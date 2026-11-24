#!/bin/bash
# Type-check every target; print errors only. First the determinism lint (tools/detlint): its
# report, and a failure stops here; then the hosts' H.264 conversion (scripts/avc_test.c) and log files
# (scripts/log_files_test.c), Android's frame waiting (scripts/frame_mail_test.c, scripts/framemail_test.sh), and the
# renderers' own tests (scripts/apple_render_test.m on a Mac, scripts/gles_render_test.c on Linux) and Core Text's
# (scripts/apple_text_test.m).
D="$(cd "$(dirname "$0")" && pwd)"
"$D/detlint" || exit 1
# every call mbui's film makes of a native host answered by Apple's film, Linux's and the hosts' with none
sh "$D/film_calls.sh" || exit 1
# the H.264 conversion the hosts share (src/host/avc.h), as still.fail's Android AvcTest tests it
mkdir -p "$D/../out"
cc -Wall -I "$D/../src/host" "$D/avc_test.c" -o "$D/../out/avc_test" && "$D/../out/avc_test" || exit 1
# what a host's log files may keep, the queue before them, which files (src/host/log_files.h)
cc -Wall -I "$D/../src/host" "$D/log_files_test.c" -o "$D/../out/log_files_test" && "$D/../out/log_files_test" || exit 1
# the frame waiting between Android's app thread and its GL thread (src/host/frame_mail.h; its Java side, FrameMail)
cc -Wall -I "$D/../src/host" "$D/frame_mail_test.c" -lm -o "$D/../out/frame_mail_test" && "$D/../out/frame_mail_test" || exit 1
sh "$D/framemail_test.sh" || exit 1
sh "$D/touchmoves_test.sh" || exit 1
. "$D/env.sh"
if [ "$(uname)" = Darwin ]; then
  cc -Wall -fobjc-arc -I "$D/../src/host" -I "$MOON_HOME/include" "$D/apple_render_test.m" \
    -framework Foundation -framework QuartzCore -framework Metal -framework CoreGraphics -framework ImageIO \
    -o "$D/../out/apple_render_test" && "$D/../out/apple_render_test" || exit 1
  # (Core Text's own: a glyph's phases, a moving line's gaps, digits one width, an ellipsis's cut; MBUI_TEST_FACE a face's
  # file whose digits are held to one width too, as an app gives one)
  cc -Wall -Werror -fobjc-arc -I "$D/../src/host" -I "$MOON_HOME/include" "$D/apple_text_test.m" \
    -framework Foundation -framework AppKit -framework CoreText -framework CoreGraphics -framework ImageIO \
    -o "$D/../out/apple_text_test" && "$D/../out/apple_text_test" ${MBUI_TEST_FACE:+"$MBUI_TEST_FACE"} || exit 1
  cc -Wall -Werror -fobjc-arc -I "$D/../src/host" "$D/ios_ime_test.m" \
    -framework Foundation -framework CoreGraphics -o "$D/../out/ios_ime_test" && "$D/../out/ios_ime_test" || exit 1
  cc -Wall -Werror -fobjc-arc -I "$D/../src/host" -I "$MOON_HOME/include" "$D/mac_app_test.m" \
    -framework Cocoa -framework QuartzCore -framework Metal -framework UserNotifications -framework Security \
    -o "$D/../out/mac_app_test" && "$D/../out/mac_app_test" || exit 1
fi
# the GLES renderer's window path (src/host/gles_render.h: Android's and Linux's), on EGL's surfaceless platform
if [ "$(uname)" = Linux ] && pkg-config --exists epoxy zlib; then
  cc -Wall -Wno-unused-function -I "$D/../src/host" -I "$MOON_HOME/include" "$D/gles_render_test.c" \
    $(pkg-config --cflags --libs epoxy zlib) -lm -o "$D/../out/gles_render_test" &&
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$D/../out/gles_render_test" || exit 1
fi
for t in ${TARGETS:-native}; do
  echo "=== $t"
  moon check --target $t --output-json 2>&1 | "$D/chk" errs
done
