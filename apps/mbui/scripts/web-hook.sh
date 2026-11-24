# Sourced by mbui's scripts/web.sh when MBUI_WEB_HOOK names it: puts libghostty-vt's Wasm beside host.js.
app_build() {
  local gvt
  gvt=$(cd "$SF_SRC" && node scripts/native.ts path ghostty-vt wasm32) || return 1
  cp "$gvt/bin/ghostty-vt.wasm" "$1/ghostty-vt.wasm"
}

app_bundle() {
  [ "$OUT/ghostty-vt.wasm" -ef "$1/ghostty-vt.wasm" ] || cp "$OUT/ghostty-vt.wasm" "$1/ghostty-vt.wasm"
}
