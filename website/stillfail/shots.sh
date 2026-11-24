#!/usr/bin/env bash
# Capture real apps/mbui offscreen WebP screenshots for the v3 classic still.fail / youdid.wtf site.
# Usage:
#   bash website/stillfail/shots.sh
# Environment:
#   MBUI_MEDIA_RUNTIME  Optional path to a prebuilt sffilm executable (skips wasm-film-build.sh).
set -euo pipefail

export PATH="$HOME/.moon/bin:/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MBUI="$ROOT/apps/mbui"
OUT="$ROOT/website/stillfail/shots"

command -v cwebp >/dev/null || { echo "shots.sh: cwebp is required" >&2; exit 1; }
command -v sips >/dev/null || { echo "shots.sh: sips is required" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "shots.sh: ffmpeg is required" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stillfail-shots.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DRIVE="$WORK/drive"
cat > "$DRIVE" <<'EOF'
timeout 8000
wait 1200
exit
EOF

if [ -n "${MBUI_MEDIA_RUNTIME:-}" ]; then
  RUNTIME="$MBUI_MEDIA_RUNTIME"
else
  bash "$MBUI/scripts/wasm-film-build.sh" "$MBUI/out/wasm-film"
  RUNTIME="$MBUI/out/wasm-film/sffilm"
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.webp "$OUT/sizes.txt"

encode_pair() {
  local name=$1 src_png=$2 half_w=$3 fixture=$4
  local png1x="$WORK/${name}-1x.png"
  cwebp -quiet -q 88 -m 6 "$src_png" -o "$OUT/${name}.webp"
  sips --resampleWidth "$half_w" "$src_png" --out "$png1x" >/dev/null
  cwebp -quiet -q 86 -m 6 "$png1x" -o "$OUT/${name}-1x.webp"

  local dims bytes2x bytes1x
  dims="$(sips -g pixelWidth -g pixelHeight "$src_png" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{printf "%sx%s", w, h}')"
  bytes2x="$(stat -f%z "$OUT/${name}.webp")"
  bytes1x="$(stat -f%z "$OUT/${name}-1x.webp")"
  printf "%-22s %-12s 2x=%7dB  1x=%7dB  fixture=%s\n" "$name" "$dims" "$bytes2x" "$bytes1x" "$fixture" | tee -a "$OUT/sizes.txt"
}

capture() {
  local name=$1 fixture=$2 dark=$3 win=$4 scale=$5 platform=$6 input=$7 half_w=$8
  local png="$WORK/${name}.png"
  echo "→ capturing $name (fixture=$fixture dark=$dark win=$win @${scale}x)"
  env MBUI_MEDIA_RUNTIME="$RUNTIME" \
    MBUI_FIXTURE="$fixture" \
    MBUI_DARK="$dark" \
    MBUI_LOCALE="zh-CN" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" \
    MBUI_WIN="$win" \
    MBUI_FILM_SCALE="$scale" \
    MBUI_FILM_PLATFORM="$platform" \
    MBUI_NATIVE_INPUT="$input" \
    bash "$MBUI/scripts/media.sh" picture "$png" "$DRIVE" >/dev/null
  encode_pair "$name" "$png" "$half_w" "$fixture"
}

capture_right_crop() {
  local name=$1 fixture=$2 dark=$3 win=$4 crop_expr=$5 half_w=$6
  local raw_png="$WORK/${name}-raw.png"
  local crop_png="$WORK/${name}.png"
  echo "→ capturing $name (fixture=$fixture dark=$dark win=$win @2x crop=$crop_expr)"
  env MBUI_MEDIA_RUNTIME="$RUNTIME" \
    MBUI_FIXTURE="$fixture" \
    MBUI_DARK="$dark" \
    MBUI_LOCALE="zh-CN" \
    MBUI_FILM_ALLOW_CORNER_FAULTS="1" \
    MBUI_WIN="$win" \
    MBUI_FILM_SCALE="2" \
    MBUI_FILM_PLATFORM="0" \
    MBUI_NATIVE_INPUT="mouse" \
    bash "$MBUI/scripts/media.sh" picture "$raw_png" "$DRIVE" >/dev/null
  ffmpeg -v error -y -i "$raw_png" -vf "crop=${crop_expr}" -frames:v 1 "$crop_png"
  encode_pair "$name" "$crop_png" "$half_w" "${fixture}:crop"
}

# 1. Hero Tab 1: chat-md (1120x700 @2x = 2240x1400, 1x = 1120w)
capture "chat-dark"     "chat-md"              1 "1120x700" 2 0 "mouse" 1120
capture "chat-light"    "chat-md"              0 "1120x700" 2 0 "mouse" 1120

# 2. Hero Tab 2: chat-view-side-mbui (1120x700 @2x = 2240x1400, 1x = 1120w)
capture "viz-dark"      "chat-view-side-mbui"  1 "1120x700" 2 0 "mouse" 1120
capture "viz-light"     "chat-view-side-mbui"  0 "1120x700" 2 0 "mouse" 1120

# 3. Hero Tab 3: settings-station (1120x700 @2x = 2240x1400, 1x = 1120w)
capture "station-dark"  "settings-station"     1 "1120x700" 2 0 "mouse" 1120
capture "station-light" "settings-station"     0 "1120x700" 2 0 "mouse" 1120

# 4. Bento Card 1: 1:1 right-pane terminal crop (1160x620 @2x = 2320x1240 -> crop 714x1240 from x=1606, y=0 = 357x620 logical)
capture_right_crop "crop-terminal-dark"  "chat-terminal-side" 1 "1160x620" "714:1240:1606:0" 357
capture_right_crop "crop-terminal-light" "chat-terminal-side" 0 "1160x620" "714:1240:1606:0" 357

# 5. Bento Card 2: 1:1 right-pane station telemetry crop (1160x620 @2x = 2320x1240 -> crop 714x1240 from x=1606, y=0 = 357x620 logical)
capture_right_crop "crop-station-dark"   "chat-station-side"  1 "1160x620" "714:1240:1606:0" 357
capture_right_crop "crop-station-light"  "chat-station-side"  0 "1160x620" "714:1240:1606:0" 357

# 6. Mobile phone shots: webdemo (390x720 @3x = 1170x2160, 1x = 390w)
capture "mobile-dark"   "webdemo"              1 "390x720"  3 1 "finger" 390
capture "mobile-light"  "webdemo"              0 "390x720"  3 1 "finger" 390

echo "✓ done: $OUT/sizes.txt"
