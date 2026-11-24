#!/bin/sh
# Android ACTION_MOVE coalescing between UI thread and logic thread (android/app/.../TouchMoves.java, MBView's):
# android/touch/TouchMovesTest.java, plain Java, no Android. Needs a JDK (javac, java).
set -eu
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/touchmoves.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
javac -Xlint:all -Werror -d "$OUT" android/app/src/main/java/dev/mbui/TouchMoves.java android/touch/TouchMovesTest.java
java -cp "$OUT" dev.mbui.TouchMovesTest
