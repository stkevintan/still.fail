#!/bin/sh
# Every C call mbui's film makes of a native host that is film's alone (src/film/film_native.mbt's `= "mbf_…"`) is
# written by Apple's film (src/host/apple_film.m), Linux's (src/host/linux_film.c) and the hosts' with none
# (src/host/film_none.c), so a program that takes film in links on every host; and film asks a host's renderer only
# through such calls of its own, never by the renderer's name (another host may lack it, or have it otherwise: Windows' mb_render_set_size takes five).
D="$(cd "$(dirname "$0")/.." && pwd)"
calls=$(sed -n 's/.*extern "C" fn .*= "\([A-Za-z0-9_]*\)".*/\1/p' "$D/src/film/film_native.mbt")
bad=0
for c in $calls; do
  case "$c" in
    mbf_*)
      for f in apple_film.m linux_film.c film_none.c; do
        grep -Eq "^[A-Za-z].*[ *]$c\(" "$D/src/host/$f" || { echo "film: $c is not in src/host/$f" >&2; bad=1; }
      done
      ;;
    # (the renderer's, which every host has with this signature)
    mb_render_init_offscreen | mb_render_draw_timed) ;;
    *) echo "film: $c is a host's own name: call it through an mbf_ call (src/host/apple_film.m, linux_film.c, film_none.c)" >&2; bad=1 ;;
  esac
done
exit $bad
