#!/usr/bin/env bash
# Builds pion/rules to WebAssembly (pion/rules/js/rules.wasm) and syncs pion_wasm_rt.mjs.
set -euo pipefail
export PATH="$HOME/.pion/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/js"

pionc build --release --target wasm32 -p wasm_entry -o "$DIR/js/rules.wasm" "$DIR"

PION_WASM_RT="${PION_WASM_RT:-$HOME/.pion/share/pion/pion_wasm_rt.mjs}"
if [ -f "$PION_WASM_RT" ]; then
  cp "$PION_WASM_RT" "$DIR/js/pion_wasm_rt.mjs"
elif [ ! -f "$DIR/js/pion_wasm_rt.mjs" ]; then
  echo "pion/rules/build.sh: missing pion_wasm_rt.mjs at $PION_WASM_RT" >&2
  exit 1
fi

ls -lh "$DIR/js/rules.wasm"
