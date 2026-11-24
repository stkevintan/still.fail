#!/bin/bash
# The macOS apps: mbui's scripts/mac.sh (build | run | script NAME | shot | bench) on this module's apps (APP=stillfail
# by default; sffix, coredemo, photos, books). stillfail and coredemo have the still.fail core in them, in Hermes:
# Hermes's framework, the engine and the Rust shell's .a (scripts/core.sh apple-native) made first when missing or
# stale (a new engine links the app again), the core's bytecode beside the app's compile (only its run and its bundle
# take it: a core changed was ~26 s before the compile on CI's Mac, 2026-10-24); `login` runs the core demo
# signing in the way a command-line tool does (MBUI_AUTH_LOGIN): what a station's remote login runs on this machine.
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
export APP=${APP:-stillfail}
sha256_of() { if command -v shasum > /dev/null; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
# What the app's link takes of the core's native parts (scripts/core.sh apple-native), by content: the engine's inputs
# (engine()'s list there, its compiler, Hermes's headers) rather than libmbui_core.a, whose ar writes the time into it,
# and the shell's and libghostty-vt's archives. Empty with no engine.
apple_native_libs_key() {
  local o=$A/out/core/aarch64-apple-darwin f
  [ -f "$o/libmbui_core.a" ] || return 0
  {
    echo "macos ${MACOSX_DEPLOYMENT_TARGET:-}"
    echo "cc $(xcrun --sdk macosx clang++ --version 2>/dev/null | head -1)"
    echo "hermes $(readlink "$A/out/core/hermes" 2>/dev/null)"
    for f in src/host/apple_core.mm engine/ready_queue.h src/host/apple_collate.h src/host/electron_sealed.h \
      src/host/core_api.h src/host/listen_api.h scripts/core.sh; do
      [ ! -f "$A/$f" ] || echo "$f $(sha256_of < "$A/$f")"
    done
    for f in libstillfail_shell.a libghostty-vt.a; do
      [ ! -f "$o/$f" ] || echo "$f $(sha256_of < "$o/$f")"
    done
  } | sha256_of
}
[ "${1:-}" = login ] && export APP=coredemo
if [ "${MBUI_CORE:-0}" != 0 ]; then export APP=coredemo; fi
if [ $APP = coredemo ] || [ $APP = stillfail ]; then
  if [ "${1:-build}" = build ]; then
    # (each part's time said, mac-app.sh shows it: a release's Mac job was 185-238 s, the app's part 114-166 s of it,
    # its compile 11 s, the rest not told apart, 2026-11-01)
    t0=$SECONDS
    exe=$A/_build/native/${MODE:-release}/build/stillfail/$APP/$APP.exe
    if [ "${STILLFAIL_CORE:-}" = pion ]; then
      sh "$D/pion-core.sh" build darwin-arm64 || exit 1
      pion_lib=$A/out/pion-core/darwin-arm64/libpion_core.a
      shell_dir=$(cd "$SF_SRC" && node scripts/native.ts path shell-apple darwin-arm64) || exit 1
      ghostty_dir=$(cd "$SF_SRC" && node scripts/native.ts path ghostty-vt darwin-arm64) || exit 1
      mkdir -p "$A/out/core/aarch64-apple-darwin" "$A/out/core/ghostty-vt/include"
      cmp -s "$shell_dir/libstillfail_shell.a" "$A/out/core/aarch64-apple-darwin/libstillfail_shell.a" \
        || cp "$shell_dir/libstillfail_shell.a" "$A/out/core/aarch64-apple-darwin/" || exit 1
      cmp -s "$shell_dir/libstillfail_shell.libs" "$A/out/core/shell-aarch64-apple-darwin.libs" \
        || cp "$shell_dir/libstillfail_shell.libs" "$A/out/core/shell-aarch64-apple-darwin.libs" || exit 1
      cmp -s "$ghostty_dir/lib/libghostty-vt.a" "$A/out/core/aarch64-apple-darwin/libghostty-vt.a" \
        || cp "$ghostty_dir/lib/libghostty-vt.a" "$A/out/core/aarch64-apple-darwin/" || exit 1
      rsync -a --checksum "$ghostty_dir/include/" "$A/out/core/ghostty-vt/include/" || exit 1
      shell_libs=$(python3 - "$A/out/core/shell-aarch64-apple-darwin.libs" <<'PY'
import sys
t = open(sys.argv[1]).read().split()
out = []
i = 0
while i < len(t):
    x = t[i:i + 2] if t[i] == "-framework" else t[i:i + 1]
    i += len(x)
    s = " ".join(x)
    if s not in out and x[0] not in ("-lSystem", "-lobjc"):
        out.append(s)
print(" ".join(out))
PY
)
      pion_cc=$A/out/pion-core/darwin-arm64/pion-cc.sh
      real_cc=${MBC_REAL_CC:-$(command -v cc)}
      cat > "$pion_cc" <<EOF
#!/bin/bash
set -eu
real_cc='$real_cc'
pion_lib='$pion_lib'
shell_libs='$shell_libs'
args=()
compiling_engine=0
linking_pion=0
i=1
n=\$#
while [ \$i -le \$n ]; do
  a="\${!i}"
  case "\$a" in
    *core_engine.m)
      compiling_engine=1
      args+=("\$a")
      ;;
    *libmbui_core.a)
      linking_pion=1
      args+=("\$pion_lib")
      ;;
    -F*hermes*|-Wl,-rpath,*hermes*)
      ;;
    -framework)
      next_i=\$((i + 1))
      if [ \$next_i -le \$n ] && [ "\${!next_i}" = hermes ]; then
        i=\$next_i
      else
        args+=("\$a")
      fi
      ;;
    *)
      args+=("\$a")
      ;;
  esac
  i=\$((i + 1))
done
if [ "\$compiling_engine" = 1 ]; then
  args=(-DSTILLFAIL_CORE_PION "\${args[@]}")
fi
if [ "\$linking_pion" = 1 ]; then
  # shellcheck disable=SC2206
  extra=(\$shell_libs)
  args+=("\${extra[@]}")
fi
exec "\$real_cc" "\${args[@]}"
EOF
      chmod +x "$pion_cc"
      export MBC_REAL_CC="$pion_cc"
      # (force relink when switching from Hermes or after libpion_core.a rebuild)
      if [ -f "$exe" ] && { [ "$pion_lib" -nt "$exe" ] || otool -L "$exe" 2>/dev/null | grep -qi hermes; }; then
        touch "$A/src/$APP/core_engine.m"
      fi
      if [ $APP = stillfail ] && [ -f "$exe" ] && ! nm "$exe" 2>/dev/null | grep -q ' _ghostty_terminal_new$'; then
        touch "$A/src/$APP/terminal_ghostty.c"
      fi
      echo "mac.sh: pion core native parts in $((SECONDS - t0)) s (zero Hermes)"
    else
      # (MBUI_APPLE_NATIVE_READY: the caller made them just before, .github/mac-release-prebuild.sh; 2-8 s again)
      [ "${MBUI_APPLE_NATIVE_READY:-0}" = 1 ] || bash "$D/core.sh" apple-native aarch64-apple-darwin || exit 1
      echo "mac.sh: the core's native parts in $((SECONDS - t0)) s"
      # (moon does not see the engine's archive nor the libraries linked beside it: an app linked before they changed has
      # its stub touched, so it is linked again. Told by what they are made of, kept beside the app ($exe.native-libs, in
      # CI's moon cache with it), not by mtimes: a fresh runner's engine is always newer than the app its cache restored,
      # and moon's mbc and link ran again every run, 40-50 s; the engine's mtime only for an app with no such mark)
      native_key=$(apple_native_libs_key)
      if [ -f "$exe" ]; then
        relink=0
        if ! otool -L "$exe" 2>/dev/null | grep -qi hermes; then
          relink=1
        elif [ -n "$native_key" ] && [ -f "$exe.native-libs" ]; then
          [ "$(cat "$exe.native-libs")" = "$native_key" ] || relink=1
        elif [ "$A/out/core/aarch64-apple-darwin/libmbui_core.a" -nt "$exe" ]; then
          relink=1
        fi
        [ $relink = 0 ] || touch "$A/src/$APP/core_engine.m"
      fi
      # (nor libghostty-vt's headers: src/stillfail/terminal_ghostty.c is its mark alone when they are not there, and moon
      # compiles a stub again only when its mtime changes, which scripts/moon-mtimes.sh makes its content's, so one
      # compiled so once would stay so in CI's moon cache. An app without the library's calls has the stub touched, so it
      # is compiled again with them.)
      if [ $APP = stillfail ] && [ -f "$exe" ] && ! nm "$exe" 2>/dev/null | grep -q ' _ghostty_terminal_new$'; then
        touch "$A/src/$APP/terminal_ghostty.c"
      fi
      # (MBUI_PACKAGES_PENDING: a file the caller takes away once its own pnpm install is over, its going waited for before
      # the bytecode's bundle installs the core's packages into the same store: the release's Mac job restored and
      # installed the store while this ran, and pnpm found a package it was importing gone, ERR_PNPM_ENOENT, main 426cefb1,
      # 42592023024)
      { [ -z "${MBUI_PACKAGES_PENDING:-}" ] || "$MBUI_DIR/scripts/chk" logwait --gone "$MBUI_PACKAGES_PENDING" --deadline 300 \
          || exit 1
        bash "$D/core.sh" hermes apple; } > "$A/out/core/hermes.log" 2>&1 &
      hbc=$!
    fi
  fi
  [ "${STILLFAIL_CORE:-}" = pion ] || export MB_CORE_BUNDLE=${MB_CORE_BUNDLE:-$A/out/core/core.hbc}
fi
if [ "${1:-}" = login ]; then
  cd "$A" && MBUI_AUTH_LOGIN=1 exec ./_build/native/${MODE:-release}/build/coredemo/coredemo.exe
fi
[ -n "${hbc:-}" ] || exec bash "$MBUI_DIR/scripts/mac.sh" "$@"
t0=$SECONDS
bash "$MBUI_DIR/scripts/mac.sh" "$@"
code=$?
echo "mac.sh: the app built in $((SECONDS - t0)) s"
# (an app without libghostty-vt shows no terminal and says nothing of it: one that should have it is not let out so)
if [ $code = 0 ] && [ -n "${exe:-}" ] && [ $APP = stillfail ] && ! nm "$exe" 2>/dev/null | grep -q ' _ghostty_terminal_new$'; then
  echo "mac.sh: $exe has no libghostty-vt (src/stillfail/terminal_ghostty.c compiled without out/core/ghostty-vt/include)" >&2
  code=1
fi
# (the native parts this app was linked with, for the next build's check above)
if [ $code = 0 ] && [ -f "$exe" ] && [ -n "${native_key:-}" ]; then printf '%s\n' "$native_key" > "$exe.native-libs"; fi
t0=$SECONDS
wait $hbc || { cat "$A/out/core/hermes.log"; echo "mac.sh: the core's bytecode was not made (scripts/core.sh hermes apple)" >&2; exit 1; }
cat "$A/out/core/hermes.log"
echo "mac.sh: the core's bytecode waited for $((SECONDS - t0)) s more"
exit $code
