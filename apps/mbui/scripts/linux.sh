#!/bin/bash
# The Linux apps: mbui's scripts/linux.sh (build | run | script NAME | shot) on this module's apps (APP=stillfail by
# default; sffix), on Linux with MoonBit, clang and GTK 4's development files (mbui's linux.sh says which).
# stillfail has the still.fail core in it (src/stillfail/linux_engine.c → src/host/linux_core.c): the engine and the
# shell prebuilt for Linux (this checkout's scripts/native.ts parts `engine` and `shell`, linux-x64 or linux-arm64, this
# machine's: from the release native-artifacts, or built here), linked by name and found beside the app as it loads
# ($ORIGIN), the engine's C API (engine/engine.h) on the include path, the desktop's Secret Service through libsecret;
# and the core as Hermes bytecode (scripts/core.sh hermes, with the engine's own hermesc). After a build all three are
# put beside the app's executable.
#   MBUI_LINUX_CORE=0 scripts/linux.sh build   the app alone, the engine and the shell put beside it
#   scripts/linux.sh core                      the core's bytecode (out/core/core.hbc)
#   scripts/linux.sh put                       the core's bytecode, the engine and the shell put beside the app
AD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$AD/env.sh"
export APP=${APP:-stillfail}
if [ -n "${MBUI_IN_LINUX_SH:-}" ]; then
  if [ "$APP" = stillfail ]; then
    t=linux-$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')
    shell=$(cd "$SF_SRC" && node scripts/native.ts path shell $t) || exit 1
    ghostty_vt=$(cd "$SF_SRC" && node scripts/native.ts path ghostty-vt $t) || exit 1
    if [ "${STILLFAIL_CORE:-}" = pion ]; then
      pion_core_dir="$A/out/pion-core/$t"
      export MBUI_LINUX_CFLAGS="-DSTILLFAIL_CORE_PION -I$MBUI_DIR/src/host -I$ghostty_vt/include"
      export MBUI_LINUX_LDFLAGS="$pion_core_dir/libpion_core.a -L$shell -L$ghostty_vt/lib -lstillfail_shell -lghostty-vt -lpthread -lm -ldl -Wl,-rpath,\$ORIGIN"
    else
      engine=$(cd "$SF_SRC" && node scripts/native.ts path engine $t) || exit 1
      export MBUI_LINUX_CFLAGS="-I$A/engine -I$MBUI_DIR/src/host -I$ghostty_vt/include $(pkg-config --cflags libsecret-1)"
      export MBUI_LINUX_LDFLAGS="-L$engine -L$shell -L$ghostty_vt/lib -lstillfail_engine -lstillfail_shell -lghostty-vt $(pkg-config --libs libsecret-1) -Wl,-rpath,\$ORIGIN"
    fi
  fi
  core() {
    if [ "${STILLFAIL_CORE:-}" = pion ]; then
      sh "$AD/pion-core.sh" build "$t"
    else
      HERMESC="$engine/hermesc" bash "$AD/core.sh" hermes
    fi
  }
  # put [core]: the engine, the shell and libghostty-vt beside the app's executable, the core's bytecode too when asked
  put() {
    . "$MBUI_DIR/scripts/env.sh"
    # (mbui's linux.sh builds this module in its copy, out/linux/app beside mbui's own)
    dir=$MBUI_DIR/out/linux/app/$(cd "$MBUI_DIR/out/linux/app" && pkg_build $APP native ${MODE:-release})
    if [ "${STILLFAIL_CORE:-}" = pion ]; then
      cp "$shell/libstillfail_shell.so" "$ghostty_vt/lib/libghostty-vt.so.1" "$dir/" || return 1
    else
      # (the engine's libraries: its own, and ICU's it carries; libghostty-vt by its SONAME)
      cp "$engine"/lib*.so* "$shell/libstillfail_shell.so" "$ghostty_vt/lib/libghostty-vt.so.1" "$dir/" || return 1
      [ "${1:-}" != core ] || cp "$A/out/core/core.hbc" "$dir/" || return 1
    fi
    ls -la "$dir"
  }
  app_prebuild() {
    if [ "$APP" = stillfail ]; then
      if [ "${STILLFAIL_CORE:-}" = pion ]; then
        if [ "${MBUI_LINUX_CORE:-1}" != 0 ] || [ ! -f "$pion_core_dir/libpion_core.a" ]; then core || exit 1; fi
      elif [ "${MBUI_LINUX_CORE:-1}" != 0 ]; then
        core || exit 1
      fi
    fi
  }
  app_postbuild() {
    if [ "$APP" = stillfail ]; then
      if [ "${MBUI_LINUX_CORE:-1}" != 0 ]; then put core || exit 1; else put || exit 1; fi
    fi
  }
  app_cmd() {
    case "$1" in
      core) core ;;
      put) put core ;;
      *) echo "linux.sh: no command $1" >&2; exit 1 ;;
    esac
  }
  return 0 2>/dev/null || exit 0
fi
export MBUI_IN_LINUX_SH=1 MBUI_LINUX_HOOK="$AD/linux.sh"
exec bash "$MBUI_DIR/scripts/linux.sh" "$@"
