#!/usr/bin/env sh
# Build a single self-contained static archive (`libpion_core.a`) combining:
# - Pion `packages/core_runtime` (`libpion_core_runtime.a`)
# - `pion_rt.o` (Pion C runtime)
# - `shell_pion.o` (`pion/base/packages/shell/native/shell_pion.c`)
# - `core_pion.o` (`packages/core_abi/native/core_pion.c`, 6-function `core_api.h` C ABI)
# - `core_runtime_bridge.o` (`packages/core_runtime/native/core_runtime_bridge.c`)
#
# Zero Hermes dependency. Ready for `apps/mbui` host linking with a single `-lpion_core`.
# Usage: sh pion/client-core/packages/core_runtime/build_staticlib.sh <out_lib.a> [target]
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <out_lib.a> [target]" >&2
  exit 2
fi

OUT_LIB="$1"
TARGET="${2:-}"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
PION_RT_DIR="${PION_RT_DIR:-$HOME/.pion/share/pion/runtime}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pion_core_staticlib.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$(dirname "$OUT_LIB")"

if [ -n "$TARGET" ]; then
  pionc build --no-main --target "$TARGET" \
    --emit-staticlib "$WORK_DIR/libpion_core_runtime.a" \
    "$ROOT/pion/client-core/packages/core_runtime"
else
  pionc build --no-main \
    --emit-staticlib "$WORK_DIR/libpion_core_runtime.a" \
    "$ROOT/pion/client-core/packages/core_runtime"
fi

CC_BIN="${CC:-cc}"
CFLAGS_COMMON="-O2"

"$CC_BIN" $CFLAGS_COMMON -c \
  -I"$PION_RT_DIR" \
  "$PION_RT_DIR/pion_rt.c" \
  -o "$WORK_DIR/pion_rt.o"

"$CC_BIN" $CFLAGS_COMMON -Wall -Wextra -Werror -c \
  "$ROOT/pion/base/packages/shell/native/shell_pion.c" \
  -o "$WORK_DIR/shell_pion.o"

"$CC_BIN" $CFLAGS_COMMON -Wall -Wextra -Werror \
  -I"$ROOT/apps/mbui/src/host" \
  -I"$PION_RT_DIR" \
  -c "$ROOT/pion/client-core/packages/core_abi/native/core_pion.c" \
  -o "$WORK_DIR/core_pion.o"

"$CC_BIN" $CFLAGS_COMMON -Wall -Wextra -Werror \
  -I"$ROOT/apps/mbui/src/host" \
  -c "$ROOT/pion/client-core/packages/core_runtime/native/core_runtime_bridge.c" \
  -o "$WORK_DIR/core_runtime_bridge.o"

OS_NAME="$(uname -s)"
if [ "$OS_NAME" = "Darwin" ]; then
  libtool -static -o "$OUT_LIB" \
    "$WORK_DIR/libpion_core_runtime.a" \
    "$WORK_DIR/pion_rt.o" \
    "$WORK_DIR/shell_pion.o" \
    "$WORK_DIR/core_pion.o" \
    "$WORK_DIR/core_runtime_bridge.o"
else
  # Linux / GNU ar MRI script merges the static archive + object files into one self-contained `.a`.
  rm -f "$OUT_LIB"
  cat > "$WORK_DIR/merge.mri" <<EOF
CREATE $OUT_LIB
ADDLIB $WORK_DIR/libpion_core_runtime.a
ADDMOD $WORK_DIR/pion_rt.o
ADDMOD $WORK_DIR/shell_pion.o
ADDMOD $WORK_DIR/core_pion.o
ADDMOD $WORK_DIR/core_runtime_bridge.o
SAVE
END
EOF
  ar -M < "$WORK_DIR/merge.mri"
  ranlib "$OUT_LIB"
fi

echo "Built self-contained staticlib: $OUT_LIB ($(wc -c < "$OUT_LIB" | tr -d ' ') bytes)"
