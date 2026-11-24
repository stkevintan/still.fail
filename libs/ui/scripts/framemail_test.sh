#!/bin/sh
# What Android's two threads hand each other (android/app/.../FrameMail.java, MBView's) step by step:
# android/mail/FrameMailTest.java, plain Java, no Android: the newest frame drawn, the GL context's tasks in their order
# among the frames, what lets go of a frame's pictures only once a frame made after it is shown, and no frame made for
# a GL context gone drawn in the new one. Needs a JDK (javac, java).
set -eu
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/framemail.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
javac -Xlint:all -Werror -d "$OUT" android/app/src/main/java/dev/mbui/FrameMail.java android/mail/FrameMailTest.java
java -cp "$OUT" dev.mbui.FrameMailTest
