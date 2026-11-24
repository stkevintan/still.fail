#!/usr/bin/env sh
# Build and run the real `core_api.h` C host E2E test linking:
# - Pion `packages/core_runtime` (real `ClientCore` + `shell_native::open`)
# - `packages/core_abi/native/core_pion.c` (6-function `apps/mbui/src/host/core_api.h` C ABI)
# - `pion/base/packages/shell/native/shell_pion.c` + real Rust `libstillfail_shell.so`
# Usage: sh pion/client-core/packages/core_runtime/run_e2e.sh [target_dir]
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
TARGET_DIR="${1:-${CARGO_TARGET_DIR:-$ROOT/client/target}}"
LIB_DIR="$TARGET_DIR/debug"
PION_RT_DIR="${PION_RT_DIR:-$HOME/.pion/share/pion/runtime}"
PIONC="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
OUT_DIR="${TMPDIR:-/tmp}/pion_core_runtime_e2e_build"
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"

SHELL_LIB=""
EXTRA_LIBS=""
if [ -f "$LIB_DIR/libstillfail_shell.so" ]; then
  SHELL_LIB="$LIB_DIR/libstillfail_shell.so"
elif [ -f "$LIB_DIR/libstillfail_shell.dylib" ]; then
  SHELL_LIB="$LIB_DIR/libstillfail_shell.dylib"
elif [ -f "$ROOT/apps/mbui/out/core/aarch64-apple-darwin/libstillfail_shell.a" ]; then
  SHELL_LIB="$ROOT/apps/mbui/out/core/aarch64-apple-darwin/libstillfail_shell.a"
  if [ -f "$ROOT/apps/mbui/out/core/shell-aarch64-apple-darwin.libs" ]; then
    EXTRA_LIBS="$(tr '\n' ' ' < "$ROOT/apps/mbui/out/core/shell-aarch64-apple-darwin.libs")"
  else
    EXTRA_LIBS="-framework Security -framework CoreFoundation -framework SystemConfiguration -liconv -lresolv"
  fi
else
  SHELL_LIB="$LIB_DIR/libstillfail_shell.so"
fi

"$PIONC" build --no-main \
  --emit-staticlib "$OUT_DIR/libpion_core_runtime.a" \
  "$ROOT/pion/client-core/packages/core_runtime"

cc -O2 -c \
  -I"$PION_RT_DIR" \
  "$PION_RT_DIR/pion_rt.c" \
  -o "$OUT_DIR/pion_rt.o"

cc -O2 -Wall -Wextra -Werror -c \
  "$ROOT/pion/base/packages/shell/native/shell_pion.c" \
  -o "$OUT_DIR/shell_pion.o"

cc -O2 -Wall -Wextra -Werror \
  -I"$ROOT/apps/mbui/src/host" \
  -I"$PION_RT_DIR" \
  -c "$ROOT/pion/client-core/packages/core_abi/native/core_pion.c" \
  -o "$OUT_DIR/core_pion.o"

cc -O2 -Wall -Wextra -Werror \
  -I"$ROOT/apps/mbui/src/host" \
  -c "$ROOT/pion/client-core/packages/core_runtime/native/core_runtime_bridge.c" \
  -o "$OUT_DIR/core_runtime_bridge.o"

cc -O2 -Wall -Wextra -Werror \
  -I"$ROOT/apps/mbui/src/host" \
  -c "$ROOT/pion/client-core/packages/core_runtime/native/core_runtime_e2e.c" \
  -o "$OUT_DIR/core_runtime_e2e.o"

cc -O2 -Wall -Wextra -Werror \
  -I"$ROOT/apps/mbui/src/host" \
  -c "$ROOT/pion/client-core/packages/core_runtime/native/core_runtime_live_net_e2e.c" \
  -o "$OUT_DIR/core_runtime_live_net_e2e.o"

# shellcheck disable=SC2086
cc -O2 \
  "$OUT_DIR/core_runtime_e2e.o" \
  "$OUT_DIR/core_runtime_bridge.o" \
  "$OUT_DIR/core_pion.o" \
  "$OUT_DIR/shell_pion.o" \
  "$OUT_DIR/libpion_core_runtime.a" \
  "$OUT_DIR/pion_rt.o" \
  "$SHELL_LIB" \
  $EXTRA_LIBS \
  -lpthread -lm -ldl \
  -o "$OUT_DIR/core_runtime_e2e"

# shellcheck disable=SC2086
cc -O2 \
  "$OUT_DIR/core_runtime_live_net_e2e.o" \
  "$OUT_DIR/core_runtime_bridge.o" \
  "$OUT_DIR/core_pion.o" \
  "$OUT_DIR/shell_pion.o" \
  "$OUT_DIR/libpion_core_runtime.a" \
  "$OUT_DIR/pion_rt.o" \
  "$SHELL_LIB" \
  $EXTRA_LIBS \
  -lpthread -lm -ldl \
  -o "$OUT_DIR/core_runtime_live_net_e2e"

DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$OUT_DIR/core_runtime_e2e"
DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$OUT_DIR/core_runtime_live_net_e2e"
