#!/bin/sh
# Build and smoke-test the Pion client core (`pion/client-core/packages/core_runtime` +
# `packages/core_abi/native/core_pion.c` + `pion/base/packages/shell/native/shell_pion.c`)
# as a drop-in `apps/mbui/src/host/core_api.h` static archive (`out/pion-core/<target>/libpion_core.a`)
# with zero Hermes (`libstillfail_engine`, `core.hbc`, `esbuild`, `Babel`, `hermesc`) dependency.
#
# Usage:
#   sh apps/mbui/scripts/pion-core.sh build [target]
#   sh apps/mbui/scripts/pion-core.sh smoke [target]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SF_SRC=${SF_SRC:-$(CDPATH= cd -- "$ROOT/../.." && pwd)}
CC=${CC:-cc}

host_target() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin) os_part=darwin ;;
    Linux) os_part=linux ;;
    *) echo "pion-core.sh: unsupported OS: $os" >&2; exit 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch_part=x64 ;;
    arm64|aarch64) arch_part=arm64 ;;
    *) echo "pion-core.sh: unsupported arch: $arch" >&2; exit 1 ;;
  esac
  printf '%s-%s\n' "$os_part" "$arch_part"
}

find_pionc() {
  if [ -n "${PIONC:-}" ]; then
    printf '%s\n' "$PIONC"
    return 0
  fi
  if command -v pionc >/dev/null 2>&1; then
    command -v pionc
    return 0
  fi
  if [ -x "$HOME/.pion/bin/pionc" ]; then
    printf '%s\n' "$HOME/.pion/bin/pionc"
    return 0
  fi
  echo "pion-core.sh: pionc not found (set PIONC or install to \$HOME/.pion/bin/pionc)" >&2
  exit 1
}

find_pion_rt_dir() {
  dir=${PION_RT_DIR:-$HOME/.pion/share/pion/runtime}
  if [ ! -f "$dir/pion_rt.c" ]; then
    echo "pion-core.sh: pion_rt.c not found in $dir (set PION_RT_DIR)" >&2
    exit 1
  fi
  printf '%s\n' "$dir"
}

dedup_apple_libs() {
  python3 - "$1" <<'PY'
import sys
t = open(sys.argv[1]).read().split()
out = []
i = 0
while i < len(t):
    x = t[i:i + 2] if t[i] == "-framework" else t[i:i + 1]
    i += len(x)
    s = " ".join(x)
    if s not in out and x[0] not in ("-lSystem", "-lobjc"):
        out.append(s)
print(" ".join(out))
PY
}

cmd_build() {
  target=${1:-$(host_target)}
  pionc=$(find_pionc)
  pion_rt_dir=$(find_pion_rt_dir)
  out_dir="$ROOT/out/pion-core/$target"
  mkdir -p "$out_dir"

  # Make sure sibling tools (e.g. qbe beside pionc) are on PATH
  pionc_dir=$(dirname "$pionc")
  case ":$PATH:" in
    *":$pionc_dir:"*) ;;
    *) PATH="$pionc_dir:$PATH"; export PATH ;;
  esac

  "$pionc" build --no-main \
    --emit-staticlib "$out_dir/libpion_core_runtime.a" \
    "$SF_SRC/pion/client-core/packages/core_runtime"

  "$CC" -O2 -c \
    -I"$pion_rt_dir" \
    "$pion_rt_dir/pion_rt.c" \
    -o "$out_dir/pion_rt.o"

  "$CC" -O2 -Wall -Wextra -Werror -c \
    "$SF_SRC/pion/base/packages/shell/native/shell_pion.c" \
    -o "$out_dir/shell_pion.o"

  "$CC" -O2 -Wall -Wextra -Werror \
    -I"$ROOT/src/host" \
    -I"$pion_rt_dir" \
    -c "$SF_SRC/pion/client-core/packages/core_abi/native/core_pion.c" \
    -o "$out_dir/core_pion.o"

  "$CC" -O2 -Wall -Wextra -Werror \
    -I"$ROOT/src/host" \
    -c "$SF_SRC/pion/client-core/packages/core_runtime/native/core_runtime_bridge.c" \
    -o "$out_dir/core_runtime_bridge.o"

  rm -f "$out_dir/libpion_core.a"
  case "$target" in
    darwin-*)
      libtool -static -o "$out_dir/libpion_core.a" \
        "$out_dir/libpion_core_runtime.a" \
        "$out_dir/pion_rt.o" \
        "$out_dir/shell_pion.o" \
        "$out_dir/core_pion.o" \
        "$out_dir/core_runtime_bridge.o"
      ;;
    linux-*)
      ar -M <<EOF
CREATE $out_dir/libpion_core.a
ADDLIB $out_dir/libpion_core_runtime.a
ADDMOD $out_dir/pion_rt.o
ADDMOD $out_dir/shell_pion.o
ADDMOD $out_dir/core_pion.o
ADDMOD $out_dir/core_runtime_bridge.o
SAVE
END
EOF
      ranlib "$out_dir/libpion_core.a"
      ;;
    *)
      echo "pion-core.sh: unsupported target for archive merge: $target" >&2
      exit 1
      ;;
  esac

  bytes=$(wc -c < "$out_dir/libpion_core.a" | tr -d ' ')
  echo "pion-core build ($target): $out_dir/libpion_core.a ($bytes bytes)"
}

cmd_smoke() {
  target=${1:-$(host_target)}
  cmd_build "$target"
  out_dir="$ROOT/out/pion-core/$target"
  smoke_bin="$out_dir/pion_smoke_test"

  case "$target" in
    darwin-*)
      shell_dir=${STILLFAIL_SHELL_DIR:-$(cd "$SF_SRC" && node scripts/native.ts path shell-apple "$target")}
      shell_libs=$(dedup_apple_libs "$shell_dir/libstillfail_shell.libs")
      # shellcheck disable=SC2086
      "$CC" -O2 -Wall -Wextra -Werror \
        -I"$ROOT/src/host" \
        "$ROOT/core/pion_smoke_test.c" \
        "$out_dir/libpion_core.a" \
        "$shell_dir/libstillfail_shell.a" \
        $shell_libs \
        -lpthread \
        -o "$smoke_bin"
      ;;
    linux-*)
      shell_dir=${STILLFAIL_SHELL_DIR:-$(cd "$SF_SRC" && node scripts/native.ts path shell "$target")}
      "$CC" -O2 -Wall -Wextra -Werror \
        -I"$ROOT/src/host" \
        "$ROOT/core/pion_smoke_test.c" \
        "$out_dir/libpion_core.a" \
        "$shell_dir/libstillfail_shell.so" \
        "-Wl,-rpath,$shell_dir" \
        -lpthread -lm -ldl \
        -o "$smoke_bin"
      ;;
    *)
      echo "pion-core.sh: unsupported smoke target: $target" >&2
      exit 1
      ;;
  esac

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mbui-pion-smoke.XXXXXX")
  trap 'rm -rf "$tmp_dir"' EXIT

  case "$target" in
    linux-*)
      LD_LIBRARY_PATH="$shell_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$smoke_bin" "$tmp_dir" "${CLOUD:-http://127.0.0.1:9}"
      ;;
    *)
      "$smoke_bin" "$tmp_dir" "${CLOUD:-http://127.0.0.1:9}"
      ;;
  esac
}

cmd=${1:-}
case "$cmd" in
  build) shift; cmd_build "${1:-}" ;;
  smoke) shift; cmd_smoke "${1:-}" ;;
  *)
    echo "usage: sh apps/mbui/scripts/pion-core.sh build [target] | smoke [target]" >&2
    exit 2
    ;;
esac
