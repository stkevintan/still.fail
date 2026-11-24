#!/bin/bash
# The component library's pages (src/sfstorybook) drawn offscreen under every setting of a matrix, and two such sets
# compared picture by picture, as Chromatic's modes are: on an Apple Silicon Mac (a build station: station_task), from
# any directory.
#   story-diff.sh --stories button,switch --out DIR [--wins wide,phone] [--themes light,dark] [--scales 1.0,1.3]
#                 [--hands mouse,finger] [--langs zh] [--drive FILE]
#     Each story × window × theme × size of words × input × language drawn by media.sh picture as
#     DIR/<story>-<win>-<theme>-<scale>-<hand>-<lang>.png (its scene record beside it, what the rules found in it in
#     .rules), and DIR/summary.md listing each with its rules' count. wide is 1280x800, phone 390x844, or WxH. An input
#     is the native one and the current one alike (MBUI_NATIVE_INPUT, MBUI_POINTING: a finger's sizes and its hand).
#     DRIVE is the scene's steps (media.sh's; default `wait 300`), e.g. `tap 环境` to draw the bar's 环境 panel open.
#     MBUI_FILM_SCALE (2) and the rest of media.sh's scene settings apply to every picture.
#   story-diff.sh --before DIR1 --after DIR2 --out REPORT
#     Each picture of DIR1 with one of the same name in DIR2 compared (libs/ui/scripts/imgdiff.mjs: before | after |
#     what differs, side by side, REPORT/<name>), and REPORT/summary.md: each one's share of pixels differing and the
#     rules found before and after. Fails where a picture is in one set alone.
set -eu
D="$(cd "$(dirname "$0")" && pwd)"
A="$(cd "$D/.." && pwd)"
repo="$(cd "$A/../.." && pwd)"
usage='story-diff.sh --stories KEYS --out DIR [--wins …] [--themes …] [--scales …] [--hands …] [--langs …] [--drive FILE] | --before DIR1 --after DIR2 --out REPORT'
stories='' out='' before='' after='' drive=''
wins=wide,phone themes=light,dark scales=1.0,1.3 hands=mouse,finger langs=zh
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "$usage" >&2; exit 2; }
  case "$1" in
    --stories) stories=$2 ;;
    --out) out=$2 ;;
    --wins) wins=$2 ;;
    --themes) themes=$2 ;;
    --scales) scales=$2 ;;
    --hands) hands=$2 ;;
    --langs) langs=$2 ;;
    --drive) drive=$2 ;;
    --before) before=$2 ;;
    --after) after=$2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift 2
done
[ -n "$out" ] || { echo "$usage" >&2; exit 2; }
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
out=$(abs "$out")
mkdir -p "$out"
list() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d'; }
rules_of() { if [ -f "$1" ]; then sed -n 's/^rules: \([0-9]*\) found$/\1/p' "$1" | tail -1; fi; }

if [ -n "$before" ] || [ -n "$after" ]; then
  [ -n "$before" ] && [ -n "$after" ] && [ -z "$stories" ] || { echo "$usage" >&2; exit 2; }
  before=$(abs "$before")
  after=$(abs "$after")
  command -v node >/dev/null || { echo 'story-diff: node is required' >&2; exit 2; }
  # (imgdiff.mjs's modules, where it looks for them: out/node under the directory it runs in)
  cd "$A"
  if [ ! -d out/node/node_modules/pixelmatch ] || [ ! -d out/node/node_modules/pngjs ]; then
    (mkdir -p out/node && cd out/node && { [ -f package.json ] || npm init -y >/dev/null; } && npm i pngjs@7.0.0 pixelmatch@5.3.0 >/dev/null 2>&1)
  fi
  summary="$out/summary.md"
  {
    echo '| picture | pixels differing | share | rules before | rules after |'
    echo '|---|---:|---:|---:|---:|'
  } > "$summary.part"
  missing=0
  for a in "$before"/*.png; do
    [ -e "$a" ] || continue
    name=$(basename "$a")
    b="$after/$name"
    if [ ! -f "$b" ]; then
      echo "story-diff: $name is not in $after" >&2
      missing=1
      continue
    fi
    said=$(node "$repo/libs/ui/scripts/imgdiff.mjs" "$a" "$b" "$out/$name" || true)
    px=$(printf '%s' "$said" | sed -n 's/^.*: \([0-9]*\) px differ (\([0-9.]*%\)).*$/\1/p')
    share=$(printf '%s' "$said" | sed -n 's/^.*: \([0-9]*\) px differ (\([0-9.]*%\)).*$/\2/p')
    case "$said" in *'size changed'*) share="$share (size changed)" ;; esac
    [ -n "$px" ] || { echo "story-diff: imgdiff failed on $name: $said" >&2; exit 1; }
    echo "| $name | $px | $share | $(rules_of "${a%.png}.rules") | $(rules_of "${b%.png}.rules") |" >> "$summary.part"
    echo "story-diff: $name: $px px differ ($share)"
  done
  for b in "$after"/*.png; do
    [ -e "$b" ] || continue
    [ -f "$before/$(basename "$b")" ] || { echo "story-diff: $(basename "$b") is not in $before" >&2; missing=1; }
  done
  mv -f "$summary.part" "$summary"
  echo "story-diff: $summary"
  exit "$missing"
fi

[ -n "$stories" ] || { echo "$usage" >&2; exit 2; }
work=$(mktemp -d "$out/.story-diff.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
if [ -n "$drive" ]; then
  cp "$(abs "$drive")" "$work/drive"
else
  printf 'wait 300\n' > "$work/drive"
fi
summary="$out/summary.md"
{
  echo '| picture | story | window | theme | words | input | language | rules |'
  echo '|---|---|---|---|---:|---|---|---:|'
} > "$work/summary.md"
failed=0
for story in $(list "$stories"); do
  for win in $(list "$wins"); do
    case "$win" in
      wide) size=1280x800 ;;
      phone) size=390x844 ;;
      *x*) size=$win ;;
      *) echo "story-diff: unknown window $win" >&2; exit 2 ;;
    esac
    for theme in $(list "$themes"); do
      case "$theme" in light) dark='' ;; dark) dark=1 ;; *) echo "story-diff: unknown theme $theme" >&2; exit 2 ;; esac
      for scale in $(list "$scales"); do
        for hand in $(list "$hands"); do
          case "$hand" in mouse|finger) ;; *) echo "story-diff: unknown input $hand" >&2; exit 2 ;; esac
          for lang in $(list "$langs"); do
            name="$story-$win-$theme-$scale-$hand-$lang"
            log="$out/$name.rules"
            if env MBUI_FIXTURE="stories:$story" MBUI_WIN="$size" MBUI_DARK="$dark" MBUI_FONT_SCALE="$scale" \
              MBUI_POINTING="$hand" MBUI_NATIVE_INPUT="$hand" MBUI_LOCALE="$lang" \
              MBUI_MEDIA_RECORD="$(printf '{"story_diff":"%s"}' "$name")" \
              bash "$D/media.sh" picture "$out/$name.png" "$work/drive" > "$log" 2>&1; then
              rules=$(rules_of "$log")
            else
              rules='failed'
              failed=1
              echo "story-diff: $name failed (its log: $log)" >&2
            fi
            echo "| $name.png | $story | $size | $theme | $scale | $hand | $lang | ${rules:-?} |" >> "$work/summary.md"
            echo "story-diff: $name: rules ${rules:-?}"
          done
        done
      done
    done
  done
done
mv -f "$work/summary.md" "$summary"
echo "story-diff: $summary"
exit "$failed"
