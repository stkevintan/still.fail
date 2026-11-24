#!/bin/bash
# Pure prebuilt mbui Wasm Runtime shell: zero app-specific C, binding only mbui's standard HostAPI
# (src/host/{host,device,stream,textref,native,terminal}_native.mbt). Drop any MoonBit .wasm / .cwasm app into
# a standard bundle and run it with zero C compilation.
#
#   scripts/runtime.sh build [mac|linux|android|ios|win]
#   scripts/runtime.sh compile <APP.wasm> --target <triple> --out <OUT.cwasm> [--traps signals|checked]
#   scripts/runtime.sh pack [mac|linux] <APP.wasm|APP.cwasm> [--name NAME] [--id APP_ID] [--out DIR]
#   scripts/runtime.sh run [mac|linux] <APP.wasm|APP.cwasm> [KEY=VAL...]
#   scripts/runtime.sh check
#   scripts/runtime.sh test
set -eu
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/.." && pwd)"
. "$D/env.sh"

if [ -n "${MBUI_OUT:-}" ]; then
  O=$(mkdir -p "$MBUI_OUT" && cd "$MBUI_OUT" && pwd)
  export MBUI_TOOLS_OUT=${MBUI_TOOLS_OUT:-$O/tools}
else
  O="$ROOT/out"
fi
mkdir -p "$O/runtime"

WT_VERSION=50.0.1
WT_SAME="-C collector=drc"
H="$ROOT/src/host"
DECLS="$H/host_native.mbt $H/device_native.mbt $H/stream_native.mbt $H/textref_native.mbt $H/native_native.mbt $H/terminal_native.mbt"
THUNKS="$O/runtime/thunks.c"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | awk '{print $1}'
  else shasum -a 256 "$@" | awk '{print $1}'; fi
}

default_platform() {
  case "$(uname -s)" in
    Darwin) echo mac ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo win ;;
    *) echo "runtime.sh: unsupported host OS $(uname -s)" >&2; exit 1 ;;
  esac
}

gen_thunks() {
  "$D/wasmhost" gen "$THUNKS" $DECLS > /dev/null
}

write_meta() {
  local dir=$1 plat=$2 arch=$3 target=$4
  cat > "$dir/runtime.json" <<EOF
{
  "runtime": "mbui-runtime",
  "platform": "$plat",
  "arch": "$arch",
  "target": "$target",
  "wasmtime": "$WT_VERSION",
  "collector": "drc"
}
EOF
}

wasmtime_cli() {
  local host sha
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) host=aarch64-macos sha=960e5216c7ebd7e9b45e6561d15821b8b801b7d54aee28c7b91921aeb30c65c8 ;;
    Darwin-x86_64) host=x86_64-macos sha=ea1818fa8cbb51524847ab2ad22197e0051594fdc96cbd0cc2afb65832e11925 ;;
    Linux-x86_64) host=x86_64-linux sha=685466455dd42a14774a86c36c8f2e45cbb9bd6d92a850139315df60a75498a5 ;;
    Linux-aarch64) host=aarch64-linux sha=d737e077416d78fbfb0a008229ec27d6a0fd5a4924874b8c38b293c850cf4094 ;;
    *) echo "runtime.sh: no wasmtime CLI for $(uname -s) $(uname -m)" >&2; exit 1 ;;
  esac
  WT_CLI="$O/wasmtime-v$WT_VERSION-$host/wasmtime"
  if [ -x "$WT_CLI" ]; then return 0; fi
  local tar_file="$O/wasmtime-v$WT_VERSION-$host.tar.xz"
  curl -fsSL --retry 3 -o "$tar_file" \
    "https://github.com/bytecodealliance/wasmtime/releases/download/v$WT_VERSION/wasmtime-v$WT_VERSION-$host.tar.xz"
  [ "$(sha256_of "$tar_file")" = "$sha" ] \
    || { rm -f "$tar_file"; echo "runtime.sh: wasmtime CLI checksum mismatch" >&2; exit 1; }
  tar xf "$tar_file" -C "$O"
  rm -f "$tar_file"
}

build_mac() {
  local arch sha target out_dir wt tar_file moon_root host_c f obj flags pids=()
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 target=aarch64-apple-darwin sha=a49327ca596fae51cd92e230265132112bb7896c5a24e4d58cd05b56612e26bb ;;
    x86_64) arch=x86_64 target=x86_64-apple-darwin sha=b6d436cba5c0964785c6ff7c9b5a743131555a0227b4f742185c4fb520c502c5 ;;
    *) echo "runtime.sh: unsupported macOS arch $(uname -m)" >&2; exit 1 ;;
  esac
  wt="$O/wasmtime-v$WT_VERSION-$arch-macos-c-api"
  if [ ! -f "$wt/lib/libwasmtime.dylib" ]; then
    tar_file="$O/wasmtime-v$WT_VERSION-$arch-macos-c-api.tar.xz"
    curl -fsSL --retry 3 -o "$tar_file" \
      "https://github.com/bytecodealliance/wasmtime/releases/download/v$WT_VERSION/wasmtime-v$WT_VERSION-$arch-macos-c-api.tar.xz"
    [ "$(sha256_of "$tar_file")" = "$sha" ] \
      || { rm -f "$tar_file"; echo "runtime.sh: wasmtime macOS C API checksum mismatch" >&2; exit 1; }
    tar xf "$tar_file" -C "$O"
    rm -f "$tar_file"
  fi
  gen_thunks
  out_dir="$O/runtime/mac"
  mkdir -p "$out_dir"
  moon_root=${MOON_HOME:-$(dirname "$(dirname "${MBUI_REAL_MOON:-$(command -v moon)}")")}
  [ -f "$moon_root/lib/runtime/runtime.c" ] || { echo "runtime.sh: missing MoonBit runtime at $moon_root/lib/runtime/runtime.c" >&2; exit 1; }
  host_c=$(ls "$H"/apple_*.m "$H/mac_app.m")
  local shell_src
  shell_src=$(cat $host_c "$H"/*.h "$H/wasm_shell.c" "$THUNKS" "$moon_root/lib/runtime/runtime.c" "$moon_root/include/moonbit.h" \
    "$wt/lib/libwasmtime.dylib" "$0" | cksum)
  if [ ! -x "$out_dir/mbui-runtime" ] || [ "$(cat "$out_dir/shell.src" 2>/dev/null)" != "$shell_src" ]; then
    local t0=$SECONDS
    rm -rf "$out_dir/obj"
    mkdir -p "$out_dir/obj"
    for f in $host_c "$H/wasm_shell.c" "$THUNKS" "$moon_root/lib/runtime/runtime.c"; do
      obj="$out_dir/obj/$(echo "${f#"$ROOT"/}" | tr '/.' '__').o"
      flags="-O2 -I$moon_root/include -I$wt/include -I$H"
      case "$f" in *.m) flags="$flags -fobjc-arc -fblocks" ;; esac
      clang $flags -c "$f" -o "$obj" &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done
    clang -o "$out_dir/mbui-runtime" "$out_dir"/obj/*.o "$wt/lib/libwasmtime.dylib" \
      -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path \
      -framework Cocoa -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics \
      -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework WebKit \
      -framework AuthenticationServices -framework LocalAuthentication -framework Security \
      -framework CoreFoundation -framework Foundation
    echo "$shell_src" > "$out_dir/shell.src"
    echo "runtime.sh: built mac runtime in $((SECONDS - t0)) s"
  fi
  cp -p "$wt/lib/libwasmtime.dylib" "$out_dir/libwasmtime.dylib"
  write_meta "$out_dir" mac "$arch" "$target"
  ls -la "$out_dir/mbui-runtime" "$out_dir/libwasmtime.dylib"
}

build_linux() {
  local arch target out_dir
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 target=x86_64-unknown-linux-gnu ;;
    aarch64|arm64) arch=aarch64 target=aarch64-unknown-linux-gnu ;;
    *) echo "runtime.sh: unsupported Linux arch $(uname -m)" >&2; exit 1 ;;
  esac
  gen_thunks
  out_dir="$O/runtime/linux"
  mkdir -p "$out_dir"
  MBUI_OUT="$O" MBUI_WASM_THUNKS="$THUNKS" MBUI_WASM_OUT="$out_dir" bash "$D/linux.sh" build
  write_meta "$out_dir" linux "$arch" "$target"
}

build_android() {
  local abi=${ABI:-arm64-v8a} arch target out_dir
  case "$abi" in
    x86_64) arch=x86_64 target=x86_64-linux-android ;;
    *) arch=aarch64 target=aarch64-linux-android ;;
  esac
  gen_thunks
  out_dir="$O/runtime/android"
  mkdir -p "$out_dir"
  ABI="$abi" MBUI_OUT="$O" MBUI_WASM_THUNKS="$THUNKS" bash "$D/android.sh" build
  if [ -f "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" ]; then
    cp -p "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" "$out_dir/mbui-runtime-$abi.apk"
  fi
  write_meta "$out_dir" android "$arch" "$target"
}

build_ios() {
  local sdk=${MBUI_IOS_SDK:-iphonesimulator} arch target out_dir src_app
  if [ "$sdk" = iphonesimulator ]; then
    case "$(uname -m)" in
      arm64|aarch64) arch=aarch64 ;;
      x86_64) arch=x86_64 ;;
      *) echo "runtime.sh: unsupported iOS simulator arch $(uname -m)" >&2; exit 1 ;;
    esac
    target="$arch-apple-ios-sim"
    src_app="$ROOT/out/ios/MBUI.app"
  else
    arch=aarch64
    target="pulley64"
    src_app="$ROOT/out/ios-device/MBUI.app"
  fi
  gen_thunks
  out_dir="$O/runtime/ios"
  mkdir -p "$out_dir"
  MBUI_IOS_SDK="$sdk" MBUI_OUT="$O" MBUI_WASM_THUNKS="$THUNKS" bash "$D/ios.sh" build
  if [ -d "$src_app" ]; then
    rm -rf "$out_dir/MBUI.app"
    cp -Rp "$src_app" "$out_dir/MBUI.app"
  fi
  write_meta "$out_dir" ios "$arch" "$target"
}

build_win() {
  local out_dir="$O/runtime/win" wt="$O/wasmtime-v$WT_VERSION-x86_64-windows-c-api"
  mkdir -p "$out_dir/obj"
  if [ ! -f "$wt/lib/wasmtime.dll.lib" ]; then
    local zip_file="$O/wasmtime-v$WT_VERSION-x86_64-windows-c-api.zip"
    curl -fsSL --retry 3 -o "$zip_file" \
      "https://github.com/bytecodealliance/wasmtime/releases/download/v$WT_VERSION/wasmtime-v$WT_VERSION-x86_64-windows-c-api.zip"
    [ "$(sha256_of "$zip_file")" = 8b461d9dc12b076d0414b1023433bbb2dc08d3b1c0f0a156853ede35f0147802 ] \
      || { rm -f "$zip_file"; echo "runtime.sh: wasmtime Windows C API checksum mismatch" >&2; exit 1; }
    (cd "$O" && unzip -q -o "$(basename "$zip_file")" && rm -f "$(basename "$zip_file")")
  fi
  local wv2="$O/webview2/1.0.4258.31"
  if [ ! -f "$wv2/build/native/include/WebView2.h" ]; then
    mkdir -p "$O/webview2"
    curl -sSfL --retry 3 -o "$wv2.nupkg" "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.4258.31"
    (cd "$O/webview2" && unzip -q -o "1.0.4258.31.nupkg" -d "$wv2" && rm -f "1.0.4258.31.nupkg")
  fi
  gen_thunks
  local moon_root flags f o extra sum objs=() pids=()
  moon_root=$(cygpath -u "${MOON_HOME:-$(dirname "$(dirname "${MBUI_REAL_MOON:-$(command -v moon)}")")}")
  win() { cygpath -w "$1"; }
  flags="-nologo -O2 -utf-8 -W0 -I$(win "$moon_root/include") -I$(win "$wt/include") -I$(win "$H") -I$(win "$wv2/build/native/include")"
  for f in "$H"/win_*.c "$H"/win_*.cpp "$H/wasm_shell.c" "$THUNKS" "$moon_root/lib/runtime/runtime.c"; do
    o="$out_dir/obj/$(echo "${f#"$ROOT"/}" | tr '/\\:' '___').obj"
    objs+=("$o")
    extra=
    case "$f" in *.cpp) extra="-EHsc -std:c++20" ;; esac
    sum=$( (echo "$flags $extra"; cat "$f" "$H"/*.h) | sha256_of )
    [ -f "$o" ] && [ "$(cat "$o.sum" 2>/dev/null)" = "$sum" ] && continue
    (rm -f "$o.sum"; cl.exe $flags $extra -c "$(win "$f")" -Fo"$(win "$o")" > "$o.log" 2>&1 && echo "$sum" > "$o.sum" \
      || { cat "$o.log" >&2; exit 1; }) &
    pids+=($!)
  done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || exit 1; done
  "$(dirname "$(command -v cl.exe)")/link.exe" -nologo -out:"$(win "$out_dir/mbui-runtime.exe")" \
    $(for o in "${objs[@]}"; do win "$o"; done) \
    "$(win "$wt/lib/wasmtime.dll.lib")" "$(win "$wv2/build/native/x64/WebView2LoaderStatic.lib")" > "$out_dir/link.log" 2>&1 \
    || { cat "$out_dir/link.log" >&2; exit 1; }
  cp -p "$wt/lib/wasmtime.dll" "$out_dir/wasmtime.dll"
  write_meta "$out_dir" win x86_64 x86_64-pc-windows-msvc
  ls -la "$out_dir/mbui-runtime.exe" "$out_dir/wasmtime.dll"
}

cmd_compile() {
  local input=${1:-} target="" out="" traps="signals" sbt="y"
  [ -n "$input" ] && [ -f "$input" ] || { echo "usage: runtime.sh compile <APP.wasm> --target <triple> --out <OUT.cwasm> [--traps signals|checked]" >&2; exit 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target=${2:-}; shift 2 ;;
      --out) out=${2:-}; shift 2 ;;
      --traps) traps=${2:-}; shift 2 ;;
      *) echo "runtime.sh compile: unknown option $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$target" ] && [ -n "$out" ] || { echo "runtime.sh compile: --target and --out are required" >&2; exit 2; }
  case "$traps" in
    signals) sbt=y ;;
    checked) sbt=n ;;
    *) echo "runtime.sh compile: --traps must be signals or checked, not $traps" >&2; exit 2 ;;
  esac
  wasmtime_cli
  mkdir -p "$(dirname "$out")"
  local t0=$SECONDS
  "$WT_CLI" compile $WT_SAME -O signals-based-traps=$sbt --target "$target" "$input" -o "$out"
  echo "runtime.sh: compiled $out for $target in $((SECONDS - t0)) s"
}

cmd_pack() {
  local plat="" app="" name="MBUIApp" app_id="" out_dir=""
  case "${1:-}" in
    mac|linux) plat=$1; shift ;;
    *) plat=$(default_platform) ;;
  esac
  app=${1:-}
  [ -n "$app" ] && [ -f "$app" ] || { echo "usage: runtime.sh pack [mac|linux] <APP.wasm|APP.cwasm> [--name NAME] [--id APP_ID] [--out DIR]" >&2; exit 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=${2:-}; shift 2 ;;
      --id) app_id=${2:-}; shift 2 ;;
      --out) out_dir=${2:-}; shift 2 ;;
      *) echo "runtime.sh pack: unknown option $1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$app_id" ]; then
    local safe_name
    safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9.-' '-' | sed -e 's/^-*//' -e 's/-*$//')
    [ -n "$safe_name" ] || safe_name="app"
    app_id="dev.mbui.runtime.$safe_name"
  fi
  local ext="wasm"
  case "$app" in *.cwasm) ext="cwasm" ;; esac
  out_dir=${out_dir:-$O/runtime/packed-$plat}
  mkdir -p "$out_dir"
  if [ "$plat" = mac ]; then
    local rt="$O/runtime/mac"
    [ -x "$rt/mbui-runtime" ] || build_mac
    local appdir="$out_dir/$name.app"
    rm -rf "$appdir"
    mkdir -p "$appdir/Contents/MacOS" "$appdir/Contents/Frameworks" "$appdir/Contents/Resources"
    cp -p "$rt/mbui-runtime" "$appdir/Contents/MacOS/mbui-runtime"
    cp -p "$rt/libwasmtime.dylib" "$appdir/Contents/Frameworks/libwasmtime.dylib"
    cp -p "$app" "$appdir/Contents/Resources/app.$ext"
    local plist="$appdir/Contents/Info.plist"
    plutil -create xml1 "$plist"
    for kv in "CFBundleIdentifier $app_id" "CFBundleName $name" "CFBundleDisplayName $name" \
      "CFBundleExecutable mbui-runtime" "CFBundlePackageType APPL" "CFBundleInfoDictionaryVersion 6.0" \
      "CFBundleShortVersionString 0.1.0" "CFBundleVersion 1" "LSMinimumSystemVersion 13.0" \
      "NSPrincipalClass NSApplication"; do
      plutil -insert "${kv%% *}" -string "${kv#* }" "$plist"
    done
    plutil -insert NSHighResolutionCapable -bool YES "$plist"
    plutil -insert NSSupportsAutomaticGraphicsSwitching -bool YES "$plist"
    codesign --force --sign - --timestamp=none "$appdir/Contents/Frameworks/libwasmtime.dylib"
    codesign --force --sign - --timestamp=none "$appdir"
    echo "runtime.sh: packed $appdir (bundled Resources/app.$ext)"
  elif [ "$plat" = linux ]; then
    local rt="$O/runtime/linux"
    [ -x "$rt/mbui-runtime" ] || build_linux
    local dir="$out_dir/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -p "$rt/mbui-runtime" "$dir/mbui-runtime"
    cp -p "$rt/libwasmtime.so" "$dir/libwasmtime.so"
    cp -p "$app" "$dir/app.$ext"
    echo "runtime.sh: packed $dir (bundled app.$ext)"
  else
    echo "runtime.sh pack: unsupported platform $plat (use mac or linux)" >&2
    exit 2
  fi
}

cmd_run() {
  local plat="" app=""
  case "${1:-}" in
    mac|linux) plat=$1; shift ;;
    *) plat=$(default_platform) ;;
  esac
  app=${1:-}
  [ -n "$app" ] && [ -f "$app" ] || { echo "usage: runtime.sh run [mac|linux] <APP.wasm|APP.cwasm> [KEY=VAL...]" >&2; exit 2; }
  shift
  local rt="$O/runtime/$plat"
  if [ ! -x "$rt/mbui-runtime" ]; then
    if [ "$plat" = mac ]; then build_mac; else build_linux; fi
  fi
  for kv in "$@"; do export "$kv"; done
  on_screen "$rt/mbui-runtime" "$app"
}

cmd_test() {
  local cc=${MBC_REAL_CC:-$(command -v clang || command -v cc)}
  local bin="$O/runtime/wasm_resolve_test"
  "$cc" -Wall -Wextra -Werror -O2 -DMBW_RESOLVE_TEST "$H/wasm_shell.c" -o "$bin"
  "$bin"
}

case "${1:-build}" in
  build)
    plat=${2:-$(default_platform)}
    case "$plat" in
      mac) build_mac ;;
      linux) build_linux ;;
      android) build_android ;;
      ios) build_ios ;;
      win|windows) build_win ;;
      *) echo "runtime.sh build: unknown platform $plat (use mac|linux|android|ios|win)" >&2; exit 2 ;;
    esac ;;
  compile) shift; cmd_compile "$@" ;;
  pack) shift; cmd_pack "$@" ;;
  run) shift; cmd_run "$@" ;;
  check) exec "$D/wasmhost" check "$THUNKS" $DECLS ;;
  test) cmd_test ;;
  *)
    echo "usage: runtime.sh build [mac|linux|android|ios|win] | compile | pack | run | check | test" >&2
    exit 2 ;;
esac
