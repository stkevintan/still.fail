#!/bin/bash
# The component library's page (src/sfstories over src/sfstorybook: each part of libs/ui's src beside its states) built for the browser into OUT,
# as cloud/wrangler.kit.jsonc serves it (kit.monoid.zone): mbui's web host, the app minified as mbui's scripts/web.sh
# bundle does, the files it carries, the sources it shows, and a page that gives them to it before it starts.
#   scripts/kit-web.sh OUT
set -e
D="$(cd "$(dirname "$0")" && pwd)"
out=$(mkdir -p "${1:?scripts/kit-web.sh OUT}" && cd "$1" && pwd)
. "$D/env.sh"
rm -rf "$out/assets"
bash "$D/assets" "$MBUI_APP_MOD" "$out/assets" > /dev/null
# (Inter, the face the app's words are in, as the web's pages carry it; the system's faces draw where it is not there)
inter=$(ls "$SF_SRC"/node_modules/.pnpm/@fontsource-variable+inter@*/node_modules/@fontsource-variable/inter/files/inter-latin-wght-normal.woff2 2>/dev/null | tail -1)
[ -z "$inter" ] || cp "$inter" "$out/assets/inter.woff2"
# (the sources the page shows: stories.mbt, whose lines each state's code is cut from, and each file of the library
# (libs/ui/src/controls) it names, whose functions it lists; each after a line naming it as sf/<file>,
# src/sfstorybook/sources.mbt)
lib=$(cd "$MBUI_APP_MOD/../../libs/ui/src/controls" && pwd)
motion_lib=$(cd "$MBUI_APP_MOD/../../libs/ui/src/motion" && pwd)
ui_lib=$(cd "$MBUI_APP_MOD/../../libs/ui/src/ui" && pwd)
(cd "$MBUI_APP_MOD/src" && for f in sfstorybook/stories.mbt sfstorybook/stories_motion.mbt motion/catalog.mbt motion/tools.mbt motion/shared.mbt motion/zoom.mbt motion/pull.mbt motion/deform.mbt motion/rolling.mbt motion/text_morph.mbt motion/hero_flight.mbt motion/reveal_node.mbt motion/choreography.mbt ui/nav_transition.mbt $(grep -o '"[a-z_]*\.mbt"' sfstorybook/stories.mbt sfstorybook/stories_motion.mbt | tr -d '"' | sort -u | sed 's|^|sf/|'); do
  case $f in sf/*) at=$lib/${f#sf/} ;; motion/*) at=$motion_lib/${f#motion/} ;; ui/*) at=$ui_lib/${f#ui/} ;; *) at=$f ;; esac
  [ -f "$at" ] || continue
  printf '//@@ %s\n' "$f"
  cat "$at"
done) > "$out/assets/sources.txt"
cp "$D/kit.html" "$out/index.html"
APP=sfstories MBUI_WEB_BROTLI=0 exec bash "$MBUI_DIR/scripts/web.sh" bundle "$out"
