#!/usr/bin/env bash
# Build `stillfail-pion` (`pion/station/packages/smoke`) linked against real `libstillfail_shell.a`.
# Supports: darwin-arm64, linux-x64 (glibc 2.28), linux-arm64 (glibc 2.28), win32-x64 (MinGW GNU).
#
# Usage:
#   bash pion/station/scripts/build.sh [target] [out]
#
# Environment:
#   SHELL_LIB           Override path to libstillfail_shell.a (default: scripts/native.ts path ...)
#   PIONC               Override path to pionc binary (default: ensure-pionc.sh)
#   PION_TOOLCHAIN_DIR  Override pion toolchain cache dir
#   ZIG_BIN             Override path to zig binary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$STATION_DIR/../.." && pwd)"

default_target="darwin-arm64"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) default_target="linux-x64" ;;
  Linux-aarch64|Linux-arm64) default_target="linux-arm64" ;;
esac

target="${1:-$default_target}"
default_ext=""
[ "$target" = "win32-x64" ] && default_ext=".exe"
out="${2:-$STATION_DIR/_build/stillfail-pion-$target$default_ext}"

# Ensure pinned pionc toolchain (or validated PIONC/PION_QBE/PION_RT_DIR override).
ENV_OUT="$(sh "$SCRIPT_DIR/ensure-pionc.sh" --print-env)" || exit $?
eval "$ENV_OUT"
PION_SHA="$PION_BUILD_SHA"

ensure_zig() {
  if [ -n "${ZIG_BIN:-}" ] && [ -x "$ZIG_BIN" ]; then
    printf '%s\n' "$ZIG_BIN"
    return 0
  fi
  if command -v zig >/dev/null 2>&1; then
    command -v zig
    return 0
  fi
  if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
    echo "build.sh: zig is required for target $target (install zig 0.16.0 or set ZIG_BIN)" >&2
    exit 1
  fi
  local zver="0.16.0"
  local zsha="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
  local zbase="${XDG_CACHE_HOME:-$HOME/.cache}/pion-station-zig/$zver"
  local zbin="$zbase/zig-x86_64-linux-$zver/zig"
  if [ ! -x "$zbin" ]; then
    mkdir -p "$zbase"
    local tmp="$zbase/zig.tar.xz.$$"
    echo "build.sh: downloading zig $zver..." >&2
    curl -fsSL --retry 5 --retry-all-errors --speed-limit 1024 --speed-time 20 \
      -o "$tmp" "https://ziglang.org/download/$zver/zig-x86_64-linux-$zver.tar.xz"
    echo "$zsha  $tmp" | sha256sum -c --quiet
    tar -xf "$tmp" -C "$zbase"
    rm -f "$tmp"
  fi
  printf '%s\n' "$zbin"
}

case "$target" in
  darwin-arm64)
    qbe_target="arm64_apple"
    cc=(cc -arch arm64 -mmacosx-version-min=11.0)
    cc_extra=(-ffunction-sections -fdata-sections)
    part="shell-apple"
    libs=(-framework SystemConfiguration -framework Security -framework CoreFoundation -framework Foundation -liconv -lobjc -Wl,-dead_strip)
    ;;
  linux-x64)
    zig_exe="$(ensure_zig)"
    qbe_target="amd64_sysv"
    cc=("$zig_exe" cc -target x86_64-linux-gnu.2.28)
    cc_extra=(-fno-sanitize=undefined -ffunction-sections -fdata-sections)
    part="shell-station"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s)
    ;;
  linux-arm64)
    zig_exe="$(ensure_zig)"
    qbe_target="arm64"
    cc=("$zig_exe" cc -target aarch64-linux-gnu.2.28)
    cc_extra=(-fno-sanitize=undefined -ffunction-sections -fdata-sections)
    part="shell-station"
    libs=(-lunwind -lutil -lrt -lpthread -lm -ldl -lc -Wl,--gc-sections -s)
    ;;
  win32-x64)
    zig_exe="$(ensure_zig)"
    qbe_target="amd64_win"
    cc=("$zig_exe" cc -target x86_64-windows-gnu)
    cc_extra=(-fno-sanitize=undefined -ffunction-sections -fdata-sections)
    part="shell-station"
    libs=(-lshell32 -liphlpapi -lbcrypt -ladvapi32 -lkernel32 -lntdll -luserenv -lws2_32 -ldbghelp -lunwind -Wl,--gc-sections -Wl,--stack,16777216 -s)
    ;;
  *)
    echo "build.sh: unsupported target '$target' (expected darwin-arm64, linux-x64, linux-arm64, win32-x64)" >&2
    exit 2
    ;;
esac

if [ -n "${SHELL_LIB:-}" ]; then
  shell_lib="$SHELL_LIB"
else
  shell_dir="$(node "$ROOT/scripts/native.ts" path "$part" "$target")"
  shell_lib="$shell_dir/libstillfail_shell.a"
fi
if [ ! -f "$shell_lib" ]; then
  echo "build.sh: missing shell static library: $shell_lib" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/pion-station-build-$target.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$out")"

# Wrap target cc for pionc's assembly step so cross-targets (linux-arm64, win32-x64)
# assemble QBE .s output with zig cc rather than the host assembler.
cat > "$work/target-cc.sh" <<EOF
#!/bin/sh
exec $(printf '%q ' "${cc[@]}" "${cc_extra[@]}") "\$@"
EOF
chmod +x "$work/target-cc.sh"

# Build all Pion packages in the workspace into a single target staticlib (skips final link).
CC="$work/target-cc.sh" "$PIONC" build --release --target "$qbe_target" \
  --emit-staticlib "$work/libsmoke.a" \
  "$STATION_DIR/packages/smoke"

rt_extra=()
if [ "$target" = "linux-x64" ] || [ "$target" = "win32-x64" ]; then
  # zig cc's compiler-rt does not provide GCC's __cpu_model symbol referenced by
  # __builtin_cpu_supports("avx2") in pion_rt.c; fall back to scalar SIMD path.
  rt_extra+=('-D__builtin_cpu_supports(x)=0')
fi

"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" ${rt_extra[@]+"${rt_extra[@]}"} -I"$PION_RT_DIR" \
  -c "$PION_RT_DIR/pion_rt.c" -o "$work/pion_rt.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -DSTH_TARGET_NAME="\"$target\"" \
  -DSTH_PION_SHA="\"$PION_SHA\"" \
  -c "$STATION_DIR/packages/host_shim/native/station_host.c" -o "$work/station_host.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -c "$STATION_DIR/packages/sqlite_ffi/native/station_sqlite.c" -o "$work/station_sqlite.o"
"${cc[@]}" -std=c11 -O2 "${cc_extra[@]}" -Wall -Wextra -Werror \
  -c "$STATION_DIR/packages/footprint/native/footprint_fs.c" -o "$work/footprint_fs.o"

"${cc[@]}" -O2 "${cc_extra[@]}" -o "$out" \
  "$work/libsmoke.a" \
  "$work/pion_rt.o" \
  "$work/station_host.o" \
  "$work/station_sqlite.o" \
  "$work/footprint_fs.o" \
  "$shell_lib" \
  "${libs[@]}"

echo "$out"
