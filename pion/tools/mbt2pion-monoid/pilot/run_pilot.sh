#!/bin/sh
# Wave M1.1 Vertical Dual-Oracle Pilot Runner
# Exercises:
#   1. Live `mbt2pion --mode publish` transpilation of 6 REAL `libs/ui/src/controls/*.mbt`
#      production files (`numbers.mbt`, `marked.mbt`, `tokens_data.mbt`, `clock_read_known.mbt`,
#      `table_copy.mbt`, `reader_marks.mbt`) + `pilot_core.mbt` (real Stage A.5 probes,
#      0 blockers, 0 hand edits, emits `00_init_order.pion` + all 7 `.pion` files)
#   2. 3-engine Differential Oracle (`moon run --target wasm-gc` vs `pionc run` vs `pionc run --target wasm32`)
#      across all 19 §7 M1.1 vertical + real-controls cases + hot-path benchmarks
#   3. Dual-target asset tests (`sf_assets_native` + `sf_assets_web` + `wasm32` build)
#   4. Cross-workspace `pion/app` `sf_smoke` + `app_state` 4-FPS (`60/120/24/7`) + `ui/src/tester.pion:66` FPS readback
#
# Environment variables (no absolute paths hardcoded in any committed pion.toml):
#   MBT2PION_BIN   Path to compiled `mbt2pion` binary (or set MBT2PION_CLI_DIR to build on demand)
#   MBT_COMPAT_DIR Path to `mbt_compat` package directory
#   INVAR_DIR      Optional path to `AFK-surf/invar` checkout at the pinned rev (auto-discovered from pion cache)
#   PIONC          Path to `pionc` (default: ~/.pion/bin/pionc or PATH)
#   MOON           Path to `moon` (default: ~/.moon/bin/moon or PATH)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/../../.." && pwd)"

export PATH="$HOME/.pion/bin:$HOME/.moon/bin:$PATH"
if [ -d /opt/homebrew/bin ]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
PIONC="${PIONC:-$(command -v pionc)}"
MOON="${MOON:-$(command -v moon)}"

if [ -z "${MBT_COMPAT_DIR:-}" ] || [ ! -d "$MBT_COMPAT_DIR" ]; then
  echo "ERROR: set MBT_COMPAT_DIR to the mbt_compat package directory" >&2
  exit 2
fi

CONTROLS_DIR="$REPO_ROOT/libs/ui/src/controls"
REAL_CONTROLS_FILES="numbers.mbt marked.mbt tokens_data.mbt clock_read_known.mbt table_copy.mbt reader_marks.mbt"
if [ ! -d "$CONTROLS_DIR" ]; then
  echo "ERROR: real controls directory missing: $CONTROLS_DIR" >&2
  exit 1
fi
for rf in $REAL_CONTROLS_FILES; do
  if [ ! -f "$CONTROLS_DIR/$rf" ]; then
    echo "ERROR: required real production control file missing: $CONTROLS_DIR/$rf" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/m11-vertical-pilot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -z "${MBT2PION_BIN:-}" ]; then
  if [ -n "${MBT2PION_CLI_DIR:-}" ] && [ -d "$MBT2PION_CLI_DIR" ]; then
    MBT2PION_BIN="$WORK/mbt2pion"
    "$PIONC" build "$MBT2PION_CLI_DIR" -o "$MBT2PION_BIN"
  else
    echo "ERROR: set MBT2PION_BIN (or MBT2PION_CLI_DIR)" >&2
    exit 2
  fi
fi

INVAR_REV="$(grep 'AFK-surf/invar\.git' "$REPO_ROOT/pion/ui/pion.toml" | head -n 1 | sed -n 's/.*rev *= *"\([0-9a-f]\{40\}\)".*/\1/p')"
if [ -z "${INVAR_DIR:-}" ]; then
  if [ ! -d "$HOME/.cache/pion/git/checkouts/$INVAR_REV" ]; then
    "$PIONC" fetch "$REPO_ROOT/pion/ui" >/dev/null
  fi
  INVAR_DIR="$HOME/.cache/pion/git/checkouts/$INVAR_REV"
fi
if [ ! -d "$INVAR_DIR/packages/ui" ]; then
  echo "ERROR: pinned invar checkout not found at $INVAR_DIR" >&2
  exit 2
fi

echo "=== [1/4] Live mbt2pion --mode publish on 6 real libs/ui/src/controls/*.mbt + pilot_core.mbt ==="
STAGE_SRC="$WORK/stage_mbt"
mkdir -p "$STAGE_SRC"
for rf in $REAL_CONTROLS_FILES; do
  cp "$CONTROLS_DIR/$rf" "$STAGE_SRC/$rf"
done
cp "$SCRIPT_DIR/mbt_transpile_src/pilot_core.mbt" "$STAGE_SRC/pilot_core.mbt"

PILOT_WS="$WORK/pilot_ws"
PILOT_PKG="$PILOT_WS/pilot"
mkdir -p "$PILOT_PKG/src"
"$MBT2PION_BIN" \
  --src "$STAGE_SRC" \
  --out "$PILOT_PKG/src" \
  --target native \
  --recipes "$TOOLS_DIR/recipes.toml" \
  --mbt-compat "$MBT_COMPAT_DIR" \
  --dep "signals=$INVAR_DIR/packages/signals" \
  --dep "view=$INVAR_DIR/packages/view" \
  --dep "ui=$INVAR_DIR/packages/ui" \
  --dep "paint=$INVAR_DIR/packages/paint" \
  --dep "pixels=$INVAR_DIR/packages/pixels" \
  --dep "flex=$INVAR_DIR/packages/flex" \
  --dep "text=$INVAR_DIR/packages/text" \
  --dep "halt=$INVAR_DIR/packages/halt" \
  --dep "dmath=$INVAR_DIR/packages/dmath" \
  --dep "codec=$INVAR_DIR/packages/codec" \
  --dep "zip=$INVAR_DIR/packages/zip" \
  --dep "hostapi=$INVAR_DIR/packages/hostapi" \
  --dep "damage=$INVAR_DIR/packages/damage" \
  --dep "editor=$INVAR_DIR/packages/editor" \
  --mode publish \
  --src-prefix "ui/src/controls" \
  --report "$WORK/pilot_migration_report.json" \
  --drift-ledger "$WORK/pilot_drift_ledger.json" \
  --run-report "$WORK/pilot_run_report.json"

test -f "$PILOT_PKG/src/00_init_order.pion" || { echo "ERROR: 00_init_order.pion was not generated" >&2; exit 1; }
for rf in $REAL_CONTROLS_FILES pilot_core.mbt; do
  pf="${rf%.mbt}.pion"
  test -f "$PILOT_PKG/src/$pf" || { echo "ERROR: $pf was not generated" >&2; exit 1; }
done
echo "OK: generated 00_init_order.pion + 6 real controls .pion + pilot_core.pion with 0 blockers"

# Assemble scratch Pion workspace (never hardcodes machine paths in repo pion.toml)
cp "$SCRIPT_DIR/pion_pilot/src/main.pion" "$PILOT_PKG/src/main.pion"

cat > "$PILOT_WS/pion.toml" << EOF
[workspace]
members = ["pilot"]

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
mbt_compat = { path = "$MBT_COMPAT_DIR" }
sf = { path = "$REPO_ROOT/pion/ui/packages/sf" }
signals = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/signals" }
view = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/view" }
ui = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/ui" }
zip = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/zip" }
pixels = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/pixels" }
paint = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/paint" }
EOF

cat > "$PILOT_PKG/pion.toml" << EOF
[package]
name = "m11_vertical_pilot"
version = "0.1.0"

[dependencies]
mbt_compat = { workspace = true }
sf = { workspace = true }
signals = { workspace = true }
view = { workspace = true }
ui = { workspace = true }
EOF

echo "=== [2/4] 3-Engine Differential Oracle (MoonBit wasm-gc vs Pion native vs Pion wasm32) + Benchmarks ==="
REPORT_ARG=""
if [ -n "${PILOT_REPORT_OUT:-}" ]; then
  REPORT_ARG="--report $PILOT_REPORT_OUT"
fi
python3 "$SCRIPT_DIR/oracle.py" \
  --moon-dir "$SCRIPT_DIR/moon_pilot" \
  --moon-extra-src "$CONTROLS_DIR/numbers.mbt" \
  --moon-extra-src "$CONTROLS_DIR/marked.mbt" \
  --moon-extra-src "$CONTROLS_DIR/tokens_data.mbt" \
  --moon-extra-src "$SCRIPT_DIR/mbt_transpile_src/pilot_core.mbt" \
  --pion-dir "$PILOT_PKG" \
  --moon-bin "$MOON" \
  --pionc-bin "$PIONC" \
  $REPORT_ARG

echo "=== [3/4] Dual-Target Assets (sf_assets_native + sf_assets_web + wasm32 build) ==="
"$PIONC" test --json "$REPO_ROOT/pion/ui"
"$PIONC" build --target wasm32 "$REPO_ROOT/pion/ui" -o "$WORK/pion_ui.wasm"
echo "OK: pion/ui native tests + wasm32 build passed"

echo "=== [4/4] Cross-Workspace pion/app sf_smoke + app_state 4-FPS (60/120/24/7) + tester.pion:66 FPS readback ==="
FPS_PKG="$WORK/fps_readback_pkg"
mkdir -p "$FPS_PKG/src"
cat > "$FPS_PKG/pion.toml" << EOF
[package]
name = "fps_readback_probe"
version = "0.1.0"

[dependencies]
ui = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/ui" }
view = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/view" }
EOF
cat > "$FPS_PKG/src/main.pion" << 'EOF'
import "ui"
import "view"

pub fn main(world : World) -> Int {
  let args = world_args(world)
  if args.length() < 2 {
    panic("missing expected fps arg")
  }
  let want_fps = match args[1] {
    "60" => 60.0
    "120" => 120.0
    "24" => 24.0
    "7" => 7.0
    _ => panic("unexpected fps tier: " + args[1])
  }
  let t = ui::Tester::tree(fn(_root : view::View) { () }, width=200.0, height=100.0)
  let want_period = 1000.0 / want_fps
  let diff = t.period_ms - want_period
  let adiff = if diff < 0.0 { -diff } else { diff }
  if adiff > 1.0e-6 {
    panic("tester.pion:66 FPS readback mismatch: period_ms=" + t.period_ms.to_string() + " expected=" + want_period.to_string())
  }
  io_println(world, "OK: ui/src/tester.pion:66 read back INVAR_TEST_FPS=" + args[1] + " -> period_ms=" + t.period_ms.to_string())
  t.dispose()
  0
}
EOF
"$PIONC" build "$FPS_PKG" -o "$WORK/fps_readback_probe"

for fps in 60 120 24 7; do
  INVAR_TEST_FPS="$fps" "$WORK/fps_readback_probe" "$fps"
  INVAR_TEST_FPS="$fps" INVAR_FPS="$fps" "$PIONC" test --json --package sf_smoke "$REPO_ROOT/pion/app" > /dev/null
  INVAR_TEST_FPS="$fps" INVAR_FPS="$fps" "$PIONC" test --json --package app_state "$REPO_ROOT/pion/app" > /dev/null
  echo "OK: sf_smoke + app_state passed at INVAR_TEST_FPS=$fps"
done

echo "=== ALL M1.1 VERTICAL DUAL-ORACLE PILOT CHECKS PASSED ==="
