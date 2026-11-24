#!/bin/bash
# Build the Linux app and run it, on Linux with MoonBit, a C compiler and GTK 4's development files (GTK 4.12 or
# later, epoxy, Pango, cairo, gdk-pixbuf, libsoup 3; Ubuntu 24.04: libgtk-4-dev libsoup-3.0-dev):
#   MODE=release|debug APP=demo|kitdemo|… scripts/linux.sh build | run | script ime | shot | bench
# moon.pkg cannot choose native stubs per system, so the build runs on a copy of the module in out/linux/mod whose host
# lists the linux_* stubs (compiled with GTK's flags) and whose apps link GTK's libraries instead of Apple's
# frameworks. MBUI_APP_MOD=<a module outside this repository whose moon.work names mbui> (still.fail's apps/mbui): its
# app APP, built from a copy of it in out/linux/app whose workspace names that copy of mbui instead, its apps linking
# GTK too; a package whose stubs are Apple's own (.m: a core host's) takes its linux_engine.c in their place where it
# has one, else is left out. MBUI_OUT=<a directory>: all of it there in place of out/ (scripts/ext-film.sh says why).
set -e
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
APPMOD=${MBUI_APP_MOD:+$(cd "$MBUI_APP_MOD" && pwd)}
# (MBUI_OUT: where the copies, the build and what it says go, in place of mbui's out: mbui left as it is, a
# repository's read-only submodule; the tools it runs built beside them, or for an app of another module in its
# out/mbui-tools: MBUI_TOOLS_OUT, scripts/mbc)
if [ -n "${MBUI_OUT:-}" ]; then
  O=$(mkdir -p "$MBUI_OUT" && cd "$MBUI_OUT" && pwd)
  export MBUI_TOOLS_OUT=${MBUI_TOOLS_OUT:-$O/tools}
else
  O=out
  [ -z "$APPMOD" ] || export MBUI_TOOLS_OUT=${MBUI_TOOLS_OUT:-$APPMOD/out/mbui-tools}
fi
cd "$D/.."
MODE=${MODE:-release}
FLAG=""; [ "$MODE" = release ] && FLAG=--release
PKG=${APP:-demo}
M=$O/linux/mod
EXE=$M/_build/native/$MODE/build/$PKG/$(basename $PKG).exe
AM=$O/linux/app
SM=$O/linux/stage/mod
SA=$O/linux/stage/app
if [ -n "$APPMOD" ]; then
  EXE=$AM/_build/native/$MODE/build/$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$APPMOD/moon.mod")/$PKG/$(basename $PKG).exe
fi
if [ -n "${MBUI_WASM_THUNKS:-}" ]; then
  WASM_OUT=${MBUI_WASM_OUT:-$O/linux/wasm-shell}
  EXE=$WASM_OUT/mbui-runtime
fi
[ -z "${MBUI_LINUX_HOOK:-}" ] || . "$MBUI_LINUX_HOOK"
# GTK 4 and what the host files use beside it; an app's own (MBUI_LINUX_CFLAGS, MBUI_LINUX_LDFLAGS) after them
LIBS="gtk4 epoxy pangocairo pangoft2 fontconfig gdk-pixbuf-2.0 libsoup-3.0 zlib"
CFLAGS="$(pkg-config --cflags $LIBS) ${MBUI_LINUX_CFLAGS:-}"
LDFLAGS="$(pkg-config --libs $LIBS) -lm -lpthread ${MBUI_LINUX_LDFLAGS:-}"
STUBS='"linux_app.c", "linux_render.c", "linux_text.c", "linux_image.c", "linux_views.c", "linux_stream.c", "linux_listen.c", "linux_browser_login.c", "linux_film.c"'

WT_VERSION=50.0.1
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | awk '{print $1}'
  else shasum -a 256 "$@" | awk '{print $1}'; fi
}

wasmtime_linux_lib() {
  local arch sha
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 sha=e2c0c26e1aef52f82f0b9918ad6f34cc30f4b557aee3e261cb127a9462be8f4d ;;
    aarch64|arm64) arch=aarch64 sha=1a36140a016a9cc098f02a37bb0cc7be6451032861ba70049127928d2f31ef84 ;;
    *) echo "linux.sh: unsupported arch $(uname -m) for wasmtime" >&2; exit 1 ;;
  esac
  WT=$O/wasmtime-v$WT_VERSION-$arch-linux-c-api
  if [ ! -f "$WT/lib/libwasmtime.so" ]; then
    mkdir -p "$O"
    local tar_file="$O/wasmtime-v$WT_VERSION-$arch-linux-c-api.tar.xz"
    curl -fsSL --retry 3 -o "$tar_file" \
      "https://github.com/bytecodealliance/wasmtime/releases/download/v$WT_VERSION/wasmtime-v$WT_VERSION-$arch-linux-c-api.tar.xz"
    [ "$(sha256_of "$tar_file")" = "$sha" ] \
      || { rm -f "$tar_file"; echo "linux.sh: wasmtime: checksum mismatch" >&2; exit 1; }
    tar xf "$tar_file" -C "$O"
    rm -f "$tar_file"
  fi
}

build_wasm_shell() {
  mkdir -p "$WASM_OUT/obj"
  wasmtime_linux_lib
  cp -p "$WT/lib/libwasmtime.so" "$WASM_OUT/libwasmtime.so"
  local moon_root cc wflags f o sum
  moon_root=${MOON_HOME:-$(dirname "$(dirname "${MBUI_REAL_MOON:-$(command -v moon)}")")}
  [ -f "$moon_root/lib/runtime/runtime.c" ] || { echo "linux.sh: missing MoonBit runtime at $moon_root/lib/runtime/runtime.c" >&2; exit 1; }
  cc=${MBC_REAL_CC:-$(command -v clang || command -v cc)}
  wflags="-O2 -fwrapv -fno-strict-aliasing -Wno-unused-value -I$moon_root/include -I$WT/include -Isrc/host $CFLAGS"
  local srcs=(
    src/host/linux_app.c src/host/linux_render.c src/host/linux_text.c src/host/linux_image.c
    src/host/linux_views.c src/host/linux_stream.c src/host/linux_listen.c
    src/host/linux_browser_login.c src/host/linux_film.c
    src/host/wasm_shell.c "$MBUI_WASM_THUNKS"
  )
  for f in ${MBUI_WASM_STUBS:-}; do srcs+=("$f"); done
  srcs+=("$moon_root/lib/runtime/runtime.c")
  local objs=() pids=()
  for f in "${srcs[@]}"; do
    o="$WASM_OUT/obj/$(echo "$f" | tr '/.' '__').o"
    objs+=("$o")
    sum=$( (echo "$cc $wflags"; cat "$f" src/host/*.h "$moon_root/include/moonbit.h" 2>/dev/null) | sha256_of )
    if [ -f "$o" ] && [ "$(cat "$o.sum" 2>/dev/null)" = "$sum" ]; then continue; fi
    (rm -f "$o.sum"; "$cc" $wflags -c "$f" -o "$o" && echo "$sum" > "$o.sum") &
    pids+=($!)
  done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || exit 1; done
  "$cc" -o "$EXE" "${objs[@]}" "-L$WASM_OUT" -lwasmtime '-Wl,-rpath,$ORIGIN' $LDFLAGS
}

# A package's moon.pkg for Linux: its native stubs compiled with GTK's flags (Objective-C's ARC flag dropped), a
# main's linking GTK's libraries in place of Apple's frameworks.
linux_pkg() {
  sed -e "s|-fobjc-arc *||" \
      -e "s|\"stub-cc-flags\": *\"\([^\"]*\)\"|\"stub-cc-flags\": \"\1 $CFLAGS\"|" \
      -e "s|\"cc-link-flags\": *\"[^\"]*-framework[^\"]*\"|\"cc-link-flags\": \"$LDFLAGS\"|" "$1"
}

# Each build's copies made afresh in out/linux/stage, then mirrored into out/linux/mod and out/linux/app (scripts/mbc
# mirror: a file only written when its content changed), so that moon, which goes by mtimes, builds anew only what
# changed.
sync() {
  rm -rf $SM && mkdir -p $SM/src
  cp -p moon.mod $SM/
  cp -rp src/. $SM/src/
  linux_pkg src/host/moon.pkg | sed -e "s/\"native-stub\": *\[[^]]*\]/\"native-stub\": [ $STUBS ]/" > $SM/src/host/moon.pkg
  for p in src/*/moon.pkg; do
    grep -q '"is-main"' $p && linux_pkg $p > $SM/$p
  done
  if ! grep -q linux_app.c $SM/src/host/moon.pkg || grep -q -e -framework -e '\.m"' $SM/src/*/moon.pkg; then
    echo "linux.sh: src/host/moon.pkg or an app's moon.pkg no longer has the expected shape" >&2
    exit 1
  fi
  "$D/mbc" mirror $SM $M
  [ -z "$APPMOD" ] || sync_app
}

# the other module's copy: its sources, its workspace naming the copy of mbui above, its apps linking GTK
sync_app() {
  rm -rf $SA && mkdir -p $SA
  cp -p "$APPMOD/moon.mod" $SA/
  cp -rp "$APPMOD/src" $SA/src
  # (the app's other members, a module it pulls in beside it, where they are)
  sh "$D/stage_work.sh" "$APPMOD" ../mod . > $SA/moon.work
  # (its packages with Apple's own native stubs, a core host's: their Linux one, linux_engine.c, instead, else left
  # out)
  for p in $(grep -l '\.m"' $SA/src/*/moon.pkg 2>/dev/null); do
    if [ -f "$(dirname $p)/linux_engine.c" ]; then
      linux_pkg $p | sed -e 's/"[^"]*\.m"/"linux_engine.c"/' -e 's/-Iout\/core\/ghostty-vt\/include *//' > $p.linux
      mv $p.linux $p
    else
      rm -rf "$(dirname $p)"
    fi
  done
  for p in $SA/src/*/moon.pkg; do
    grep -q '"is-main"' $p && { linux_pkg $p > $p.linux; mv $p.linux $p; }
  done
  "$D/mbc" mirror $SA $AM
}

# (the program as a command: out's is a path from here)
case $EXE in /*) X=$EXE ;; *) X=./$EXE ;; esac
case "${1:-build}" in
  build)
    if type app_prebuild >/dev/null 2>&1; then app_prebuild; fi
    if [ -n "${MBUI_WASM_THUNKS:-}" ]; then
      build_wasm_shell
    else
      sync
      # moon's build, with the C that moonc generates split and compiled in parallel (scripts/mbc: a `cc` first on PATH
      # that moon uses for every C step, all but that one passed through; MBC_SPLIT=0 compiles it whole)
      rm -f $O/mbc.log
      export MBC_REAL_CC=${MBC_REAL_CC:-$(command -v clang || command -v cc)}
      B=$M; [ -z "$APPMOD" ] || B=$AM
      code=0
      (cd $B && PATH="$("$D/mbc" shim "$(cd ../.. && pwd)/mbc/linux"):$PATH" MBC_LOG="$(cd ../.. && pwd)/mbc.log" \
        moon build --target native $FLAG src/$PKG) || code=$?
      cat $O/mbc.log 2>/dev/null || true
      [ $code = 0 ] || exit $code
    fi
    if type app_postbuild >/dev/null 2>&1; then app_postbuild; fi
    ls -la $EXE ;;
  run)
    on_screen "$X" ;;
  script)
    rm -rf $O/$2 && mkdir -p $O/$2
    MBUI_SCRIPT=$2 MBUI_SHOT_DIR=$(cd $O/$2 && pwd) on_screen "$X" ;;
  shot)
    rm -rf $O/shot-linux && mkdir -p $O/shot-linux
    MBUI_BENCH=${MBUI_BENCH:--1} MBUI_SCRIPT=shot MBUI_SHOT_DIR=$(cd $O/shot-linux && pwd) on_screen "$X" ;;
  bench)
    MBUI_BENCH=1 on_screen "$X" ;;
  *)
    if type app_cmd >/dev/null 2>&1; then app_cmd "$@"; else echo "linux.sh: no command $1" >&2; exit 1; fi ;;
esac
