#!/bin/sh
# Android's background glyph rasterization state machine (android/app/.../GlyphsAhead.java, MBText's):
# android/text/GlyphsAheadTest.java, plain Java, no Android. Needs a JDK (javac, java).
set -eu
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/glyphsahead.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
javac -Xlint:all -Werror -d "$OUT" android/app/src/main/java/dev/mbui/GlyphsAhead.java android/text/GlyphsAheadTest.java
java -cp "$OUT" dev.mbui.GlyphsAheadTest
