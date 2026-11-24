#!/bin/bash
# Words the hosts' text is weighed by (src/kitdemo/gallery/dl_print_wbtest.mbt words_shown: the same lines dark on
# light and light on dark) drawn offscreen by this host's renderer (src/render) at 1, 1.5 and 2: in the host's own
# faces, and in each font file of WORDS_FONTS (a directory: each <name>.ttf given as faces 1 and 2, as an app gives its
# words' face, Han falling back to the host's where it has none). Pictures for people to set one host's text beside
# another's: no reference, nothing checked.
#   WORDS_FONTS=<dir> scripts/render_words.sh mac|windows      out/words/<name>-<scale>.png (name "own": no face given)
# (On Windows: mbui-render-windows run by hand, gh workflow run mbui-render-windows.yml --ref <branch>, draws them with Inter's and Noto Sans SC's variable files: its words-windows.)
set -e
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
. "$D/render_dl.sh"
cd "$D/.."
O=out/words
rm -rf $O; mkdir -p $O
# (the one the renderer's build printed beside its others, render_windows.sh build; else printed here)
if [ -s out/render/words.dl ]; then cp out/render/words.dl $O/words.dl; else render_words_dl $O; fi
case "${1:-}" in
  mac)
    APP=render bash scripts/mac.sh build >/dev/null
    EXE=./_build/native/release/build/render/render.exe
    winpath() { printf '%s' "$PWD/$1"; } ;;
  windows)
    [ -f out/win/mod/_build/native/release/build/render/render.exe ] || APP=render bash "$D/win.sh" build
    EXE=out/win/mod/_build/native/release/build/render/render.exe
    winpath() { cygpath -w "$PWD/$1"; } ;;
  *) echo "render_words: mac or windows"; exit 2 ;;
esac
sets="own"
for f in "${WORDS_FONTS:-/nonexistent}"/*.ttf; do [ -f "$f" ] && sets="$sets $(basename "$f" .ttf)"; done
for s in 1 1.5 2; do
  sed "s/^window \([0-9.]*\) \([0-9.]*\) [0-9.]*$/window \1 \2 $s/" $O/words.dl > $O/words-$s.dl
  for n in $sets; do
    faces=""
    if [ "$n" != own ]; then
      f="$WORDS_FONTS/$n.ttf"
      [ "$1" = windows ] && f=$(cygpath -w "$f")
      faces="1:$f;2:$f"
    fi
    MBUI_DL_PEN=1 MBUI_FACES="$faces" MBUI_DL="$(winpath $O/words-$s.dl)" MBUI_DL_PNG="$(winpath $O/$n-$s.png)" $EXE
  done
done
ls -la $O
