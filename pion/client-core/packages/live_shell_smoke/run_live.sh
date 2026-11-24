#!/usr/bin/env sh
# Build and run `live_shell_smoke` linked against real Rust `libstillfail_shell` (`rusqlite` WAL + Tokio).
# Usage: sh pion/client-core/packages/live_shell_smoke/run_live.sh [target_dir]
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
TARGET_DIR="${1:-${CARGO_TARGET_DIR:-$ROOT/client/target}}"
LIB_DIR="$TARGET_DIR/debug"
PION_RT_DIR="${PION_RT_DIR:-$HOME/.pion/share/pion/runtime}"
PIONC="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
OUT_DIR="${TMPDIR:-/tmp}/pion_live_shell_smoke_build"
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

cc -O2 -Wall -Wextra -Werror -c "$ROOT/pion/base/packages/shell/native/shell_pion.c" -o "$OUT_DIR/shell_pion.o"
if [ -n "$EXTRA_LIBS" ]; then
  "$PIONC" build --emit-staticlib "$OUT_DIR/liblive_shell_smoke.a" "$ROOT/pion/client-core/packages/live_shell_smoke"
  cc -O2 -c -I"$PION_RT_DIR" "$PION_RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
  # shellcheck disable=SC2086
  cc -O2 "$OUT_DIR/liblive_shell_smoke.a" "$OUT_DIR/shell_pion.o" "$OUT_DIR/pion_rt.o" "$SHELL_LIB" $EXTRA_LIBS -lpthread -lm -ldl -o "$OUT_DIR/live_shell_smoke"
else
  "$PIONC" build "$ROOT/pion/client-core/packages/live_shell_smoke" \
    -l "$OUT_DIR/shell_pion.o" \
    -l "$SHELL_LIB" \
    -o "$OUT_DIR/live_shell_smoke"
fi
DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$OUT_DIR/live_shell_smoke"
