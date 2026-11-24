#!/bin/bash
# The Windows apps: mbui's scripts/win.sh (build | run | script NAME | shot) on this module's apps (APP=stillfail by
# default; sffix), in Git Bash on Windows with MoonBit and MSVC (a Developer Command Prompt's environment).
# stillfail has the still.fail core in it (src/stillfail/win_engine.c → src/host/win_core.c): the engine and the shell
# prebuilt for Windows (this checkout's scripts/native.ts parts `engine` and `shell`, win32-x64: from the release
# native-artifacts, or built here, as only Windows can), the engine's C API (engine/engine.h) and import library found
# through cl's and link's own variables (CL, LIB), and the core as Hermes bytecode (scripts/core.sh hermes, with the
# engine's own hermesc). After a build all three are put beside the app's .exe, which finds them there.
# The build in parts, for CI to make the core while cl compiles the app (it needs no node_modules; the core does):
#   MBUI_WIN_CORE=0 scripts/win.sh build   the app alone, the engine and the shell put beside it
#   scripts/win.sh core                    the core's bytecode (out/core/core.hbc)
#   scripts/win.sh put                     the core's bytecode, the engine and the shell put beside the app
#   scripts/win.sh collate                 the host's order of names (src/host/win_collate.h) checked
#   scripts/win.sh engine-sync             synchronous host answers across the engine DLL checked
#   scripts/win.sh sealed                  the desktop app's sealed values opened (src/host/win_electron_sealed.h) checked
#   scripts/win.sh hello                   Windows Hello as secure.* asks it (src/host/win_hello.h) checked
#   scripts/win.sh reports                 PostHog reports payload and reports.json logic (src/host/win_reports.c) checked
#   scripts/win.sh setup                   the installer (windows/setup.c) with the app built and put packed after it
#   scripts/win.sh setup-bare              the installer's own program alone (out/setup-bare), which setup packs the app with
# Its identity (as mac-app.sh's Info.plist has the Mac app's), in the program's resources: its icon
# (windows/AppIcon-<mac-icon.swift's hash>.ico: that script draws it on a Mac, `--ico`), its version (0.1.<MBUI_BUILD>,
# else the commits in still.fail's history), its name, and its own environment (RCDATA MBUI_ENV, which mbui's host
# reads as what the process's environment does not say: src/host/win_life.h): MBUI_APP_ID, MBUI_APP_NAME,
# MBUI_SCHEMES, MBUI_OWN, MBUI_BETA. MBUI_VARIANT, which app it is built as (as mac-app.sh's): preview (the default) still.fail
# preview, an app beside still.fail's desktop app (fail.still.mbui, the test channel's, no links of that app's); stable and
# beta still.fail's desktop app itself, to take its place (apps/desktop/package.json, build.sh): its id
# (fail.still.desktop, .beta: its AppUserModelID, its pinned shortcuts'), its name (still.fail, youdid.wtf: its
# userData, %APPDATA%\<name>, whose data, sign-in and sealed keys it takes: src/host/win_core.c), its links (stillfail,
# stillfail-beta), MBUI_OWN; the beta's core a beta's.
AD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$AD/env.sh"
# Every app build, including release variants, picks the same compiler before mbc looks up its objects.
if [ -z "${MBUI_IN_WIN_SH:-}" ] && [ "${1:-build}" = build ]; then . "$AD/win-compiler.sh"; fi
export APP=${APP:-stillfail}
if [ -z "${MBUI_IN_WIN_SH:-}" ] && [ "$APP" = stillfail ]; then
  engine=$(cd "$SF_SRC" && node scripts/native.ts path engine win32-x64) || exit 1
  shell=$(cd "$SF_SRC" && node scripts/native.ts path shell win32-x64) || exit 1
  ghostty_vt=$(cd "$SF_SRC" && node scripts/native.ts path ghostty-vt win32-x64) || exit 1
  # (the shell's import library too: the app asks the shell itself for a remote screen's frames, src/host/win_core.c;
  # libghostty-vt's static library for src/stillfail/terminal_ghostty.c)
  export LIB="$(cygpath -w "$engine");$(cygpath -w "$shell");$(cygpath -w "$ghostty_vt/lib");$LIB"
  export CL="/I$(cygpath -w "$A/engine") /I$(cygpath -w "$MBUI_DIR/src/host") /I$(cygpath -w "$ghostty_vt/include") ${CL:-}"
  export engine shell ghostty_vt
fi
core() { HERMESC=$(cygpath -m "$engine/hermesc.exe") bash "$AD/core.sh" hermes; }
# variant: what MBUI_VARIANT builds the app as (from apps/mbui/mbui.json): its id, its name, its program's name where
# it is put (the desktop app's own program's in its place; preview uses stillfail.exe on Windows), the folder it is put
# in (%LOCALAPPDATA%\Programs\<dir>: the desktop app's installer's, its package name), its company, and its own
# environment beyond those
variant() {
  local v=${MBUI_VARIANT:-preview} meta kv feed
  local MBUI_APP_ID MBUI_APP_NAME MBUI_EXECUTABLE MBUI_VERSION MBUI_BUILD MBUI_VARIANT \
    MBUI_RUNTIME MBUI_MODULE_DIR MBUI_ENTRY MBUI_SCHEMES MBUI_UPDATE_FEED MBUI_UPDATE_CHANNEL \
    MBUI_ENV_KV MBUI_MAC_MIN_VERSION MBUI_WIN_INSTALL_DIR MBUI_WIN_COMPANY
  meta=$("$MBUI_DIR/scripts/ui" meta "$A/mbui.json" --variant "$v" --format sh) || {
    echo "win.sh: MBUI_VARIANT is preview, stable, beta, monoid or monoid-beta, not $v" >&2
    return 1
  }
  meta=${meta//$'\r'/}
  eval "$meta"
  id=$MBUI_APP_ID
  name=$MBUI_APP_NAME
  exe=$MBUI_EXECUTABLE
  [ "$v" != preview ] || exe=stillfail
  dir=$MBUI_WIN_INSTALL_DIR
  company=$MBUI_WIN_COMPANY
  schemes=$MBUI_SCHEMES
  feed=${MBUI_UPDATE_FEED/#mac/win}
  extra="MBUI_UPDATE_FEED=$feed"
  if [ -n "$MBUI_ENV_KV" ]; then
    local IFS=';'
    for kv in $MBUI_ENV_KV; do
      case "$kv" in
        MBUI_STATION_LABEL=*) ;;
        *=*) extra="$extra
$kv" ;;
      esac
    done
  fi
}
# res: the app's resources (out/win-res/app.res), for mbui's win.sh to link into it (MBUI_WIN_RES)
res() {
  local n=${MBUI_BUILD:-$(git -C "$SF_SRC" rev-list --count HEAD 2>/dev/null || echo 1)}
  local icon=$A/windows/AppIcon-$(sha256sum "$AD/mac-icon.swift" | cut -c1-12).ico
  [ -f "$icon" ] || { echo "win.sh: no $icon (scripts/mac-icon.swift changed: swift scripts/mac-icon.swift --ico $icon, on a Mac)" >&2; return 1; }
  local id name exe dir company schemes extra env_lines r=$A/out/win-res
  variant || return 1
  rm -rf "$r" && mkdir -p "$r"
  cp "$icon" "$r/app.ico"
  env_lines="MBUI_APP_ID=$id
MBUI_APP_NAME=$name
MBUI_VERSION=0.1.$n
MBUI_BUILD=$n"
  [ -z "$schemes" ] || env_lines="$env_lines
MBUI_SCHEMES=$schemes"
  env_lines="$env_lines
$extra"
  if [ -n "${STILLFAIL_POSTHOG:-}" ] && { [ "${MBUI_VARIANT:-preview}" = stable ] || [ "${MBUI_VARIANT:-preview}" = beta ]; }; then
    local ph_path ph_host ph_key
    ph_path=$(cygpath -w "$STILLFAIL_POSTHOG" 2>/dev/null || printf '%s' "$STILLFAIL_POSTHOG")
    ph_host=$(node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(typeof d.host === "string" ? d.host : "");' "$ph_path") || return 1
    ph_key=$(node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(typeof d.key === "string" ? d.key : "");' "$ph_path") || return 1
    [ -n "$ph_key" ] || { echo "win.sh: no PostHog key in $STILLFAIL_POSTHOG" >&2; return 1; }
    [ -z "$ph_host" ] || env_lines="$env_lines
STILLFAIL_POSTHOG_HOST=$ph_host"
    env_lines="$env_lines
STILLFAIL_POSTHOG_KEY=$ph_key"
  fi
  printf '%s\n' "$env_lines" > "$r/app.env"
  cat > "$r/app.rc" <<RC
1 ICON "app.ico"
MBUI_ENV RCDATA "app.env"
1 VERSIONINFO
 FILEVERSION 0,1,$n,0
 PRODUCTVERSION 0,1,$n,0
 FILEFLAGSMASK 0x3F
 FILEFLAGS 0
 FILEOS 0x40004
 FILETYPE 0x1
 FILESUBTYPE 0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "$company"
      VALUE "FileDescription", "$name"
      VALUE "FileVersion", "0.1.$n"
      VALUE "InternalName", "stillfail"
      VALUE "OriginalFilename", "$exe.exe"
      VALUE "ProductName", "$name"
      VALUE "ProductVersion", "0.1.$n"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
RC
  # (rc's options with -, not /: Git Bash hands /fo to Windows programs as a path)
  (cd "$r" && rc.exe -nologo -fo app.res app.rc) || return 1
  # (one name whatever is in it, the app's link flags the same from one build to the next: named by its content, a
  # version's every commit made the app package's moon.pkg another and moon built all of it again, moonc and its C split
  # anew, ~45 s of a Windows preview with nothing of its MoonBit changed, 2026-11-05. moon links the program again only
  # as an input it knows changes, which these resources are not: where they are not what the program was linked with
  # (kept beside it), the program is taken away, and moon links it again alone; mbc's link goes by its inputs' content)
  local res=$r/app.linked.res
  . "$MBUI_DIR/scripts/env.sh"
  # (a build before this one's: none, nothing linked yet)
  if [ -f "$MBUI_DIR/out/win/app/moon.work" ]; then
    local built=$MBUI_DIR/out/win/app/$(cd "$MBUI_DIR/out/win/app" && pkg_build $APP native ${MODE:-release})
    if ! cmp -s "$r/app.res" "$built/app.res"; then
      rm -f "$built/stillfail.exe"
      mkdir -p "$built" && cp "$r/app.res" "$built/app.res"
    fi
  fi
  cp "$r/app.res" "$res"
  export MBUI_WIN_RES=$res
  echo "win.sh: $name 0.1.$n ($id), its resources $(wc -c < "$res") bytes ($(basename "$res"))"
}
# put [core]: the engine and the shell beside the app's .exe, the core's bytecode too when asked
put() {
  . "$MBUI_DIR/scripts/env.sh"
  # (mbui's win.sh builds this module in its copy, out/win/app beside mbui's own)
  dir=$MBUI_DIR/out/win/app/$(cd "$MBUI_DIR/out/win/app" && pkg_build $APP native ${MODE:-release})
  cp "$engine/stillfail_engine.dll" "$shell/stillfail_shell.dll" "$ghostty_vt/bin/ghostty-vt.dll" "$dir/" || return 1
  [ "${1:-}" != core ] || cp "$A/out/core/core.hbc" "$dir/" || return 1
  ls -la "$dir"
}
# collate: the order of names the core asks of the host (src/host/win_collate.h), checked by core/collate_test_win.c
collate() {
  local out=$A/out/collate
  mkdir -p "$out"
  (cd "$A" && cl.exe -nologo -O2 -W3 -Isrc/host core/collate_test_win.c -Fe"$(cygpath -w "$out/collate_test_win.exe")" \
    -Fo"$(cygpath -w "$out/")" > "$out/build.log") || { cat "$out/build.log"; return 1; }
  "$out/collate_test_win.exe"
}
# The real engine DLL takes host answers through its C ABI (the host and the engine have separate CRTs).
engine_sync() {
  . "$MBUI_DIR/scripts/env.sh"
  local built=$MBUI_DIR/out/win/app/$(cd "$MBUI_DIR/out/win/app" && pkg_build $APP native ${MODE:-release}) out=$A/out/engine-sync
  mkdir -p "$out/data"
  (cd "$A" && cl.exe -nologo -O2 -W3 -Iengine -Isrc/host core/engine_sync_test_win.c \
    -Fe"$(cygpath -w "$built/engine_sync_test.exe")" -Fo"$(cygpath -w "$out/")" > "$out/build.log") || { cat "$out/build.log"; return 1; }
  "$built/engine_sync_test.exe" "$(cygpath -m "$out/data")"
}
# sealed: the desktop app's sealed values opened in its place (src/host/win_electron_sealed.h), checked by
# core/sealed_test_win.c
sealed() {
  local out=$A/out/sealed
  mkdir -p "$out"
  (cd "$A" && cl.exe -nologo -O2 -W3 -Isrc/host core/sealed_test_win.c -Fe"$(cygpath -w "$out/sealed_test_win.exe")" \
    -Fo"$(cygpath -w "$out/")" > "$out/build.log") || { cat "$out/build.log"; return 1; }
  "$out/sealed_test_win.exe"
}
# hello: Windows Hello as the core's secure.* asks it (src/host/win_hello.h), checked by core/hello_test_win.c (pure C at
# -W4 -WX, as win_core.c takes it), and the program it makes needing no Visual C++ redistributable (check_crt: WinRT's
# runtimeobject.lib is the system's own)
hello() {
  local out=$A/out/hello
  mkdir -p "$out"
  (cd "$A" && cl.exe -nologo -O2 -W4 -WX -Isrc/host core/hello_test_win.c -Fe"$(cygpath -w "$out/hello_test_win.exe")" \
    -Fo"$(cygpath -w "$out/")" > "$out/build.log") || { cat "$out/build.log"; return 1; }
  check_crt "$out/hello_test_win.exe" || return 1
  "$out/hello_test_win.exe"
}
# reports: Windows PostHog telemetry payload and reports.json logic (src/host/win_reports.c), checked by
# core/reports_test_win.c (pure C at -W4 -WX -utf-8) with zero Visual C++ redistributable dependency (check_crt)
reports() {
  local out=$A/out/reports
  mkdir -p "$out"
  (cd "$A" && cl.exe -nologo -O2 -W4 -WX -utf-8 -Isrc/host core/reports_test_win.c -Fe"$(cygpath -w "$out/reports_test_win.exe")" \
    -Fo"$(cygpath -w "$out/")" > "$out/build.log") || { cat "$out/build.log"; return 1; }
  check_crt "$out/reports_test_win.exe" || return 1
  "$out/reports_test_win.exe"
}
# setup: the installer (windows/setup.c) with the app as built and put (put: the program, its engine and shell, core.hbc)
# packed after it, as MBUI_VARIANT has it: <MBUI_SETUP_OUT, else out/setup>/<name> (MBUI_SETUP_NAME, else
# stillfail-setup-0.1.<n>.exe); with MBUI_SETUP_RAW (a path) its raw form (setup.c --raw's) written there as it is packed
# the installer's own program (windows/setup.c), bare: made once for its source, apart from the app (CI makes it while
# the app compiles: made in the installer's step, beside the e2e flow's app, it was 4 s alone and 15-56 s there,
# 2026-10-28). -utf-8: its Chinese words, read in the build machine's code page without it, were garbled in the program
setup_bare() {
  local out=$A/out/setup-bare
  [ "$out/setup-bare.exe" -nt "$A/windows/setup.c" ] && [ "$out/setup-bare.exe" -nt "$A/src/host/station_uninstall.h" ] && return 0
  mkdir -p "$out"
  local t0=$SECONDS
  (cd "$A" && cl.exe -nologo -O2 -W3 -utf-8 windows/setup.c -Fe"$(cygpath -w "$out/setup-bare.exe.tmp.exe")" -Fo"$(cygpath -w "$out/")" > "$out/build.log") ||
    { cat "$out/build.log"; return 1; }
  mv -f "$out/setup-bare.exe.tmp.exe" "$out/setup-bare.exe"
  echo "win.sh: setup.c compiled in $((SECONDS - t0)) s"
}
# Check the actual programs that will be installed, not just the compiler options: a prebuilt DLL can bring its own
# runtime dependency. Windows 10 includes the UCRT, but not the Visual C++ redistributable.
check_crt() {
  local file deps bad=0
  for file in "$@"; do
    [ -f "$file" ] || { echo "win.sh: no $file to check" >&2; return 1; }
    deps=$(dumpbin.exe -nologo -dependents "$(cygpath -w "$file")") || return 1
    printf '%s\n%s\n' "Dependencies of $(basename "$file"):" "$deps"
    if printf '%s\n' "$deps" | grep -Eiq '(^|[[:space:]])(MSVCP|VCRUNTIME)[0-9_]*\.dll([[:space:]]|$)'; then
      echo "win.sh: $(basename "$file") needs the Visual C++ redistributable" >&2
      bad=1
    fi
  done
  return "$bad"
}
setup() {
  local n=${MBUI_BUILD:-$(git -C "$SF_SRC" rev-list --count HEAD 2>/dev/null || echo 1)} id name exe dir company schemes extra
  variant || return 1
  . "$MBUI_DIR/scripts/env.sh"
  local built=$MBUI_DIR/out/win/app/$(cd "$MBUI_DIR/out/win/app" && pkg_build $APP native ${MODE:-release}) out=${MBUI_SETUP_OUT:-$A/out/setup}
  [ -f "$built/stillfail.exe" ] || { echo "win.sh: no app built (win.sh build, put)" >&2; return 1; }
  rm -rf "$out" && mkdir -p "$out/files"
  setup_bare || return 1
  check_crt "$A/out/setup-bare/setup-bare.exe" "$built/stillfail.exe" "$built/stillfail_engine.dll" "$built/stillfail_shell.dll" "$built/ghostty-vt.dll" || return 1
  cp "$A/out/setup-bare/setup-bare.exe" "$out/setup-bare.exe"
  cp "$built/stillfail.exe" "$out/files/$exe.exe"
  cp "$built/stillfail_engine.dll" "$built/stillfail_shell.dll" "$built/ghostty-vt.dll" "$built/core.hbc" "$out/files/"
  printf 'APP_NAME=%s\nAPP_ID=%s\nEXE=%s\nDIR=%s\nSCHEMES=%s\nVERSION=0.1.%s\n' "$name" "$id" "$exe" "$dir" "$schemes" "$n" > "$out/setup.env"
  local to=$out/${MBUI_SETUP_NAME:-stillfail-setup-0.1.$n.exe}
  local w=(); for f in "$out/files/"*; do w+=("$(cygpath -w "$f")"); done
  # (MBUI_SETUP_RAW: its raw form too, written by --pack from the files as read, the same bytes as --raw writes: a
  # Windows path, which the program's CreateFileW takes)
  MBUI_SETUP_RAW=${MBUI_SETUP_RAW:+$(cygpath -w "$MBUI_SETUP_RAW")} \
    "$out/setup-bare.exe" --pack "$(cygpath -w "$to")" "$(cygpath -w "$out/setup.env")" "${w[@]}" || return 1
  echo "win.sh: $(basename "$to") $(wc -c < "$to") bytes ($name 0.1.$n)"
}
app_prebuild() {
  if [ "$APP" = stillfail ] && [ "${MBUI_WIN_CORE:-1}" != 0 ]; then core || exit 1; fi
  if [ "$APP" = stillfail ]; then res || exit 1; fi
}
app_postbuild() {
  if [ "$APP" = stillfail ]; then
    if [ "${MBUI_WIN_CORE:-1}" != 0 ]; then put core || exit 1; else put || exit 1; fi
  fi
}
app_cmd() {
  case "$1" in
    core) core ;;
    put) put core ;;
    collate) collate ;;
    engine-sync) engine_sync ;;
    sealed) sealed ;;
    hello) hello ;;
    reports) reports ;;
    setup) setup ;;
    setup-bare) setup_bare ;;
    *) echo "win.sh: no command $1" >&2; exit 1 ;;
  esac
}
[ -z "${MBUI_IN_WIN_SH:-}" ] || { return 0 2>/dev/null || exit 0; }
export MBUI_IN_WIN_SH=1 MBUI_WIN_HOOK="$AD/win.sh"
exec bash "$MBUI_DIR/scripts/win.sh" "$@"
