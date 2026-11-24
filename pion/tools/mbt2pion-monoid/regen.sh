#!/bin/sh
# Deterministic regeneration & full-byte `--check` wrapper for `mbt2pion-monoid`.
#
# Usage:
#   sh pion/tools/mbt2pion-monoid/regen.sh [options]
#
# Options:
#   --src <dir>                Source MoonBit directory (default: pilot/mbt_transpile_src)
#   --out <dir>                Output Pion directory (required unless --assets-only)
#   --target <t>               Target platform: native | wasm32 (default: native)
#   --mode <m>                 Mode: audit | publish (default: publish)
#   --api-map <path>           API map JSON (default: pion/tools/mbt2pion-monoid/api_map.json)
#   --recipes <path>           Recipes TOML (default: pion/tools/mbt2pion-monoid/recipes.toml)
#   --overlay-dir <dir>        Optional overlay directory
#   --mbt-compat <dir>         Path to `mbt_compat` package (defaults to $MBT_COMPAT_DIR if set)
#   --package-manifest <path>  Optional package pion.toml for real Stage A.5 / Stage B check
#   --dep <name=path>          Optional extra dependency (repeatable)
#   --src-prefix <rel>         Repo-relative SourceLoc prefix (default: ui/src/controls)
#   --with-tests               Include *_test.mbt / *_wbtest.mbt
#   --check                    Verify 100% full-byte equality (including headers) without modifying disk
#   --no-fmt                   Skip `pionc fmt` pass
#   --assets                   Also regenerate (or with --check, verify read-only) native/web assets
#   --assets-only              Only run assets step + single invar pin check
#
# Environment:
#   MBT2PION_BIN               Path to compiled `mbt2pion` binary (or MBT2PION_CLI_DIR to build)
#   MBT_COMPAT_DIR             Default path for `--mbt-compat`
#   PIONC                      Path to `pionc` (default: ~/.pion/bin/pionc or PATH)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export PATH="$HOME/.pion/bin:$HOME/.moon/bin:$PATH"
if [ -d /opt/homebrew/bin ]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

SRC_DIR="$SCRIPT_DIR/pilot/mbt_transpile_src"
OUT_DIR=""
TARGET="native"
MODE="publish"
API_MAP="$SCRIPT_DIR/api_map.json"
RECIPES="$SCRIPT_DIR/recipes.toml"
OVERLAY_DIR=""
MBT_COMPAT_ARG="${MBT_COMPAT_DIR:-}"
PKG_MANIFEST=""
DEPS_LIST=""
SRC_PREFIX="ui/src/controls"
WITH_TESTS=""
CHECK_FLAG=""
NO_FMT=""
RUN_ASSETS=0
ASSETS_ONLY=0
REPORT_PATH=""
DRIFT_PATH=""
RUN_REPORT_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC_DIR="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --api-map) API_MAP="$2"; shift 2 ;;
    --recipes) RECIPES="$2"; shift 2 ;;
    --overlay-dir) OVERLAY_DIR="$2"; shift 2 ;;
    --mbt-compat) MBT_COMPAT_ARG="$2"; shift 2 ;;
    --package-manifest) PKG_MANIFEST="$2"; shift 2 ;;
    --dep)
      if [ -z "$DEPS_LIST" ]; then
        DEPS_LIST="$2"
      else
        DEPS_LIST="$DEPS_LIST
$2"
      fi
      shift 2
      ;;
    --src-prefix) SRC_PREFIX="$2"; shift 2 ;;
    --report) REPORT_PATH="$2"; shift 2 ;;
    --drift-ledger) DRIFT_PATH="$2"; shift 2 ;;
    --run-report) RUN_REPORT_PATH="$2"; shift 2 ;;
    --with-tests) WITH_TESTS="--with-tests"; shift 1 ;;
    --check) CHECK_FLAG="--check"; shift 1 ;;
    --no-fmt) NO_FMT="--no-fmt"; shift 1 ;;
    --assets) RUN_ASSETS=1; shift 1 ;;
    --assets-only) RUN_ASSETS=1; ASSETS_ONLY=1; shift 1 ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "regen.sh: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

# 1. Always enforce single repo-wide invar pin
sh "$SCRIPT_DIR/check_single_invar_pin.sh"

# 2. Optional asset regeneration (or pure read-only verification when --check is set)
if [ "$RUN_ASSETS" -eq 1 ]; then
  if [ -n "$CHECK_FLAG" ]; then
    node "$SCRIPT_DIR/gen_assets.mjs" --check
  else
    node "$SCRIPT_DIR/gen_assets.mjs"
  fi
  if [ "$ASSETS_ONLY" -eq 1 ]; then
    exit 0
  fi
fi

if [ -z "$OUT_DIR" ]; then
  echo "regen.sh: --out <dir> is required" >&2
  exit 64
fi

PIONC="${PIONC:-$(command -v pionc)}"

# 3. Resolve mbt2pion binary
TMP_BIN_DIR=""
cleanup() {
  if [ -n "$TMP_BIN_DIR" ] && [ -d "$TMP_BIN_DIR" ]; then
    rm -rf "$TMP_BIN_DIR"
  fi
}
trap cleanup EXIT

if [ -z "${MBT2PION_BIN:-}" ]; then
  if [ -n "${MBT2PION_CLI_DIR:-}" ] && [ -d "$MBT2PION_CLI_DIR" ]; then
    TMP_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mbt2pion-regen-bin.XXXXXX")"
    MBT2PION_BIN="$TMP_BIN_DIR/mbt2pion"
    "$PIONC" build "$MBT2PION_CLI_DIR" -o "$MBT2PION_BIN"
  else
    echo "regen.sh: set MBT2PION_BIN or MBT2PION_CLI_DIR" >&2
    exit 2
  fi
fi

# 4. Read pinned metadata from manifest.toml for platform-neutral headers
MANIFEST="$SCRIPT_DIR/manifest.toml"
M2P_COMMIT="$(sed -n 's/^mbt2pion_commit *= *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)"
TC_LOCK="$(sed -n 's/^toolchain_lock *= *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)"
SRC_COMMIT="$(sed -n 's/^monoid_source_commit *= *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -n 1)"
M2P_COMMIT="${M2P_COMMIT:-6d22ff1f90bd19012a5997f7fdfdc56ee3012408}"
TC_LOCK="${TC_LOCK:-unpinned}"
SRC_COMMIT="${SRC_COMMIT:-working-tree}"

set -- "$MBT2PION_BIN" \
  --src "$SRC_DIR" \
  --out "$OUT_DIR" \
  --target "$TARGET" \
  --mode "$MODE" \
  --recipes "$RECIPES" \
  --mbt2pion-commit "$M2P_COMMIT" \
  --toolchain-lock "$TC_LOCK" \
  --source-commit "$SRC_COMMIT" \
  --src-prefix "$SRC_PREFIX" \
  --pionc "$PIONC"

if [ -n "$API_MAP" ] && [ "$API_MAP" != "none" ]; then
  set -- "$@" --api-map "$API_MAP"
fi
if [ -n "$OVERLAY_DIR" ]; then
  set -- "$@" --overlay-dir "$OVERLAY_DIR"
fi
if [ -n "$MBT_COMPAT_ARG" ]; then
  set -- "$@" --mbt-compat "$MBT_COMPAT_ARG"
fi
if [ -n "$PKG_MANIFEST" ]; then
  set -- "$@" --package-manifest "$PKG_MANIFEST"
fi
if [ -n "$DEPS_LIST" ]; then
  OLD_IFS="$IFS"
  IFS='
'
  for dep_spec in $DEPS_LIST; do
    if [ -n "$dep_spec" ]; then
      set -- "$@" --dep "$dep_spec"
    fi
  done
  IFS="$OLD_IFS"
fi
if [ -n "$REPORT_PATH" ]; then
  set -- "$@" --report "$REPORT_PATH"
fi
if [ -n "$DRIFT_PATH" ]; then
  set -- "$@" --drift-ledger "$DRIFT_PATH"
fi
if [ -n "$RUN_REPORT_PATH" ]; then
  set -- "$@" --run-report "$RUN_REPORT_PATH"
fi
if [ -n "$WITH_TESTS" ]; then
  set -- "$@" "$WITH_TESTS"
fi
if [ -n "$CHECK_FLAG" ]; then
  set -- "$@" "$CHECK_FLAG"
fi
if [ -n "$NO_FMT" ]; then
  set -- "$@" "$NO_FMT"
fi

"$@"
