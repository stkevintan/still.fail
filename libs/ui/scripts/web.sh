#!/bin/bash
# Build the browser version (APP=demo|photos): scripts/web.sh build | bundle [OUT] | test
# MODE=release|debug (default release; debug builds without --release, for a quick look while working). MODE=debug or
# MBUI_QUICK=1 leaves out bundle's brotli (quality 11: seconds), unless MBUI_WEB_BROTLI says otherwise.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
# MBUI_APP_MOD: an app of a module outside this repository (its moon.work naming mbui; scripts/android.sh says more)
ROOT=$(cd "$D/.." && pwd)
CALLER_PWD=$PWD
# (MBUI_OUT: the build there, out/ of the module built otherwise; the tools it runs built under MBUI_TOOLS_OUT,
# scripts/mbc, for an app of another module its out/mbui-tools: mbui left as it is)
O=out; [ -z "${MBUI_OUT:-}" ] || O=$(mkdir -p "$MBUI_OUT" && cd "$MBUI_OUT" && pwd)
cd "${MBUI_APP_MOD:-$ROOT}"
if [ -n "${MBUI_OUT:-}" ]; then export MBUI_TOOLS_OUT=${MBUI_TOOLS_OUT:-$O/tools}
elif [ -n "${MBUI_APP_MOD:-}" ]; then export MBUI_TOOLS_OUT=${MBUI_TOOLS_OUT:-$PWD/out/mbui-tools}; fi
OUT=$O/web
APP=${APP:-demo}
MODE=${MODE:-release}
FLAG=; [ "$MODE" = release ] && FLAG=--release
QUICK=${MBUI_QUICK:-0}; [ "$MODE" = debug ] && QUICK=1
# (milliseconds now: Node, which bundle needs too)
now_ms() { node -p "Date.now()"; }
[ -z "${MBUI_WEB_HOOK:-}" ] || . "$MBUI_WEB_HOOK"
case "${1:-build}" in
  build)
    T0=$(now_ms)
    moon build --target js $FLAG src/$APP 2>&1 | "$D/chk" errs
    mkdir -p $OUT
    cp $(pkg_build $APP js $MODE)/$APP.js $OUT/demo.js
    if [ $APP = photos ]; then
      # the made-up pictures (scripts/test_images.swift --gallery)
      gallery_pictures
      mkdir -p $OUT/photos
      cp -p out/pictures/*.jpg $OUT/photos/
    fi
    cp $ROOT/web/index.html $ROOT/web/host.js $OUT/
    if type app_build >/dev/null 2>&1; then app_build "$OUT"; fi
    T1=$(now_ms)
    echo "built ($MODE) in $(node -p "(($T1 - $T0) / 1000).toFixed(2)") s"
    ls -la $OUT
    gzip -9 -c $OUT/demo.js | wc -c | xargs echo "demo.js gzip bytes:"
    ;;
  bundle)
    bash "$D/web.sh" build >/dev/null
    if [ -n "${2:-}" ]; then
      DST=$(cd "$CALLER_PWD" && mkdir -p "$2" && cd "$2" && pwd)
    else
      DST=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
    fi
    # minified (MoonBit's names are long) by esbuild, the version pinned here: prefer MBUI_ESBUILD, PATH,
    # current module node_modules, and only fall back to parent monorepo node_modules before npx.
    ESBUILD=0.28.2
    es=""
    if [ -n "${MBUI_ESBUILD:-}" ] && [ -x "$MBUI_ESBUILD" ]; then
      es="$MBUI_ESBUILD"
    elif command -v esbuild >/dev/null 2>&1; then
      es=$(command -v esbuild)
    else
      for cand in \
        "$PWD"/node_modules/.bin/esbuild \
        "$PWD"/node_modules/.pnpm/esbuild@$ESBUILD/node_modules/esbuild/bin/esbuild \
        "$ROOT"/node_modules/.bin/esbuild \
        "$ROOT"/node_modules/.pnpm/esbuild@$ESBUILD/node_modules/esbuild/bin/esbuild \
        "$ROOT"/../../node_modules/.pnpm/esbuild@$ESBUILD/node_modules/esbuild/bin/esbuild \
        "$ROOT"/../../station/node_modules/.pnpm/esbuild@*/node_modules/esbuild/bin/esbuild; do
        if [ -x "$cand" ]; then
          es="$cand"
          break
        fi
      done
    fi
    if [ -n "$es" ]; then
      "$es" --minify "$OUT/demo.js" --outfile="$DST/app.js" --log-level=error
    else
      npx --yes esbuild@$ESBUILD --minify "$OUT/demo.js" --outfile="$DST/app.js" --log-level=error
    fi
    [ "$ROOT/web/host.js" -ef "$DST/host.js" ] || cp "$ROOT/web/host.js" "$DST/host.js"
    if [ "${MBUI_WEB_BROTLI:-$([ "$QUICK" = 1 ] && echo 0 || echo 1)}" != 0 ]; then
      for f in app.js host.js; do
        node -e 'const z = require("node:zlib"), fs = require("node:fs"), [src, dst] = process.argv.slice(1), b = fs.readFileSync(src);
fs.writeFileSync(dst, z.brotliCompressSync(b, { params: { [z.constants.BROTLI_PARAM_QUALITY]: 11,
  [z.constants.BROTLI_PARAM_LGWIN]: 24, [z.constants.BROTLI_PARAM_SIZE_HINT]: b.length } }))' "$DST/$f" "$DST/$f.br"
      done
    fi
    if type app_bundle >/dev/null 2>&1; then app_bundle "$DST"; fi
    ls -la "$DST"
    gzip -9 -c "$DST/app.js" | wc -c | xargs echo "app.js gzip bytes:"
    [ ! -f "$DST/app.js.br" ] || { wc -c < "$DST/app.js.br" | xargs echo "app.js brotli bytes (sent):"; }
    ;;
  test)
    mkdir -p out/node
    if [ ! -d out/node/node_modules/playwright ]; then
      (cd out/node && npm init -y >/dev/null && npm i playwright@latest >/dev/null 2>&1)
      (cd out/node && npx playwright install chromium >/dev/null 2>&1)
    fi
    NODE_PATH=$PWD/out/node/node_modules node scripts/web-test.mjs "${@:2}"
    ;;
esac
