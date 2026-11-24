#!/bin/bash
# This module's tests against mbui's fake host (no window): still.fail's design system, its pages (over the fixtures),
# the media screens' parts and the core client's, the screens (src/sfapp/screens_wbtest.mbt, scripts/screens.sh), then the flows seen
# again over their runs' cores (src/sfreplay/steps.mbt). UPDATE=1 refreshes snapshots. TARGETS: the targets they run
# on (in development wasm-gc, no C compiled (the user, 2026-11-03); in CI (GITHUB_ACTIONS) native, as the apps are built:
# check-mbui's native on Linux, and on macOS on main). PARTS: which
# of the two (app: the design system, the pages, the screens, gallery and player; replay: the core and the flows seen
# again), both by default; check-mbui runs each on a runner of its own. SFAPP_SHARDS: how many processes sfapp's test
# files are run in side by side (5); 1, the pages' files all in one (the screen sweeps a process each beside them):
# what one file leaves behind that a later one trips on shows best there, and check-mbui's run of the day runs them so
# (a push's in 4). mbui's own: its scripts/test.sh.
# APP_EXE (with APP_INFO, its tests' list, __whitebox_test_info.json): sfapp's test program built elsewhere (check-mbui's
# app-build job's), its runs asked of it directly (scripts/testexe; TESTEXE: that tool built elsewhere too, beside it),
# nothing built here. APP_BUILD_OUT: sfapp's test program built only, it, its tests' list and the tool put in that
# directory for them. REPLAY_EXE (with REPLAY_INFO, __blackbox_test_info.json) and REPLAY_BUILD_OUT: the same for the
# flows' program (src/sfreplay/flows), check-mbui's replay-build job's, run at every frame rate (replay-fps); the
# core's tests run where it is built (REPLAY_BUILD_OUT), after it is put there. PKGS_BUILD_OUT (APP_GROUP=pkgs): the
# small packages' test programs and their tests' lists put there as they are built, then run here at the default rate;
# PKGS_EXE: that directory, its programs run beside sfapp's pages (@pkgs, check-mbui's app 1/4 at each rate).
# APP_FILES: of sfapp's test files only these (with APP_EXE and APP_GROUP=1/1: a branch's changed files at a rate);
# none, no sfapp file at all (APP_EXE then not run), only the packages' (PKGS_EXE). PKGS_FILES: of the small packages'
# test files only these (with PKGS_EXE: a branch's changed files of sfpages, settings, gallery, player, sfgraphic).
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
# (the whole suite is CI's, a PR's: on Studio or a laptop it is half an hour of wasm-gc in a row where CI's native runs
# it in five minutes; outside CI run the test files a change touches, `moon test --target wasm-gc --release FILE`
# (the user, 2026-11-08). MBUI_WHOLE_SUITE=1 only when a person asked for the whole of it here.)
if [ -z "${GITHUB_ACTIONS:-}" ] && [ "${MBUI_WHOLE_SUITE:-}" != 1 ]; then
  echo "test.sh: the whole suite runs in the PR's CI, not here. Run the test files your change touches:" >&2
  echo "  moon test --target wasm-gc --release src/sfapp/<file>_wbtest.mbt" >&2
  exit 2
fi
cd "$A"
# (fd 9: the script's own stderr, for what is said while runs go on: parts_watch)
exec 9>&2
F='^Warning\|^ *│\|^ *╭\|^ *╰\|^─\|^ *[0-9]* │'
code=0
if [ -n "${GITHUB_ACTIONS:-}" ]; then targets=${TARGETS:-native}; else targets=${TARGETS:-wasm-gc}; fi
for t in $targets; do
  echo "=== $t"
  # (native, on any system: a test's program links no host's code, its host the Tester's fake (mbui/hostapi). Built
  # --release as the apps are, its C split and compiled in parallel by mbui's scripts/mbc (moon's cc on PATH): on
  # macos-15 the tests ran in 15 s against debug's 144 s (2026-10-20). An object made of the same inputs (by content)
  # is kept: a build over the last one's objects (mbui-check.yml's native cache) compiles only the units whose
  # functions changed. clang where there is one, as on macOS (MBC_REAL_CC says otherwise). Without ThinLTO unless
  # MBC_LTO says (its link is 30-40 s a test; main's run has it on: mbui-check.yml).)
  mode="--target $t"
  # (mbui's scripts/env.sh native_tests: the C split by mbui's scripts/mbc, units kept by content in MBC_STORE)
  if [ $t = native ] && [ -z "${APP_EXE:-}" ] && [ -z "${REPLAY_EXE:-}" ] && [ -z "${REALSIZE_EXE:-}" ] && [ -z "${PAGES_TEST_EXE:-}" ]; then native_tests "$A"; mode=$NATIVE; fi
  # (wasm-gc: --release, as native's; wasm-gc rather than classic Wasm, whose memory is freed by counting alone: what
  # holds itself is never freed, 3.7 MB a screen opened in a Tester, and the corner and contrast sweeps outgrew its
  # 4 GiB (2026-11-03))
  [ $t = wasm-gc ] && mode="--target wasm-gc --release"
  # (the parts' packages in one moon test, which runs a package's tests in one executable and the packages side by
  # side. The flows in one package, src/sfreplay/flows: each test package is a program of the whole app, its C
  # compiled apart, and five of them compiled the same change five times over; on CI's four cores the replay part was
  # 194 s with them apart and 140 s together, 2026-10-22; sfreplay's own two tests there too: its whitebox test was
  # one more program of the whole app, linked with ThinLTO on main in 120 s beside the flows' 118, 2026-10-23)
  pkgs=""
  if [[ " ${PARTS:-app realsize pages_test replay} " = *" app "* ]]; then
    # (the screens' tests in sfapp's own, screens_wbtest.mbt: a package of their own was a second program of the whole
    # app, compiled again on every change, 88 s of a branch's app part with sfapp's own 92, 2026-10-23)
    # (sfpages' own tests too: the pages moved there from sfapp brought theirs, run by nothing until 2026-10-25)
    pkgs="-p stillfail/sfpages -p stillfail/sfapp -p stillfail/sfapp/settings -p stillfail/gallery -p stillfail/player -p stillfail/sfgraphic"
    # (APP_GROUP=k/n: one runner's share of sfapp's runs, app_group_of below, each building sfapp's program alone;
    # APP_GROUP=pkgs: the small packages' run alone, on a runner of its own. Their five programs were built by the
    # first group beside sfapp's, each much of the app again: its build 168-209 s after a change where the others'
    # was 57-89, the first's job the check's longest, 2026-10-29, 40807235675) (built once since, at the default rate
    # (PKGS_BUILD_OUT), their runs at the other rates on what it built (PKGS_EXE): each rate's runner built the same
    # programs again, 72-90 s, to run them 21-51 s, 2026-11-11)
    if [ "${APP_GROUP:-}" = pkgs ]; then pkgs="-p stillfail/sfpages -p stillfail/sfapp/settings -p stillfail/gallery -p stillfail/player -p stillfail/sfgraphic"
    elif [ -n "${APP_GROUP:-}" ]; then pkgs="-p stillfail/sfapp"; fi
    # (with ThinLTO, MBC_LTO=thin: only the program of the whole app. What ThinLTO's tests are for is the code that
    # ships, built as it ships, inlined across its units; all of it is in sfapp's test, run with the whole app's tests.
    # The smaller programs are parts of the same code, each linked again with ThinLTO for its own few tests: five
    # links a part side by side, 35-69 s each after a change, 2026-10-23, 40022031382; their tests run without it)
    [ "${MBC_LTO:-0}" = thin ] && pkgs="-p stillfail/sfapp"
  fi
  if [[ " ${PARTS:-app realsize pages_test replay} " = *" realsize "* ]] && [ "${MBC_LTO:-0}" != thin ]; then
    pkgs="$pkgs -p stillfail/sfapp_realsize"
  fi
  if [[ " ${PARTS:-app realsize pages_test replay} " = *" pages_test "* ]] && [ "${MBC_LTO:-0}" != thin ]; then
    pkgs="$pkgs -p stillfail/sfapp_pages_test"
  fi
  if [[ " ${PARTS:-app realsize pages_test replay} " = *" replay "* ]]; then
    if [ "${MBC_LTO:-0}" = thin ]; then pkgs="$pkgs -p stillfail/sfreplay/flows"; else
    # (not sfreplay: no test of its own is left there, and its package was two empty programs of the whole app, 29 s
    # of the replay part's compile, 2026-10-24)
    pkgs="$pkgs -p stillfail/core -p stillfail/sfreplay/flows"
    # (on a program built elsewhere, REPLAY_EXE: the flows alone, the core's tests run where it was built)
    [ -z "${REPLAY_EXE:-}" ] || pkgs="${pkgs/ -p stillfail\/core/}"
    fi
    # (a test under a directory of its own there is in no package this runs: a branch from before brought one back)
    for g in src/sfreplay/flows/*/; do
      [ -d "$g" ] || continue
      echo "test.sh: $g: the flows' tests are in src/sfreplay/flows itself, one package (its tests here are never run)" >&2
      code=1
    done
  fi
  # The kinds of test program a package has none of (internal: a test in its own files; blackbox: *_test.mbt;
  # whitebox: *_wbtest.mbt), which moon builds anyway, each the whole app, and never runs: scripts/mbc puts a stand-in
  # in their place (MBC_EMPTY_TESTS)
  empty=""
  for p in $pkgs; do
    [ "$p" = -p ] && continue
    d=src/${p#stillfail/}; n=$(basename "$d"); [ -d "$d" ] || continue
    [ -n "$(ls "$d"/*.mbt 2>/dev/null | grep -vE '_(wb)?test\.mbt$' | xargs grep -l '^test ' 2>/dev/null)" ] || empty="$empty ${p#stillfail/}/$n.internal_test"
    [ -n "$(ls "$d"/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$')" ] || empty="$empty ${p#stillfail/}/$n.blackbox_test"
    [ -n "$(ls "$d"/*_wbtest.mbt 2>/dev/null)" ] || empty="$empty ${p#stillfail/}/$n.whitebox_test"
  done
  export MBC_EMPTY_TESTS="$empty"
  # The app part's small packages' programs (the library's, the settings', gallery's, player's: a few tests each, the
  # whole of mbui in each) compiled without optimising (MBC_LIGHT_TESTS): a change to mbui compiled its units again in
  # each of them beside sfapp's, ~80 s of four programs' compile on CI's four cores, 2026-10-24, 40127533069
  light=""
  # (a release/* branch's run: yesterday's main, ~24 h behind the 3 h of units main's store keeps, is never merged back
  # into main and runs only the default rate, so the whole app's programs are light there as before #7350: cold at their
  # own level its app build ran past 233 s and its replay build past 202 s, 44919782303, 2026-11-22)
  release_light=0
  if [ -n "${GITHUB_ACTIONS:-}" ] && [[ "${GITHUB_REF:-}" == refs/heads/release/* ]]; then release_light=1; fi
  for p in $pkgs; do
    case $p in
      -p) continue ;;
      stillfail/core) [ "$release_light" = 1 ] || continue ;;
      stillfail/sfreplay/flows) [ "$release_light" = 0 ] || light="$light sfreplay/flows/flows.blackbox_test"; continue ;;
      stillfail/sfapp) [ "$release_light" = 0 ] || light="$light sfapp/sfapp.whitebox_test"; continue ;;
      stillfail/sfapp_realsize) [ "$release_light" = 0 ] || light="$light sfapp_realsize/sfapp_realsize.blackbox_test"; continue ;;
      stillfail/sfapp_pages_test) [ "$release_light" = 0 ] || light="$light sfapp_pages_test/sfapp_pages_test.blackbox_test"; continue ;;
      # (sfapp's program and the flows' at their own level, a branch's as main's: a branch's built at -O0, its 409 units
      # of sfpages, sfdesk, sfbase and sfapp were none of them main's once merged, which compiled them again at -O2
      # past its app build's budget, 44452414116, 2026-11-19. Their tests' units are test.<unit>, at MBC_TEST_OPT below)
      stillfail/sfreplay/*) continue ;;
    esac
    n=$(basename "$p")
    light="$light ${p#stillfail/}/$n.internal_test ${p#stillfail/}/$n.blackbox_test ${p#stillfail/}/$n.whitebox_test"
  done
  export MBC_LIGHT_TESTS="$light"
  # (release/*: a whole app's program built alone keeps mbui's and the library's units at its own level (mbc's
  # MBC_LIGHT_KEEP), which run in every frame of its tests, at -O0 2.5 times as long, 44243493008)
  if [ "$release_light" = 1 ]; then
    case " $light " in
      *" sfapp/sfapp.whitebox_test "*) [ "$pkgs" = "-p stillfail/sfapp" ] && export MBC_LIGHT_KEEP="ui_ stillfail_sfgraphic_" ;;
      *" sfapp_realsize/sfapp_realsize.blackbox_test "*) [ -n "${REALSIZE_BUILD_OUT:-}" ] && export MBC_LIGHT_KEEP="ui_ stillfail_sfgraphic_" ;;
      *" sfapp_pages_test/sfapp_pages_test.blackbox_test "*) [ -n "${PAGES_TEST_BUILD_OUT:-}" ] && export MBC_LIGHT_KEEP="ui_ stillfail_sfgraphic_" ;;
      *" sfreplay/flows/flows.blackbox_test "*) [ -n "${REPLAY_BUILD_OUT:-}" ] && export MBC_LIGHT_KEEP="ui_ stillfail_sfgraphic_" ;;
    esac
  fi
  # A test's functions (its *_test.mbt's, *_wbtest.mbt's) in units of their own (mbc's test.<unit>), compiled at -O1 in
  # every program at its own level (mbc's MBC_TEST_OPT), a branch's as main's, so what a branch compiled is what main
  # takes from the store once merged: sfapp's 526 test files are 92% of its source, beside its 43, and at -O2 a change
  # of mbui's took main's app build past five minutes compiling them (44452414116), at -O0 its tests ran 2.5 times as
  # long (44243493008). The program's own code at its own level, the tests running through it at full speed
  export MBC_TEST_OPT=${MBC_TEST_OPT:--O1}
  out=$(mktemp)
  # Built first on its own (TIMES=1, as CI's: each said with how long it took; its errors shown by the run), then run.
  s=$(date +%s)
  # (a build that fails fails the run: the programs a build before it left in _build are not run in their place)
  if [ -z "${APP_EXE:-}" ] && [ -z "${REPLAY_EXE:-}" ] && [ -z "${REALSIZE_EXE:-}" ] && [ -z "${PAGES_TEST_EXE:-}" ] && ! moon test $mode $pkgs --build-only > "$out.build" 2>&1; then
    grep -v "$F" "$out.build" | tail -40
    rm -f "$out.build"
    exit 1
  fi
  rm -f "$out.build"
  [ -z "${TIMES:-}" ] || [ -n "${APP_EXE:-}${REPLAY_EXE:-}${REALSIZE_EXE:-}${PAGES_TEST_EXE:-}" ] || echo "test.sh: built in $(( $(date +%s) - s )) s"
  # (wasm-gc: the whole app's programs (sfapp's, the flows') run as a native one built elsewhere is (APP_EXE, exe_run),
  # their files side by side, each part a moonrun of the program (scripts/wasmtest.mjs): moon test runs a program's
  # tests one after another. UPDATE's are moon test's own, to write the snapshots)
  wasm_exe() {
    local dir=_build/wasm-gc/release/test/stillfail/$1 kind=$2 pkg=stillfail/$1
    [ -f "$dir/$(basename "$1").${kind}_test.wasm" ] || return 1
    printf '#!/bin/sh\nexec node "%s/wasmtest.mjs" "%s" %s "$1"\n' "$D" "$A/$dir/$(basename "$1").${kind}_test.wasm" "$pkg" \
      > "$dir/run-$kind"
    chmod +x "$dir/run-$kind"
    echo "$A/$dir/run-$kind"
  }
  if [ $t = wasm-gc ] && [ -z "${UPDATE:-}" ] && [ -z "${APP_EXE:-}" ] && [[ " $pkgs " = *" -p stillfail/sfapp "* ]]; then
    APP_EXE=$(wasm_exe sfapp whitebox) && APP_INFO=$A/_build/wasm-gc/release/test/stillfail/sfapp/__whitebox_test_info.json \
      || APP_EXE=""
  fi
  # (sfapp's test program and its tests' list put where APP_BUILD_OUT says, for the jobs that run it: nothing run)
  if [ -n "${APP_BUILD_OUT:-}" ]; then
    b=_build/native/release/test/stillfail/sfapp
    [ -f $b/sfapp.whitebox_test.exe ] || { moon test $mode $pkgs --build-only 2>&1 | grep -v "$F" | tail -40; exit 1; }
    mkdir -p "$APP_BUILD_OUT" && cp $b/sfapp.whitebox_test.exe $b/__whitebox_test_info.json "$APP_BUILD_OUT/" &&
      cp "$(bash "$D/testexe" path)" "$APP_BUILD_OUT/testexe" || exit 1
    ! command -v strip >/dev/null 2>&1 || [ "$(uname -s)" != Linux ] || strip --strip-unneeded "$APP_BUILD_OUT/sfapp.whitebox_test.exe" "$APP_BUILD_OUT/testexe" || true
    echo "test.sh: sfapp's test program put in $APP_BUILD_OUT ($(du -h "$APP_BUILD_OUT/sfapp.whitebox_test.exe" | cut -f1))"
    [ -z "${MBUI_BUILT_MARK:-}" ] || touch "$MBUI_BUILT_MARK"
    exit 0
  fi
  # (sfapp_realsize's test program and its tests' list put where REALSIZE_BUILD_OUT says, for the jobs that run it: nothing run)
  if [ -n "${REALSIZE_BUILD_OUT:-}" ]; then
    b=_build/native/release/test/stillfail/sfapp_realsize
    [ -f $b/sfapp_realsize.blackbox_test.exe ] || { moon test $mode $pkgs --build-only 2>&1 | grep -v "$F" | tail -40; exit 1; }
    mkdir -p "$REALSIZE_BUILD_OUT" && cp $b/sfapp_realsize.blackbox_test.exe $b/__blackbox_test_info.json "$REALSIZE_BUILD_OUT/" &&
      cp "$(bash "$D/testexe" path)" "$REALSIZE_BUILD_OUT/testexe" || exit 1
    ! command -v strip >/dev/null 2>&1 || [ "$(uname -s)" != Linux ] || strip --strip-unneeded "$REALSIZE_BUILD_OUT/sfapp_realsize.blackbox_test.exe" "$REALSIZE_BUILD_OUT/testexe" || true
    echo "test.sh: sfapp_realsize's test program put in $REALSIZE_BUILD_OUT ($(du -h "$REALSIZE_BUILD_OUT/sfapp_realsize.blackbox_test.exe" | cut -f1))"
    [ -z "${MBUI_BUILT_MARK:-}" ] || touch "$MBUI_BUILT_MARK"
    exit 0
  fi
  # (sfapp_pages_test's test program and its tests' list put where PAGES_TEST_BUILD_OUT says, for the jobs that run it: nothing run)
  if [ -n "${PAGES_TEST_BUILD_OUT:-}" ]; then
    b=_build/native/release/test/stillfail/sfapp_pages_test
    [ -f $b/sfapp_pages_test.blackbox_test.exe ] || { moon test $mode $pkgs --build-only 2>&1 | grep -v "$F" | tail -40; exit 1; }
    mkdir -p "$PAGES_TEST_BUILD_OUT" && cp $b/sfapp_pages_test.blackbox_test.exe $b/__blackbox_test_info.json "$PAGES_TEST_BUILD_OUT/" &&
      cp "$(bash "$D/testexe" path)" "$PAGES_TEST_BUILD_OUT/testexe" || exit 1
    ! command -v strip >/dev/null 2>&1 || [ "$(uname -s)" != Linux ] || strip --strip-unneeded "$PAGES_TEST_BUILD_OUT/sfapp_pages_test.blackbox_test.exe" "$PAGES_TEST_BUILD_OUT/testexe" || true
    echo "test.sh: sfapp_pages_test's test program put in $PAGES_TEST_BUILD_OUT ($(du -h "$PAGES_TEST_BUILD_OUT/sfapp_pages_test.blackbox_test.exe" | cut -f1))"
    [ -z "${MBUI_BUILT_MARK:-}" ] || touch "$MBUI_BUILT_MARK"
    exit 0
  fi
  # (the flows' test program and its tests' list put where REPLAY_BUILD_OUT says, the same way)
  if [ -n "${REPLAY_BUILD_OUT:-}" ]; then
    b=_build/native/release/test/stillfail/sfreplay/flows
    [ -f $b/flows.blackbox_test.exe ] || { moon test $mode $pkgs --build-only 2>&1 | grep -v "$F" | tail -40; exit 1; }
    mkdir -p "$REPLAY_BUILD_OUT" && cp $b/flows.blackbox_test.exe $b/__blackbox_test_info.json "$REPLAY_BUILD_OUT/" &&
      cp "$(bash "$D/testexe" path)" "$REPLAY_BUILD_OUT/testexe" || exit 1
    ! command -v strip >/dev/null 2>&1 || [ "$(uname -s)" != Linux ] || strip --strip-unneeded "$REPLAY_BUILD_OUT/flows.blackbox_test.exe" "$REPLAY_BUILD_OUT/testexe" || true
    echo "test.sh: the flows' test program put in $REPLAY_BUILD_OUT ($(du -h "$REPLAY_BUILD_OUT/flows.blackbox_test.exe" | cut -f1))"
    # (then the core's tests here, the flows' left to replay-fps's runs of it)
    pkgs="${pkgs/ -p stillfail\/sfreplay\/flows/}"
  fi
  # (the small packages' test programs and their tests' lists put where PKGS_BUILD_OUT says, each under its package's
  # path, with the tool; then run here as ever. A kind a package has none of is a stand-in, MBC_EMPTY_TESTS: not put)
  if [ -n "${PKGS_BUILD_OUT:-}" ]; then
    for p in $pkgs; do
      [ "$p" = -p ] && continue
      q=${p#stillfail/} n=$(basename "$p") b=_build/native/release/test/$p
      [ -d "src/$q" ] || continue
      for k in internal blackbox whitebox; do
        [[ " $MBC_EMPTY_TESTS " = *" $q/$n.${k}_test "* ]] && continue
        [ -f $b/$n.${k}_test.exe ] || { echo "test.sh: no $b/$n.${k}_test.exe to put in $PKGS_BUILD_OUT" >&2; exit 1; }
        mkdir -p "$PKGS_BUILD_OUT/$q" && cp $b/$n.${k}_test.exe $b/__${k}_test_info.json "$PKGS_BUILD_OUT/$q/" || exit 1
        ! command -v strip >/dev/null 2>&1 || [ "$(uname -s)" != Linux ] || strip --strip-unneeded "$PKGS_BUILD_OUT/$q/$n.${k}_test.exe" || true
      done
    done
    cp "$(bash "$D/testexe" path)" "$PKGS_BUILD_OUT/testexe" || exit 1
    ! command -v strip >/dev/null 2>&1 || [ "$(uname -s)" != Linux ] || strip --strip-unneeded "$PKGS_BUILD_OUT/testexe" || true
    echo "test.sh: the packages' test programs put in $PKGS_BUILD_OUT ($(du -sh "$PKGS_BUILD_OUT" | cut -f1))"
    # (and run from there side by side, pkgs_run, on the runner of their own (APP_GROUP=pkgs) as at a rate)
    PKGS_EXE=$PKGS_BUILD_OUT
  fi
  # (MBUI_BUILT_MARK: that file written once every program this run builds is built and put where it goes, whatever
  # their tests say after: check-mbui keeps a branch's units only from a build that came to its end, never one cut or
  # failed half way. APP_BUILD_OUT's, above, before its exit)
  [ -z "${MBUI_BUILT_MARK:-}" ] || [ -n "${APP_EXE:-}${REPLAY_EXE:-}${REALSIZE_EXE:-}${PAGES_TEST_EXE:-}" ] || touch "$MBUI_BUILT_MARK"
  s=$(date +%s)
  # The page files FILE... dealt to the runners SPECS (each "programs,cores,others,times": its programs for the pages,
  # its cores, the seconds its other runs take of them, and how many times it runs each page, two where it runs two
  # rates in turn): a line "k FILE" each, the longest first, onto the k that, with it, would end the soonest (its pages
  # over its programs, or with its other runs over its cores, whichever is longer; the lowest k among equals). A file's
  # time is its line's in scripts/page-seconds.txt at the rate (MBUI_TEST_FPS: the default, 60, 120, 24 or 7), 1 where
  # it is 0, and a file not there yet, or `-` there at the rate (none measured it), counts as one of the longest (the
  # column's ninetieth percentile), so it is dealt early to whichever runner has room: as the median, chat_find_wbtest (116 s at 120 a second, new in #5283) went with
  # app 1/4 at 120 fps's own and made it 280 s of its 5 minutes (42936333352, 2026-11-11). Every runner at one rate
  # deals the same.
  page_deal() {
    local specs=$1
    shift
    [ $# = 0 ] && return
    printf '%s\n' "$@" | awk -v col=$(case "${MBUI_TEST_FPS:-}" in "") echo 2 ;; 60) echo 3 ;; 120) echo 4 ;; *) echo 5 ;; esac) '
      FNR == NR { if ($1 !~ /^#/ && $col != "-") { w[$1] = $col > 0 ? $col : 1; if ($col > 0) v[++m] = $col }; next }
      FNR == 1 { for (i = 2; i <= m; i++) for (j = i; j > 1 && v[j - 1] > v[j]; j--) { t = v[j]; v[j] = v[j - 1]; v[j - 1] = t }
        new = m ? v[int(m * 9 / 10) + 1] : 1 }
      { b = $0; sub(/.*\//, "", b); print ((b in w) ? w[b] : new), $0 }' "$D/page-seconds.txt" - |
      LC_ALL=C sort -k1,1nr -k2,2 | awk -v specs="$specs" '
        function end(g, l) { l *= x[g]; return (l / p[g] > (o[g] + l) / c[g]) ? l / p[g] : (o[g] + l) / c[g] }
        BEGIN { k = split(specs, s, " ")
          for (g = 1; g <= k; g++) { split(s[g], q, ","); p[g] = q[1]; c[g] = q[2]; o[g] = q[3]; x[g] = q[4] } }
        { best = 1
          for (g = 2; g <= k; g++) if (end(g, load[g] + $1) < end(best, load[best] + $1)) best = g
          load[best] += $1; print best, $2 }'
  }
  # Moon runs each test program serially; shard sfapp alongside the other packages.
  if [ "${APP_GROUP:-}" = pkgs ] && [ -n "${PKGS_EXE:-}" ]; then runs=("@pkgs"); else runs=("$pkgs"); fi
  if [ "${APP_FILES:-}" = none ] && [[ " $pkgs " = *" -p stillfail/sfapp "* ]]; then
    # (no sfapp file: a branch that changed only the small packages' test files, mbui-check.yml's rates-changed)
    runs=("$(echo " $pkgs " | sed 's| -p stillfail/sfapp | |')")
    [ -z "${PKGS_EXE:-}" ] || runs+=("@pkgs")
  elif [[ " $pkgs " = *" -p stillfail/sfapp "* ]]; then
    files=(src/sfapp/*_wbtest.mbt)
    # (APP_FILES: those of sfapp's test files alone, sweeps among them as ever: a branch's run of the files it changed at
    # the rates, mbui-check.yml's rates-changed)
    [ -z "${APP_FILES:-}" ] || read -r -a files <<< "$APP_FILES"
    n=${SFAPP_SHARDS:-5}
    # (the day's run, SFAPP_SHARDS=1: its pages a process for each group's share, every file after the ones before it
    # there, at the default rate alone; at a rate as a push runs them. All the pages in one process at a rate were more
    # than its job's 10 minutes, 1,141-3,990 s of them by page-seconds.txt, the day's mbui-check cancelled or failed
    # every day since 2026-11-09: 43151279466, app 4/4 at 24, 7, 60 and 120 fps stopped at 615 s, 2026-11-12)
    one_process=
    if [ "$n" = 1 ] && [ -n "${APP_GROUP:-}" ] && [ -n "${APP_EXE:-}" ]; then
      if [ -n "${MBUI_TEST_FPS:-}" ]; then n=4; else one_process=1; fi
    fi
    runs=("$(echo " $pkgs " | sed 's| -p stillfail/sfapp | |')")
    # Run the screen sweeps beside page tests, so their durations do not add. Corners includes squeeze's screens (and,
    # in its Chinese run, a press's room and the light theme's contrast: each screen opened once for all its rules);
    # the long-text, contrast, and kept-row sweeps have their own processes.
    # (preview_tree's 121 tests in two: one process of it at 120 frames a second was 104-175 s, the longest of its
    # part's job by 110 s and more, the job 156-263 s of its 5 minutes, main d2791a7a 42719997459,
    # core/bound-devices-sign 42720203578, 2026-11-10)
    # (FILE:@N, in two at its test N: preview_tree's halves by count were 140-242 s and 72-88 s of app 4/4 at 120 fps,
    # its part 1/2 260 s of its 5 minutes, main c96bf86e 42774790006, 2026-11-10: its test 54, the long name's bar at
    # each platform, size of words, width and state, 48 viewers opened, is a fifth of the file's time alone (13 s of 62
    # in Wasm on Studio, the others 1 s each). Cut before it, the two are 28 s and 34 s; a test added before it moves N)
    # (kept_rows_kinds' four by count put three of its longest (中屏 read out, both scrolled) in one run, 166-233 s at 120 a
    # second alone, app 3/4 at 120 fps part 2/2 226-247 s of its 5 minutes, main e1c758fc 42939211803, mbui-chooser-node
    # 42940297713, 2026-11-11: those three a run each, @2@3@4@5@8, the last run still 8-11 on the second)
    # (chat_page_nodes' in two by count: the chat's page made as nodes tested more each day (16 tests to 26 on
    # 2026-11-13), 180 s alone at 120 a second, the longest file of app 2/4 at 120 fps part 2/3's 272 s of its 5
    # minutes, main bcb03cad 43359172114, 130 at the default rate where the table had 21)
    # (send_steady's in three, at its tests 1 and 2: it walks its frames itself, 48, 50 and 51 sends at as many paces,
    # 151-221 s in one process at the default rate, the longest run of app 4/4's 230 s of its 5 minutes, its pages
    # ended before it, ci/default-rate-others-reckoned 43344761305, 2026-11-13; at a rate it returns at once)
    # (answers_still's in three, a Home and a chat each: every screen walked at six paces of the core's answers, new in
    # #5996 and not in page-seconds.txt, so dealt as one page of the column's ninetieth percentile; one process of it was
    # 256 s of app 4/4 at 120 fps part 2/3 and 117 s of app 1/4 at 24 7 fps, which its 7 then cut at its 5 minutes,
    # main 0d56014c 43468965521, 2026-11-13) (in five since, its 中屏 and 大屏 a run each: in three, beside the first's
    # pages and packages at 120, its 小屏 pair was 118 s and the others 218 and 224, main af1435b8 43476543010)
    # Five share-card tests take about 55 s each. Cut by hand at their indices, new screens moved them on: three fell in
    # tests 75-82, 202 s (ded934c144 44605217183), 328 s and cut at its 5 minutes on main 67e99adf7 (44602004555).
    # switches_still is now cut in 32 even runs, its switches_part interleaving the screens so a run's ten tests walk
    # screens 32 apart: no two of a row of 32 share a run.
    # send_steady has nine tests now, and tests 2-3 (22 and 27 paced sends) walk the most frames. Its 2-9 range ran
    # as one process on app 4/4, which hit the 5-minute limit at 318 s on main f855908e (44401157133). Cut it in five.
    sweeps=(src/sfapp/screens_wbtest.mbt:1 src/sfapp/corners_wbtest.mbt:6 src/sfapp/squeeze_said_wbtest.mbt:1
      src/sfapp/contrast_wbtest.mbt:1 src/sfapp/preview_tree_wbtest.mbt:@54
      src/sfapp/words_large_wbtest.mbt:2 src/sfapp/duo_side_wbtest.mbt:2 src/sfapp/send_steady_wbtest.mbt:@1@2@3@4
      src/sfapp/chat_page_nodes_wbtest.mbt:2 src/sfapp/answers_still_wbtest.mbt:@2@3@4@5
      src/sfapp/switches_still_wbtest.mbt:32)
    pages=()
    while IFS= read -r f; do
      [[ " ${sweeps[*]} " = *" $f:"* ]] || pages+=("$f")
    done < <(grep -l '^test "' "${files[@]}" </dev/null 2>/dev/null)
    for w in "${sweeps[@]}"; do
      f=${w%:*} k=${w##*:}
      [ -f "$f" ] && [[ " ${files[*]} " = *" $f "* ]] || continue
      # (at a rate, MBUI_TEST_FPS, no run of the screens', squeeze_said's and words_large's: each checks a screen at
      # rest, as the corners and contrast sweeps do, which run at the default rate alone (their groups are only
      # there). Screens' draws its frames at the Mac's recorded moments, so a rate changes nothing in it (wasm-gc on one
      # machine: 16.2 s at the default rate, 14.6 s at 7, 15.3 s at 120: the same run again); words_large and
      # squeeze_said did not once fail at a rate alone in a day's 490 pipeline runs, 2026-11-10. The three at the four
      # rates were 788 of the app tests' 6,599 process-seconds in 42928153698. Still sweeps: never dealt among the pages)
      if [ -n "${MBUI_TEST_FPS:-}" ]; then
        # (real_size's, every screen opened on a workspace of real size and given its changes, the same: a sweep of every
        # screen, its bars set on the default run; 40-102 s a run at the four rates, #5407 42976047326)
        # (duo_side's, every screen's controls held clear of an iPhone Duo's column on its side, at rest: the same)
        # (switches_still's, every screen's switches pressed, its table set on the default run: main's switches job's alone)
        # (corners' and contrast's too, said here since a branch's changed files at a rate (APP_GROUP=1/1, every run on the
        # one): main's rates never ran them (their groups are the default rate's alone), and a branch that changed
        # corners_wbtest ran its three at 120 and 60 with the motion counted on one runner, cut at its 5 minutes,
        # lock-upgrade-page 43559278519, 2026-11-14)
        case $f in */screens_wbtest.mbt | */squeeze_said_wbtest.mbt | */words_large_wbtest.mbt | */duo_side_wbtest.mbt | */switches_still_wbtest.mbt | */corners_wbtest.mbt | */contrast_wbtest.mbt) continue ;; esac
        # (send_steady's one run: at a rate eight of its nine tests return at once, the file 1 s (page-seconds.txt),
        # where its five cuts moved the app part's count so that chat_page_nodes' two halves fell on part 3/3 and part
        # 1/3 and part 3/3 at 60 was cut at 318 s; one run here, part 1/3, the halves on part 2/3 and part 3/3)
        case $f in */send_steady_wbtest.mbt) k=1 ;; esac
      fi
      # (in k runs of its tests by their index: moon test FILE --index FROM-TO, the tests in the file's order)
      m=$(grep -c '^test "' "$f")
      # (@N@M…: cut before each of those tests, as their time says, not by count)
      if [ "${k#@}" != "$k" ]; then
        a=0
        for c in ${k//@/ } $m; do [ "$c" -gt "$a" ] && [ "$c" -le "$m" ] && runs+=("$f --index $a-$c") && a=$c; done
        continue
      fi
      if [ "$k" -le 1 ] || [ "$m" -le 1 ]; then runs+=("$f"); continue; fi
      for ((j = 0; j < k; j++)); do
        a=$((j * m / k)) b=$(((j + 1) * m / k))
        [ $b -gt $a ] && runs+=("$f --index $a-$b")
      done
    done
    if [ -n "$one_process" ]; then
      # (the day's, on the four runners: each group's share by the files' times, in one process)
      g1=() g2=() g3=() g4=()
      while read -r g f; do
        case $g in 1) g1+=("$f") ;; 2) g2+=("$f") ;; 3) g3+=("$f") ;; *) g4+=("$f") ;; esac
      done < <(page_deal "1,1,0,1 1,1,0,1 1,1,0,1 1,1,0,1" "${pages[@]}")
      runs+=("@pages 1 1 ${g1[*]}" "@pages 2 1 ${g2[*]}" "@pages 3 1 ${g3[*]}" "@pages 4 1 ${g4[*]}")
      export APP_JOBS=1
    elif [ "$n" = 1 ]; then
      # (one: the files that test the pages in one process, every one after the ones moon runs before it, so what one
      # leaves behind that a later one trips on shows (shards, a process each, hide it))
      runs+=("${pages[*]}")
    elif [ -n "${APP_EXE:-}" ]; then
      # (on a program built elsewhere: the pages in runs whose programs each take the next file (exe_run's xargs -P),
      # not dealt out beforehand to the programs: by name round four one took 75 s while another took 21, 2026-11-01)
      # (dealt to the four runners by the cores each has free: all of them on the fourth, its job's tests were
      # 218-276 s, cut at its 5 minutes, while the first ran two processes for 143 s, the second four for 150 (one
      # long, three short), the third three for 90, 2026-11-05: of each fifteen, seven to the fourth with four
      # programs, three to the first and four to the second with two each, one to the third with one) (the first's
      # with four since: on a runner of its own, nothing beside them, two of its cores stood idle while preview_tree,
      # taken late by name, ran 162 s of its 265 at 120 fps, mbui-motion-layer3 42659257481, 2026-11-10) (six to the
      # fourth and four to the first since: at 60 a second the fourth's pages were 243 s, its job 254 of its 5 minutes,
      # the first's job 59 s, core-unheld-messages 42723740236, main 2c1c63b8 42723386381, 2026-11-10)
      # (each run's files the largest first, as its programs take the next: by name, a group's longest files came
      # last (tape_wbtest 110-138 s at 120 a second, quote_image 146 s, of the fourth's 140 the 121st and later) and ran
      # on alone after the rest, app 1/4 at 120 fps 278 s and 283 s, delta-updates 42749767767,
      # fix/cached-android-java-sources 42755835282, 2026-11-10; the files dealt to a group change as files come)
      # (each file onto the group, then the part, that would end the soonest with it, the longest first by its time in
      # CI, scripts/page-seconds.txt. A group's runners: the first's pages on four programs, the second's on two, the
      # third's on one, the fourth's on four, each on four cores; at 120 a second the second, third and fourth on two
      # runners (APP_PART), at 60 the fourth, and at 24 and 7 the fourth a runner a rate where the others run both in turn
      # (mbui-check.yml's app-rates). Their other runs, seconds of their cores, from main's runs of 2026-11-10 and 11
      # and ci/pages-dealt-by-time 42928057443: the first's preview_tree 80 at the default rate and 180 at 60; the
      # second's sweeps 160, 400 at 60, 340 on its two at 120, 210 at 24 and 7; the third's kept_rows 240, 340, 370 and
      # 450; the fourth's 220 on its two at 120, 190 at 24 and at 7. Dealt by place (four, four, one and six of each
      # fifteen) or by shares alone, the second's pages beside its sweeps were 225-268 s of app 2/4 at 60 fps, its two
      # programs each on a file of 92-111 s, main da1d0b20 42919874518, 35383456 42925799584, 42928057443)
      # (at a rate since the screens', squeeze_said's and words_large's sweeps are none (above): the second's other run
      # is kept_rows' last alone, 15 s at 60, 26 at 120, 9 and 5 at 24 and 7, so its pages have its four cores, four
      # programs as the first's and the fourth's, and at 60 one runner again; the fourth's at 24 and at 7 is
      # preview_tree's alone, 173 and 73 (42928153698, 2026-11-11, before this); the first's has the packages' programs
      # too (@pkgs), five side by side beside its pages: 107 s at 60 beside preview_tree's 220, 157 at 120, 46 and 43 at
      # 24 and 7, its job at 120 211 s with them counted 40 (ci-rates-for-what-they-test 42942660697, 2026-11-11))
      # (at 60 the first's other runs are 560 s of its cores, not 330, and the third's 600, not 340: preview_tree's
      # halves 152 and 222 s and the packages' 190 beside its pages, kept_rows' five runs 81-148 s; app 1/4 at 60 fps
      # was 289 s of its 5 minutes, its pages 278, where the second's and fourth's were 175 and 202,
      # mbui-reused-block-at-once 42992663019, 2026-11-11)
      # (at 24 and 7 the third's other runs, kept_rows' five at each, are 840 s of its cores, not 450: its pages beside
      # them on one program were 148 and 120 s, the job 281 s of its 5 minutes, mbui-lang-reset 42998551581; the
      # fourth's, preview_tree's halves, 123 and 99, not 170)
      if [ -n "${APP_GROUP:-}" ] && [ "${APP_GROUP#*/}" = 4 ]; then
        case "${MBUI_TEST_FPS:-}" in
          # (the first's other runs at 60 436 s of its cores, not 560: the packages' 173 and preview_tree's halves 153
          # and 110, main 23971ce1 43066168046, 2026-11-11, where the fourth's pages were 288 s of its 300 on its four)
          # (dealt so, the first's 271 s, the fourth's 251, the second's 240 and the third's 121 at 60, main 4d4bc73a
          # 43070391697: the third's pages on one program beside kept_rows' five runs took little. Its pages on two
          # now, and the first's other runs between the two measures)
          # (its pages on two the third's at 60 were 259-266 s, kept_rows' runs slowed beside them: main 436755fc
          # 43074044573, f06a53f3 43076123102; on one 121-199. Reckoned at 800 of its cores, fewer pages)
          # (two programs gave the third 86 page files beside kept_rows at 60, 271 s of them, the job 281 s of its 5
          # minutes, main e73742ee 43081853101: one again, as it was at 121-199 s)
          # (the second's at 60 260-281 s of its 5 minutes on main's last five runs, the third's 114-207: the second
          # reckoned 200 s of other runs it has not, so it is dealt fewer pages; main f4940357 43103370007, 2026-11-11)
          # (dealt so the fourth's at 60 was 211-277 s on main's five runs after, and stopped at its five minutes once,
          # its tests passed in 289 s, main f7367fe4 43114028979, 2026-11-11; the second's 136-223. The same deal ran
          # 150 s on one runner and 223 on another, so four runners levelled at some 215 s have no room. The fourth's on
          # two runners at 60 as at 120 (mbui-check.yml's app-rates, APP_PART), eight programs; the second's other runs
          # as they are, 20; the first's, 200: its pages' 755 s beside them were 154-276 s. By page-seconds.txt's times
          # at 60 written again from those five runs (the fourth's 941 s of pages there, its job 248 s, the second's 560
          # and 145): each runner's pages some 160 s on its programs)
          # (the first's other runs reckoned 200 there was wrong: dealt so its job was 261 s, main 0430f0a7
          # 43118127081, the packages' programs 242 s, its 81 pages' files 237 (462 s of them by the table), preview_tree's
          # halves 180 and 125, so some 500 s of its cores beside its pages, as it was reckoned before; the second's
          # job was 115 s, the third's 140, the fourth's two 127 and 180. 520 again: its pages 279 s by the table)
          # (the second's pages at 60 893-1008 s of its four programs where the table said 836-862, beside its other
          # run's 17-20, app 2/4 at 60 fps 252-263 s of its 5 minutes on main 7ffd403c, 01816ca5, e21b10c4, 2026-11-12;
          # the first's beside the packages' programs, two processes each since #5844 (213 s), and preview_tree's halves
          # (216 and 152) some 700 s of its cores, its job 245 s; the fourth's two parts 150-171 s. So the second is
          # reckoned 120 and the first 700: by the table some 60 s of the second's pages and 30 of the first's go to the
          # fourth's eight programs, the third's to them too)
          # (the fourth's 100, 120, 50 and 120 more at 60, 120, 24 and 7 and the default rate: chat_page_nodes' two,
          # above, as main's runs of 2026-11-13 measured the file)
          # (the fourth's on three runners at 60 as at 120, twelve programs (mbui-check.yml's app-rates says why): the
          # other three's pages dealt fewer by as much, app 1/4 at 60 fps 288 s of its five minutes on ed9727a1)
          # (the third's answers_still five runs at 60 are some 410 s, not the 91 reckoned for them: beside kept_rows'
          # five (some 960) its 44 pages on one program were 288-289 s, app 3/4 at 60 fps 298 and 299 s of its 5
          # minutes on main 7b8ad5f2 43493491412 and dd870393 43496129988, where the first's was 183 and the second's
          # 137-165. Reckoned 1000: by the table its pages all go to the others (the first +45 s on its four programs,
          # the second +40 on its four, the fourth +131 on its twelve), which have the room)
          # (page-seconds.txt written again from main's runs of 2026-11-18 (44391836965, 44389380389, 44379034613): the
          # first's job was 123-137 s at 60 beside its 222 s of pages by the table, its other runs reckoned too many; the
          # second's 289 s of its 5 minutes on a slow runner with 621, reckoned too few; the third's one program near
          # empty. The first reckoned 320, the second 300, the third 900: by the table the first's pages 418 s, the
          # second's 437, the fourth's 2093 on its twelve)
          # (the third's 86 s at 60 with no page, its one program near empty: reckoned 600, it takes 131 s of the table's
          # pages, the fourth's 2129 s down to 2035 on its twelve, reckoned 160)
          60) specs="4,4,320,1 4,4,300,1 1,4,600,1 12,12,160,1" ;;
          # (the first's packages' programs at 120 275 s beside its pages' 263, the job 295 s of its 5 minutes, main
          # 436755fc 43074044573, 2026-11-11: reckoned 160 s of its cores, they take some 500 now)
          # (the second's and the fourth's on three runners each at 120, twelve programs (mbui-check.yml's app-rates
          # says why): by the table every runner's pages 180 s a program where they were 246)
          # (the first's pages at 120 ran 1.9-2.0 times their table's times (852-890 s of 449: flight_under_bar 114 of
          # 46, usage_wide_made 75-91 of 7) beside the packages' programs, some processes each on its four cores, where
          # the fourth's part 1/3 ran 0.8-1.0: app 1/4 at 120 fps 223-275 s of its 5 minutes on main ec512e53 43542799229,
          # 93c11f44 43543602427, 64ef3c14 43546815737, the second's and fourth's parts 102-197. Reckoned 800: by the
          # table its pages 400 s to 242, the second's twelve programs +120, the fourth's +18, the third's +20)
          120) specs="4,4,420,1 12,12,26,1 2,8,850,1 12,12,460,1" ;;
          # (the first's other runs at 24 and 7, the packages' programs, 105-133 s and 85-106 beside its pages, not the
          # 46 and 43 they were reckoned at: its job 235-266 s of its 5 minutes on main's runs of 2026-11-12, a3e59ea9
          # 43157398527, 36b56f21 43159426488, c9f8f144 43159891701; reckoned 300 of its cores, the third's 900 so that
          # its pages on one program take none of the first's)
          # (the second's pages at 24 and 7 562 and 456 s of its four programs where the table said 408 at each, app 2/4
          # at 24 7 fps 270-272 s of its 5 minutes on main 6e1e487a 43335323020, b13bf078 43336207216, 2026-11-13; the
          # third's kept_rows five runs some 250 s of its cores at each rate, not 450, its job 130-139 s. So the
          # second is reckoned 150, as at 60 for what runs beside its pages, and the third 500: by the table some 70 s
          # of the second's pages at each rate go to the third's program and the fourth's)
          # (the first's pages beside its packages' programs at 24 and 7 139 and 114 s where the table said 338 at
          # each over four programs, the packages' 91 and 80, app 1/4 at 24 7 fps 250-267 s of its 5 minutes on main
          # 559256a0, ecd82606, 2026-11-13, the second's 147: the first reckoned 450, the second 100. By the table
          # the first's pages go from 338 s to 262 at each rate, the second's from 387 to 450)
          # (the first's and the second's at 24 and at 7 a runner a rate since, as the fourth's: running both in turn they
          # were 4.2 and 4.7 min of their 5 on main af1435b8 43476543010, the fourth's at 24 4.6 beside other runs of 600 s
          # of its cores (preview_tree's halves, chat_page_nodes' two, answers_still's) where it was reckoned 290. Each
          # reckoned for one rate: the first's packages' programs 75-87 s, the second's kept_rows run 12)
          24 | 7) specs="4,4,225,1 4,4,50,1 1,4,500,2 4,4,600,1" ;;
          # (at the default rate each group's other runs reckoned as they now run, branch pushes of 2026-11-13
          # (mbui-chat-made-always 43343545286): the first's real_size half 190 s and preview_tree's halves 61 and 97
          # beside its pages, some 350 s of its cores where they were reckoned 80, its pages 215-229 s, app 1/4 209-242 s
          # of its 5 minutes; the second's sweeps some 210, the third's kept_rows five some 390, the fourth's
          # real_size half 42 and send_steady's three (above) some 220. The third's reckoned 500, not its 390: on one
          # program its pages are its job. By the table the first's pages go from 623 s to 485, the second's from 351
          # to 417 (on two programs, 117-131 s of 351 before), the third's from 167 to 140, the fourth's from 720 to
          # 668 beside send_steady's three)
          # (send_steady's three beside the fourth's pages were 114, 137 and 149 s, with real_size's half 78 and its
          # pages 211, app 4/4 222-237 s of its 5 minutes on main c54dc28b 43348134004 and branches after: reckoned 300,
          # by the table some 95 s of its pages go to the other three)
          # (the first's other runs some 560-600 s of its cores since (real_size's half 200-232 s, preview_tree's halves
          # 69-120, answers_still's five), its pages 252-291 s on five pushes of 2026-11-14 and app 1/4 cut at its 5
          # minutes on main 3ee6f477 (43540456308, attempt 1); the third's 270-440, its job 94-159 s; the second's
          # 276-473 and the fourth's 324-477 as reckoned. The first reckoned 600, the third 400: by the table some 160 s
          # of the first's pages go to the second (two programs), the third and the fourth, 787 s to 627)
          # (answers_still's five on the third since (some 200-220 s of its cores): the third reckoned 600. The first kept
          # at 600 for its pages, which ran there 1.85 times their table's times: by the table its pages 627 s to 607,
          # the third's 306 to 286, the second's 573 to 593, the fourth's 766 to 786)
          # (real_size's phone half, some 85-105 s, on the third since: the third reckoned 700. Its pages are its one
          # program's, so the deal hardly moves; the fourth kept at 420 for its pages' slowness beside its runs)
          # (read stays' six files, 433 s by the table (the 大屏 page-before ones 99-106 s each, a third of the lot's
          # longest): with them the fourth's pages were 782-940 s by the table and ran 1187-1189 s beside send_steady's
          # three (one of 99 s ran 223), app 4/4 cut at its 5 minutes on three pushes, its tests passed in 302 s on the
          # last; the third's pages on its one program 249 s at 354; the first's 146 s at 800 and the second's 184 s at
          # 717 on their four and two (#6134, 43568641653, 43569987964). So the third reckoned 1400 and the fourth 900:
          # by the table the first's pages some 1060 s, the second's 830, the third's 260, the fourth's 760)
          # (read stays' files made cheap, 433 s of the table to some 50 (#6178): the same reckoning then dealt the
          # first 1190 s of pages by the table and app 1/4 was cut at its 5 minutes, the others 179-204 s
          # (43577616575); main's own app 1/4 cut at 317 s the same hour (43577920185). The first reckoned 950: by the
          # table its pages 970 s, the second's 960, the third's 480, the fourth's 1020)
          # (page-seconds.txt written again (#6210): the third's pages, 239 s by the table on its one program, ran
          # 237-302 s beside its eleven other runs (829 s of its cores), app 3/4 the longest of the four on main and
          # branches alike, 254-312 s (cut at its 5 minutes on main 02416d29 43580485463; reply-place 43588784943 298 s),
          # the others 151-235. The third reckoned 1500: by the table its pages 172 s, the first's 637, the second's
          # 795, the fourth's 705, each of those some 10-35 s of the table more, on their four and two)
          # (the third's pages, 235 s by the table on its one program, ran 217-243 s beside kept_rows', answers_still's
          # and real_size's eleven runs, app 3/4 227-255 s of its 5 minutes on four pushes of 2026-11-14 (43604749359,
          # 43605560534, 43605643007), the second's 181-235 on its two programs, the first's and fourth's 105-152 on their
          # four. The third reckoned 1650 and the second 650: by the table the third's pages 132 s, the second's 694 (751),
          # the first's 622 (529), the fourth's 666 (599))
          # (dealt so, the third's job was 132-170 s on main 2c8f3745 43607717744 and branches after, the first's
          # 212-243 and the fourth's 227-261: too many taken from the third. Reckoned 1580: by the table its pages 188 s,
          # the first's 598, the second's 690, the fourth's 643)
          # (dealt so, the first's pages ran 235 s, some 0.39 s for each of the table's beside real_size's half (195 s)
          # and preview_tree's halves, where the fourth's ran 149, 0.23, and the second's and third's jobs 142 and 153
          # (app-deal-third-2's push, 2026-11-14). The first reckoned 1150 and the fourth 800: by the table the first's
          # pages 462 s, the second's 710, the third's 188, the fourth's 759)
          # (dealt so, the fourth's job was 199-268 s on main 152b19b5 43615169071 and branches after #6295, its pages
          # 245-275 beside send_steady's three; the first's 132-197 and the third's 142-183. The fourth reckoned 900,
          # the first 1060 and the third 1590: by the table the first's pages 523 s, the second's 711, the third's 205,
          # the fourth's 682)
          # (dealt so, the fourth's job was the longest of the four on main's runs of the evening, 241-257 s (ab5e69b4
          # 43639248574: 197, 219, 168, 257), the third's 163-212: the fourth reckoned 980, the third 1550. By the
          # table the first's pages 567 s, the second's 683, the third's 259, the fourth's 612, where they were 533,
          # 688, 211 and 689 with the files merged since)
          # (dealt so, with the files merged since, the third's pages were 265 s by the table on its one program and ran
          # 278 s: app 3/4 271 s on main 7b151c31 (43658036848) and 294 s on farview-pace (43658053979), the others
          # 160-251. The third reckoned 1650: by the table the first's pages 598 s, the second's 705, the third's 199,
          # the fourth's 619)
          # (reckoned by what ran, not by what was reckoned before: on five pushes of 2026-11-16 (43844048935,
          # 43845665634, 43844188947, 43847582791, 43847194601) each group's job was its pages' file-seconds over its
          # programs, near enough (the first 470 s on four, 118 s; the second 383 on two, 192; the third 175-271 on its
          # one, its job 175-284; the fourth 845 on four, 214), whatever ran beside them, and the reckonings had drifted
          # from what did (the first reckoned 1030 where its other runs were some 160 s of runs, the third 1650 where
          # its were 620-750): the first's job was half the third's. page-seconds.txt written again from those runs (26
          # files it had not, each dealt as one of the longest) and each group's other runs reckoned at half their
          # runs' seconds, as they share its cores with the pages (the first's real_size half and preview_tree's halves
          # 160 s of runs, the second's sweeps 420, the third's kept_rows, real_size and answers_still 650, the
          # fourth's send_steady three 230 since they skip the frames nothing asks for); the third's pages on two
          # programs (p3, below), one leaving their 175-271 s to one core: by the table some 200 s a group)
          # (dealt so, #6678's 43854977577: app 1/4 211 s of tests (real_size's wide half 169 beside its pages' 211),
          # 2/4 203 (its pages on two programs the longest), 3/4 170, 4/4 139 (send_steady's three 38-60 s). Each
          # reckoned again so that what was dealt would have ended as it ran, the wide window's real_size on the
          # fourth, the second's pages on three programs: by the table 720, 355, 386 and 711 s of pages)
          # (dealt so, 43857300626: app 1/4 198 s, 2/4 116, 3/4 188, 4/4 234 with real_size's wide half there; that
          # half on the second since, each reckoned again as it ran: by the table 658, 546, 364 and 604 s of pages)
          # (real_size's wide half on the fourth since (app_group_of), the second's reckoning raised for what ran there
          # beside it all the same, 43864771728: by the table 715, 503, 393 and 561 s of pages)
          # Account for the real_size and kept_rows sweeps on groups 1 and 4.
          # Group 2 now runs its pages on four workers after its sweeps finish. words_large and the second
          # chat_page_nodes run moved to contrast and group 1 (app 2/4 was cut at 292 s with 549 -O0 units,
          # mbui-w5c-composer-node 44240663495, while contrast took 112 s, 4/4 137 s and 3/4 150 s). Pages lean
          # to group 1, which had the most room at -O0 (44243280552: 1/4 174 s, 3/4 236 s, 4/4 268 s).
          # main f855908e (44401157133) cut app 4/4 at 318 s while contrast took 157 s, 1/4 185 s, 3/4 207 s and
          # 2/4 225 s. kept_rows 3-4 and send_steady's last two ranges moved to contrast. About 145 s of pages
          # moved from group 4 to group 1. By the table: 1103, 643, 763 and 643 s of pages (was 988, 648, 728, 788).
          # fdb3787b0 (44553344108, -O0) cut app 1/4 at 308 s: its 101 page files ran 296 s beside 447 s of other
          # runs (chat_page_nodes 22-44, chat_drive_parity 0-4 and preview_tree's halves), while 2/4 took 176 s,
          # 3/4 157 s and 4/4 124 s. main b7ddfb6b07 (44553113433, -O2): 205, 172, 235 and 128 s. Group 1 reckoned
          # 500 and group 4 400 (group 2 600): about 300 s of pages moved from group 1 to groups 4 and 2. By the
          # table: 757, 657, 697 and 856 s of pages (was 1057, 597, 717, 596).
          # #8203's 45064931159 (-O0) cut app 2/4 at 317 s: its 97 page files ran beside chat_page_nodes' two (113-133 s),
          # squeeze_said (100-111) and screens (70-84), seven processes on four cores, while 1/4 took 146 s, 3/4 115 s
          # and 4/4 140 s (send_steady's three, 65-75 s). On main (-O2, 45063615978, 45052196659) 2/4 was the slowest
          # too, 168-187 s, and 4/4 125-140. Screens moved to the fourth (app_group_of), page-seconds.txt written again
          # from those runs and 45045217984. Reckoned so (group 2 760, group 3 560, group 4 500), 45066643199 took
          # 154 s for 1/4, 119 s for 2/4 (its two other runs 148 s), 221 s for 3/4 (its 583 s of pages ran 204 s beside
          # answers_still's five runs, nine processes on four cores) and 139 s for 4/4. Group 2 reckoned 660, group 3
          # 700, group 4 460. By the table: 643, 483, 443 and 683 s of pages (was 804, 704, 743 and 903 by the old
          # table).
          *) specs="4,4,500,1 4,4,660,1 4,4,700,1 4,4,460,1" ;;
        esac
        g1=() g2=() g3=() g4=()
        while read -r g f; do
          case $g in 1) g1+=("$f") ;; 2) g2+=("$f") ;; 3) g3+=("$f") ;; *) g4+=("$f") ;; esac
        done < <(page_deal "$specs" "${pages[@]}")
        # The second group's pages use $n workers at every rate, so they fill all cores once its sweeps finish.
        # The third's use $n at the default rate and one at a rate, beside kept_rows' five runs.
        p2=$n p3=$n
        [ -z "${MBUI_TEST_FPS:-}" ] || p3=1
        runs+=("@pages 1 $n ${g1[*]}" "@pages 2 $p2 ${g2[*]}" "@pages 3 $p3 ${g3[*]}" "@pages 4 $n ${g4[*]}")
      else
        runs+=("@pages 0 $n $(page_deal 1,1,0,1 "${pages[@]}" | cut -d' ' -f2 | tr '\n' ' ')")
      fi
      export APP_JOBS=$n
    else
      for ((k = 0; k < n; k++)); do
        shard=()
        for ((i = k; i < ${#pages[@]}; i += n)); do shard+=("${pages[i]}"); done
        [ ${#shard[@]} = 0 ] || runs+=("${shard[*]}")
      done
    fi
    # (the small packages' programs built once at the default rate, PKGS_EXE: their runs at a rate here, on the first)
    [ -z "${PKGS_EXE:-}" ] || runs+=("@pkgs")
  fi
  # Real-size sweep and budget tests (src/sfapp_realsize, blackbox test program): built apart from sfapp so sfapp
  # carries no sfrealsize payloads or budget tables. real_size_test.mbt runs at the default rate alone, split at @1@2
  # (indices 0-1, 1-2, 2-end) beside the package's other test files.
  if [[ " $pkgs " = *" -p stillfail/sfapp_realsize "* ]] && [ "${MBC_LTO:-0}" != thin ]; then
    rest=()
    # (a run named by @ (@pkgs, @pages …) kept as it is: one padded with blanks matched none of its names below and ran
    # as the app's; a run that was the real-size package alone left out)
    for r in "${runs[@]}"; do
      case "$r" in
        @*) rest+=("$r") ;;
        *)
          # (rr, not s: s is when the run began, read again as each run's time is said)
          rr=$(echo " $r " | sed 's| -p stillfail/sfapp_realsize | |')
          [ -z "${rr// /}" ] || rest+=("$rr")
          ;;
      esac
    done
    runs=("${rest[@]}")
    rx=${REALSIZE_EXE:-_build/native/release/test/stillfail/sfapp_realsize/sfapp_realsize.blackbox_test.exe}
    [ $t = wasm-gc ] && rx=$(wasm_exe sfapp_realsize blackbox)
    rs_files=(src/sfapp_realsize/*_test.mbt)
    [ -z "${REALSIZE_FILES:-}" ] || read -r -a rs_files <<< "$REALSIZE_FILES"
    rs_sweep_runs=0
    rs_other=()
    while IFS= read -r f; do
      if [ "$f" = src/sfapp_realsize/real_size_test.mbt ]; then
        if [ -z "${MBUI_TEST_FPS:-}" ]; then
          m=$(grep -c '^test "' "$f")
          a=0
          for c in 1 2 $m; do
            if [ "$c" -gt "$a" ] && [ "$c" -le "$m" ]; then
              if [ $t != js ] && [ -z "${UPDATE:-}" ] && [ -n "$rx" ] && [ -f "$rx" ]; then
                runs+=("@realsize_sweep $f --index $a-$c")
              else
                runs+=("$f --index $a-$c")
              fi
              rs_sweep_runs=$((rs_sweep_runs + 1))
              a=$c
            fi
          done
        fi
      else
        rs_other+=("$f")
      fi
    done < <(grep -l '^test "' "${rs_files[@]}" </dev/null 2>/dev/null)
    if [ ${#rs_other[@]} -gt 0 ]; then
      if [ $t != js ] && [ -z "${UPDATE:-}" ] && [ -n "$rx" ] && [ -f "$rx" ]; then
        rs_j=${REALSIZE_JOBS:-4}
        [ "$rs_sweep_runs" -gt 0 ] && [ "$rs_j" -gt 2 ] && rs_j=2
        runs+=("@realsize_pages $rs_j ${rs_other[*]}")
      else
        runs+=("${rs_other[*]}")
      fi
    fi
  fi
  # Pages, settings, stations, files and viewer blackbox tests (src/sfapp_pages_test): built apart from sfapp so
  # sfapp's whitebox C stays smaller and faster to compile.
  if [[ " $pkgs " = *" -p stillfail/sfapp_pages_test "* ]] && [ "${MBC_LTO:-0}" != thin ]; then
    rest=()
    # (a run named by @ kept as it is, as the real-size package's above: "@pages …" padded with a blank matched no
    # name of it below, APP_PART dealt none of its files and gave every one of them to its last part, #7620's)
    for r in "${runs[@]}"; do
      case "$r" in
        @*) rest+=("$r") ;;
        *)
          rr=$(echo " $r " | sed 's| -p stillfail/sfapp_pages_test | |')
          [ -z "${rr// /}" ] || rest+=("$rr")
          ;;
      esac
    done
    runs=("${rest[@]}")
    px=${PAGES_TEST_EXE:-_build/native/release/test/stillfail/sfapp_pages_test/sfapp_pages_test.blackbox_test.exe}
    [ $t = wasm-gc ] && px=$(wasm_exe sfapp_pages_test blackbox)
    pt_files=(src/sfapp_pages_test/*_test.mbt)
    [ -z "${PAGES_TEST_FILES:-}" ] || read -r -a pt_files <<< "$PAGES_TEST_FILES"
    pt_other=()
    while IFS= read -r f; do
      pt_other+=("$f")
    done < <(grep -l '^test "' "${pt_files[@]}" </dev/null 2>/dev/null)
    if [ -n "${PAGES_TEST_PART:-}" ] && [ ${#pt_other[@]} -gt 0 ]; then
      pt_k=${PAGES_TEST_PART%/*} pt_n=${PAGES_TEST_PART#*/}
      pt_mine=()
      for ((idx = 0; idx < ${#pt_other[@]}; idx++)); do
        [ $((idx % pt_n + 1)) -eq "$pt_k" ] && pt_mine+=("${pt_other[idx]}")
      done
      pt_other=("${pt_mine[@]}")
    fi
    if [ ${#pt_other[@]} -gt 0 ]; then
      if [ $t != js ] && [ -z "${UPDATE:-}" ] && [ -n "$px" ] && [ -f "$px" ]; then
        pt_j=${PAGES_TEST_JOBS:-4}
        runs+=("@pages_test_pages $pt_j ${pt_other[*]}")
      else
        runs+=("${pt_other[*]}")
      fi
    fi
  fi
  # The flows seen again (src/sfreplay/flows, one program): their files in REPLAY_SHARDS moon tests side by side (3),
  # the core's tests in another. One moon test ran them one after another, 83 s of the replay part's run on CI's four
  # cores, the part the pipeline's longest on a branch (mbui-parts-nodes, 40573326799, 2026-10-28).
  if [[ " $pkgs " = *" -p stillfail/sfreplay/flows "* ]] && [ "${MBC_LTO:-0}" != thin ]; then
    flows=(src/sfreplay/flows/*_test.mbt)
    n=${REPLAY_SHARDS:-3}
    rest=()
    for r in "${runs[@]}"; do rest+=("$(echo " $r " | sed 's| -p stillfail/sfreplay/flows | |')"); done
    runs=("${rest[@]}")
    fx=${REPLAY_EXE:-_build/native/release/test/stillfail/sfreplay/flows/flows.blackbox_test.exe}
    [ $t = wasm-gc ] && fx=$(wasm_exe sfreplay/flows blackbox)
    if [ $t != js ] && [ -z "${UPDATE:-}" ] && [ -n "$fx" ] && [ -f "$fx" ]; then
      # (native: their files in one run of the program built above, whose n programs each take the next file
      # (exe_run's xargs -P), not dealt out beforehand: dealt by name round three, 68 s, 43 and 41, the replay
      # part's 183 s the pipeline's longest job, chat-opener-links 41248997629, 2026-11-01)
      runs+=("@flows ${flows[*]}")
    else
      for ((k = 0; k < n; k++)); do
        shard=()
        for ((i = k; i < ${#flows[@]}; i += n)); do shard+=("${flows[i]}"); done
        [ ${#shard[@]} = 0 ] || runs+=("${shard[*]}")
      done
    fi
  fi
  # Which of APP_GROUP's n runners a run is on (k of 1..n). Four (check-mbui's): each two or three of the runs that
  # were the app part's longest side by side on one runner's four cores, 2026-10-27 (corners 188 s and 171, kept_rows'
  # 187 and 147, the pages' 174, contrast's 117, screens' 77, squeeze_said's 49, the packages' 10, all nine at once:
  # the part's run 188 s). Alone on four runners (40425191188) corners in Chinese was 92 s, every other run 52 s or less:
  # its press's room and contrast a third corners run since, on the first: on the fourth beside the pages and contrast,
  # the three slowed each other to 85, 81 and 38 s while the first ran 38 (adb-card-direct, 40430050749). A run named
  # nowhere here is the first's, never left out. (Screens' then on the second: beside both Chinese corners runs on the
  # first it slowed them to 74 and 62 s, the second running 37, 40430734093.) (Contrast's on the first since the small
  # packages went to a runner of their own: the fourth's job was the part's longest, the pages' 72 s beside contrast's 25,
  # while the first ran its two corners runs in 26, fix/back-cancel-follows-system 40828675419, mbui-panel-ground
  # 40843559612, 2026-10-29.) (Then on the third: the first's job beside the corners runs was the part's longest but the
  # pages', 152 s and 179, the second's and third's 96 and 101, main 9a748590, 40942683567, 2026-10-30.) (On a runner of
  # its own since: beside kept_rows' two runs the third's was then the longest, 162-185 s against the first's 110-118,
  # fix/side-bar-under-band 40955953763, msg-highlight 40955729359; wherever it went it was some 50 s of that runner's.)
  # (kept_rows' second run on the second since: with both of them the third's job was the part's longest after the
  # pages', the second's the shortest, 65-123 s against 157-182, fix/swipe-archive-undo 40972095755, mbui-node-asks
  # 40971809575, main ff97a641 40971760122, 2026-10-30.)
  # (kept_rows' in four since, the first three on the third, side by side on its cores, the last on the second beside
  # its three: the third's one process of 65 s was its job's longest, 183 s on main 99a74aa4, 2026-10-31.)
  app_group_of() {
    local n=$1
    shift
    if [ "$n" != 4 ]; then echo 1; return; fi
    case "$1 $2 $3" in
      "-p "*) echo 1 ;;
      # (the small packages' programs, at a rate: on the first, beside its pages)
      "@pkgs  ") echo 1 ;;
      # (corners' three runs on a runner of their own since, beside the four: its English run alone 240 s of the second's
      # 252 on arch/next, its Chinese 200 of the first's, each push near its 5 minutes and some cut, ci-corners-once
      # 42003619842, 2026-11-05: back among the four once a screen opens in one build, as on main)
      "src/sfapp/corners_wbtest.mbt "*) echo corners ;;
      "src/sfapp/screens_wbtest.mbt  ") echo 4 ;;
      "src/sfapp/squeeze_said_wbtest.mbt  ") echo 2 ;;
      # (screens', squeeze_said's and words_large's at the default rate alone: the sweeps' loop above says why)
      # (words_large's sweep, every screen at the system's larger words, on the second, whose jobs had the most room:
      # dealt with the pages by name it was the fourth's at 60 a second, one of its last files to start, 51-59 s of its
      # 214-262, 2026-11-10. It was the fourth's at 24 and at 7, which has a runner for each, while it ran at a rate:
      # the second ran both in turn, 138 s and 117 s of pages beside its four sweeps, 267 s of its 5 minutes, main
      # 62fed392 42751653901)
      # (its two, the app's two languages, a run each: in one at 120 a second it was 173 s of the second's part 2/2, 257 s
      # of its 5 minutes on main caa9c272, 42759467421, 2026-11-10)
      # (on contrast since: on the second beside its other sweeps, app 2/4 was cut at 292 s when 549 -O0 units were
      # compiled, mbui-w5c-composer-node 44240663495, while contrast took 112 s)
      "src/sfapp/words_large_wbtest.mbt "*) echo contrast ;;
      # (real_size's, its two windows a test each since it gives each screen its changes as well, apart on the two with
      # the most room at the default rate: the wide window's, the longer, on the first, where the opening alone was
      # 103 s of its 5 minutes (#5407 42976047326); the phone's on the fourth, which has no run but its pages. On Studio
      # in Wasm 37 s and 13 s where the opening alone was 28 s: some 135 s and 50 s here, 2026-11-11)
      # (its tests cut at each of its two sweeps since #6627 put a quick test of its own first: cut in two halves, the
      # first was that test alone and the second both sweeps, "--index 1-3", matched by none of these and dealt to the
      # fourth beside its 142 files of pages, 306 s, app 4/4 cut at its 5 minutes on main 202a54dc 43822504735)
      # (the wide window's on the second since, the one with the most room: on the first beside its pages on four
      # programs it ran 169 s, app 1/4 228 s (#6678's 43854977577); on the fourth 197 s beside its pages and
      # send_steady's three, app 4/4 234 s, where app 2/4 was 116 (43857300626))
      # (and on the fourth since: on the second beside its pages on three programs and its sweeps, eleven processes on
      # its four cores, it ran 200 s and app 2/4 293 s, every other run there slowed alike (screens 175 s), where app 4/4
      # with send_steady's three alone beside its pages was 108, #6694's 43864771728)
      # At the default rate, contrast runs the wide real_size sweep, send_steady 3-4 and 4-9, and both duo_side and
      # words_large runs.
      "src/sfapp/duo_side_wbtest.mbt "*) echo contrast ;;
      # (preview_tree's two on the fourth, the one with the most programs: at 120 a second APP_PART gives each of its
      # two halves one; at 24 and at 7 the fourth has a runner for each. At the default rate and at 60 on the first:
      # there the fourth's 138 files of pages and preview_tree's two, six processes on its four cores, were 214-273 s
      # of its 5 minutes at 60, the same commit's runs 50 s apart by their runners alone, while the first's job was
      # 54-124 s, main 85413543 42736997391, station-conversations-survive 42739107408, 2026-11-10)
      "src/sfapp/preview_tree_wbtest.mbt "*) case "${MBUI_TEST_FPS:-}" in "" | 60) echo 1 ;; *) echo 4 ;; esac ;;
      "src/sfapp/contrast_wbtest.mbt  ") echo contrast ;;
      # (switches_still's runs, every screen's switches pressed over a core answering late, on four runners of
      # their own, every fourth on each (APP_PART), four side by side on its four cores: main's alone, after a merge
      # (mbui-check.yml's switches). Cut where its tests' time, as main's runs measured it, comes to a sixteenth each:
      # by count, ten a run past the 60th and two before it, a runner's fourteen runs side by side on its four cores were
      # 200-280 s each, its job 295 s of its 5 minutes, main 4dda0ed0 43565383295, 2026-11-14 (its chats' screens, 20-52,
      # the most). No more runners for it (the owner: 「不要一慢就拆」, 「分片会排队」))
      # (seventeen since, its tests 52-68 cut at 60: that one run was 273-279 s, part 1/4 288-291 s of its 5 minutes on
      # main 98178dc5 43606413194 and cf48243e 43604572194, its other three runs 68-132 s; the other parts 108-166 s)
      # (eighteen since, its tests 52-60 cut at 56: that run was 247 s on main ccb596e1 43609558227, part 1/4 258 s
      # beside its four others (99-167 s), where 60-68 was 96; its tests 52-59 8-11 s each on Studio, none the most)
      "src/sfapp/switches_still_wbtest.mbt "*) echo switches ;;
      # (send_steady's three on the fourth, beside its pages on its four cores: the deal reckons them there)
      # At the default rate its last two ranges go to contrast, which had the most room (44401157133).
      "src/sfapp/send_steady_wbtest.mbt --index 3-4" | "src/sfapp/send_steady_wbtest.mbt --index 4-"*)
        [ -z "${MBUI_TEST_FPS:-}" ] && echo contrast || echo 4 ;;
      "src/sfapp/send_steady_wbtest.mbt "*) echo 4 ;;
      # (chat_page_nodes' two on the fourth, the one with the most programs; reckoned there at each rate. At the
      # default rate on the second, whose pages are on two programs beside its sweeps: on the fourth beside
      # send_steady's three, real_size's half and its pages, ten processes on its four cores, app 4/4 was 238-249 s
      # of its 5 minutes on 2026-11-13's pushes after #5906, the second's 158)
      # (at 120 a second on the third since, whose two parts had the room, 112-189 s: on the fourth's three parts, its
      # tests 14-28 beside preview_tree's 0-54 on the first, app 4/4 at 120 fps part 1/3 was 272-295 s of its 5
      # minutes on main's runs after #6096 and cut at them on 8b149318 43562087371)
      # (at the default rate its second run on the first since, for the same cut of app 2/4 as words_large's; the
      # fourth, beside send_steady's three, was the longest at -O0, 268 s, 44243280552)
      "src/sfapp/chat_page_nodes_wbtest.mbt --index 0-"*) case "${MBUI_TEST_FPS:-}" in "") echo 2 ;; 120) echo 3 ;; *) echo 4 ;; esac ;;
      "src/sfapp/chat_page_nodes_wbtest.mbt "*) case "${MBUI_TEST_FPS:-}" in "") echo 1 ;; 120) echo 3 ;; *) echo 4 ;; esac ;;
      # (answers_still's three where each rate's jobs had the most room on main 0d56014c 43468965521 without it: the
      # first at the default rate (162 s) and at 120 (122 s), the third at 60 (150 s), the fourth at 24 and at 7, a
      # runner each; reckoned in specs below: 31, 256, 91 and some 120 s of its cores)
      # (at 120 on the third since: on the first beside its pages and the packages' programs its runs were 560 s of its
      # cores, its job 4.2 min where it had been 2.5, the third's two 2.0 and 2.5, main af1435b8 43476543010)
      # (at the default rate on the third since: on the first, beside its pages on four programs, real_size's half and
      # preview_tree's halves, twelve processes on its four cores, its pages ran 1.85 times their page-seconds.txt
      # times where the other three's ran 0.6-0.9, app 1/4 286 s of its 5 minutes on mbui-picks-whole 43544698219
      # after #6086, the third's 164 s with its pages on one program)
      "src/sfapp/answers_still_wbtest.mbt "*) case "${MBUI_TEST_FPS:-}" in "" | 60 | 120) echo 3 ;; *) echo 4 ;; esac ;;
      "@pages "*) [ "$2" = 0 ] && echo 1 || echo "$2" ;;
      *) [ $# -gt 2 ] && echo 4 || echo 1 ;;
    esac
  }
  if [ -n "${APP_GROUP:-}" ] && [[ " $pkgs " = *" -p stillfail/sfapp "* ]]; then
    mine=()
    for r in "${runs[@]}"; do
      [ -n "${r// /}" ] || continue
      # (APP_GROUP=contrast, corners, switches: that sweep's runs alone, on a runner of their own, beside the four;
      # switches' on three, APP_PART below)
      if [ "$APP_GROUP" = contrast ] || [ "$APP_GROUP" = corners ] || [ "$APP_GROUP" = switches ]; then [ "$(app_group_of 4 $r)" = "$APP_GROUP" ] && mine+=("$r")
      else [ "$(app_group_of "${APP_GROUP#*/}" $r)" = "${APP_GROUP%/*}" ] && mine+=("$r"); fi
    done
    runs=("${mine[@]}")
    # (APP_PART=k/m: the k-th of m shares of this group's pages' files (page_deal's), and every m-th of its other runs: a
    # group too long for one runner's five minutes at a rate's frames (mbui-check's at 120 a second) on m. Its other
    # runs were all the first's: kept_rows' three runs and half the pages 228 s, the pages' 70 s of it beside them, the
    # second's same number of pages alone 18 s, main c1c5a1b0, 42653215101, 2026-11-10)
    if [ -n "${APP_PART:-}" ]; then
      mine=() o=0
      for r in "${runs[@]}"; do
        if [ "${r%% *}" = @pages ]; then
          read -r -a words <<< "$r"
          kept=()
          specs=$(printf '1,1,0,1 %.0s' $(seq ${APP_PART#*/}))
          # (the fourth's at 120 a second: its first part has preview_tree's tests 0-54 beside its pages, 81-111 s, the
          # second 54-121, 175-182 s, on one of the four cores each; dealt as though both had none, the second's job was
          # 259 s of its 5 minutes three times, the first's 145-212, main e0220aca 43130127033, e046fa45 43132128804,
          # 20027072 43133699456, 2026-11-12)
          # (in three parts since 2026-11-12, the third with none of preview_tree's: its other runs go to the first two)
          # (but the third has chat_page_nodes' tests 0-14 since, 145-161 s, and the first chat_page_nodes' 14-28 beside
          # preview_tree's 0-54, 183-218 s, the second preview_tree's 54-121, 121-177: the third's pages 260-272 s of a job
          # 275-283 of its 5 minutes on main c52e9bd2 43530192044, b4992a65 43546414824, cb22a840 43548862078, the
          # first's 172-198, the second's 136-199. Reckoned as they run: by the table the third's pages 893 s to 817, the
          # second's 714 to 817, the first's 743 to 716)
          # (chat_page_nodes' two on the third at 120 since (app_group_of): the first's other runs preview_tree's 0-54, the
          # second's its 54-121, the third's none but send_steady's moment)
          # (at 60 the first two parts each have half of chat_page_nodes' tests beside their pages (80 s of one core),
          # the third none: dealt as though none had any, part 2/3 ran its pages 284 s and was cut at its 5 minutes, part
          # 3/3 148-200 s, main a6881ee25 44395572349, 2026-11-18. At 120 the first two reckoned 250 and 280 were too
          # many: 136-169 s where the third was 294 on a3a444e19 44391836965. By the table, at 60 the parts' pages
          # 645, 644 and 804 s, at 120 512, 491 and 661)
          # (at 60 since send_steady is one run there: the first part has its 1 s, the second and third each half of
          # chat_page_nodes' tests (160 s of one core), the three parts some 785 core-s each by the table)
          if [ "${APP_GROUP:-}" = 4/4 ] && [ "${APP_PART#*/}" = 3 ]; then
            case "${MBUI_TEST_FPS:-}" in
              60) specs="4,4,0,1 4,4,160,1 4,4,160,1" ;;
              120) specs="4,4,150,1 4,4,170,1 4,4,0,1" ;;
            esac
          fi
          while read -r g f; do [ "$g" = "${APP_PART%/*}" ] && kept+=("$f"); done < <(page_deal "$specs" "${words[@]:3}")
          [ ${#kept[@]} = 0 ] || mine+=("${words[0]} ${words[1]} ${words[2]} ${kept[*]}")
        # (the pages_test files' share, PAGES_TEST_PART's already: kept whole, not dealt again)
        elif [ "${r%% *}" = @pages_test_pages ] && [ -n "${PAGES_TEST_PART:-}" ]; then
          mine+=("$r")
        else
          [ $((o % ${APP_PART#*/})) = $((${APP_PART%/*} - 1)) ] && mine+=("$r")
          o=$((o + 1))
        fi
      done
      runs=("${mine[@]}")
    fi
  fi
  # (APP_GROUP=switches on a program built already: its part's ranges of switches_still's tests as one run, a test a
  # process on a pool of the runner's cores (switches_run). As eight runs of ten side by side, eight processes shared
  # four cores, each at half of one (73-79 s of CPU at 151 s), and one range's ten in a row ran on alone with three
  # cores idle until part 2/4 was cut at 315 s of its 5 minutes, main 2787f032a 45042101395; one test's abort failed
  # the nine after it in its range too, part 4/4's screen 312 (exit 134), 45040104379)
  if [ "${APP_GROUP:-}" = switches ] && [ -n "${APP_EXE:-}" ] && [ ${#runs[@]} -gt 0 ]; then
    sw_file="" sw_ranges=() other=()
    for r in "${runs[@]}"; do
      read -r -a words <<< "$r"
      if [ ${#words[@]} = 3 ] && [ "${words[1]}" = --index ] && { [ -z "$sw_file" ] || [ "$sw_file" = "${words[0]}" ]; }; then
        sw_file=${words[0]} sw_ranges+=("${words[2]}")
      else
        other+=("$r")
      fi
    done
    [ -z "$sw_file" ] || runs=("@switches $sw_file ${sw_ranges[*]}" ${other[@]+"${other[@]}"})
  fi
  run_name() {
    [ "$1" = @pkgs ] && { echo "the packages$(cd "$PKGS_EXE" && find . -name '*_test.exe' | sed 's|^\./| |; s|/[^/]*$||' | LC_ALL=C sort -u | tr -d '\n')"; return; }
    [ "$1" = @flows ] && shift
    [ "$1" = @realsize_sweep ] && shift
    [ "$1" = @realsize_pages ] && shift 2
    [ "$1" = @pages_test_pages ] && shift 2
    [ "$1" = @pages ] && shift 3
    if [ "$1" = @switches ]; then
      local f=$2 n=0 r
      shift 2
      for r in "$@"; do n=$((n + ${r#*-} - ${r%-*})); done
      echo "$(basename "$f") ($n tests)"
      return
    fi
    case " $* " in
      *" -p "*) echo "the packages$(echo " $* " | sed 's| -p stillfail/| |g')" ;;
      *" --index "*) echo "$(basename "$1") (tests $3)" ;;
      *) [ $# -le 2 ] && echo $(basename -a "$@") || echo "$# files ($(basename "$1") ...)" ;;
    esac
  }
  # parts_watch DIR EXE: in CI, a part of exe_run's still running after MBUI_PART_SAYS seconds (150) is said at once on
  # the job's log (fd 9, the script's own stderr), never only in its run's output, which is printed after it ends: what
  # it runs, its process's state and CPU time, the last of what it printed, and its threads' stacks where gdb is there.
  # Why: app 1/4 was cut at its 5 minutes with nothing said of which file had not ended, #6837 b68070c9c and main
  # d77015c89, 2026-11-17, its runs 137 s otherwise.
  # (its sleep in the background, killed with it: a sleep of its own process left by exe_run's kill held fd 9, the
  # step's stderr, open up to 10 s after the tests ended, and app 4/4 at 60 fps part 2/3 was cut at its 5 minutes
  # 9.5 s after its tests had all passed in 284 s, main a6881ee25 44395572349, 2026-11-18)
  parts_watch() {
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    local d=$1 exe=$2 t0 said=" " name arg pid sp=
    trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; exit 0' TERM INT EXIT
    t0=$(date +%s)
    while :; do
      sleep 10 & # det-ok(script-wait): a watchdog's look at the parts still running, never a wait a test passes by
      sp=$!
      wait "$sp" 2>/dev/null || break
      sp=
      [ $(($(date +%s) - t0)) -ge "${MBUI_PART_SAYS:-150}" ] || continue
      while read -r name arg; do
        [ -f "$d/$name.out" ] && [ ! -f "$d/$name.code" ] || continue
        case "$said" in *" $name "*) continue ;; esac
        said="$said$name "
        {
          echo "test.sh: still running after $(($(date +%s) - t0)) s: $(basename "$exe") $arg"
          pid=$(ps -eo pid=,args= | awk -v e="$exe" -v a="$arg" 'index($0, e " " a) && !/ sh -c / { print $1; exit }')
          [ -z "$pid" ] || ps -o pid=,stat=,etime=,time=,wchan= -p "$pid" | sed 's/^/  ps: /'
          tail -20 "$d/$name.out" | sed 's/^/  said: /'
          if [ -n "$pid" ] && command -v gdb > /dev/null; then
            timeout 30 sudo -n gdb -batch -p "$pid" -ex 'thread apply all bt 40' 2>&1 | grep -a '^#\|^Thread' | head -80 | sed 's/^/  gdb: /'
          fi
        } >&9
      done < "$d/parts"
    done
  }
  # exe_run EXE INFO JOBS PKG FILE… | FILE --index FROM-TO: a run on a test program built already, JOBS of it side by
  # side, each taking the next part when done with one (xargs -P); tools/testexe says what to ask it and what it said.
  # JOBS as Neach: a process a file even on one (testexe says each file's seconds only of a run in more than one part)
  exe_run() {
    local exe=$1 info=$2 j=$3 pkg=$4 d c split=$3
    shift 4
    case $j in *each) j=${j%each} split=$((j > 1 ? j : 2)) ;; esac
    d=$(mktemp -d)
    "$TESTEXE" parts "$info" "$split" "$@" > "$d/parts" || { rm -rf "$d"; return 2; }
    if [ -s "$d/parts" ]; then
      parts_watch "$d" "$exe" &
      local w=$!
      sed "s|^|$d/|" "$d/parts" | xargs -P "$j" -L 1 sh -c \
        's=$(date +%s); "$0" "$2" > "$1.out" 2>&1; echo "$? $(($(date +%s) - s))" > "$1.code"' "$exe"
      kill $w 2>/dev/null
      wait $w 2>/dev/null
    fi
    "$TESTEXE" said "$info" "$d" "$pkg"
    c=$?
    rm -rf "$d"
    return $c
  }
  # switches_run EXE INFO JOBS PKG FILE FROM-TO…: exe_run's, a test a part, the ranges' tests taken across them (each
  # range's first, then each one's second, …), so its tests of the heavy screens (each range's first half: chats, the
  # card to share) go first and the light ones (settings) end it, JOBS of them side by side
  switches_run() {
    local exe=$1 info=$2 j=$3 pkg=$4 file=$5 d k=0 max=0 off r a b i c
    shift 5
    d=$(mktemp -d)
    for r in "$@"; do
      a=${r%-*} b=${r#*-}
      [ $((b - a)) -gt "$max" ] && max=$((b - a))
    done
    for ((off = 0; off < max; off++)); do
      for r in "$@"; do
        a=${r%-*} b=${r#*-}
        i=$((a + off))
        [ "$i" -lt "$b" ] || continue
        echo "$k $file:$i-$((i + 1))"
        k=$((k + 1))
      done
    done > "$d/parts"
    if [ -s "$d/parts" ]; then
      parts_watch "$d" "$exe" &
      local w=$!
      sed "s|^|$d/|" "$d/parts" | xargs -P "$j" -L 1 sh -c \
        's=$(date +%s); "$0" "$2" > "$1.out" 2>&1; echo "$? $(($(date +%s) - s))" > "$1.code"' "$exe"
      kill $w 2>/dev/null
      wait $w 2>/dev/null
    fi
    "$TESTEXE" said "$info" "$d" "$pkg"
    c=$?
    rm -rf "$d"
    return $c
  }
  # pkgs_run DIR: the small packages' programs put there (PKGS_BUILD_OUT), side by side, each on two processes taking
  # its next file (exe_run's): a process of all a package's files, as moon test runs it, was the first group's longest
  # run at every rate on main's 14 runs of 2026-11-12, 124-246 s at 120 a second, its pages ending 30-93 s before it
  # with its four cores to spare, app 1/4 at 120 fps 265 s of its 5 minutes (main 89fc703f 43324051783). On a runner
  # of their own (APP_GROUP=pkgs) at the default rate too, each program on four: as moon test, one process a package,
  # sfpages' 683 tests ran on one of its four cores and were cut at its deadline after a build of 130 s (#7244,
  # 2026-11-18).
  # (testexe says each file's seconds of its package: scripts/page-seconds.sh takes sfapp's alone)
  # (PKGS_FILES: only those of a package's files, a package with none of them not run)
  pkgs_run() {
    local e q k i=0 c=0 pids=() o f mine j=2
    [ "${APP_GROUP:-}" = pkgs ] && j=4
    o=$(mktemp -d)
    for e in $(cd "$1" && find . -name '*_test.exe' | sed 's|^\./||' | LC_ALL=C sort); do
      q=$(dirname "$e") k=${e%_test.exe}
      k=${k##*.}
      mine=(src/$q/*.mbt)
      if [ -n "${PKGS_FILES:-}" ]; then
        mine=()
        for f in $PKGS_FILES; do [ "$(dirname "$f")" = "src/$q" ] && mine+=("$f"); done
        [ ${#mine[@]} != 0 ] || continue
      fi
      exe_run "$1/$e" "$1/$q/__${k}_test_info.json" "$j" "stillfail/$q" "${mine[@]}" > "$o/$i" 2>&1 &
      pids+=($!) i=$((i + 1))
    done
    for e in "${pids[@]}"; do wait $e || c=1; done
    for ((e = 0; e < i; e++)); do cat "$o/$e"; done
    rm -rf "$o"
    return $c
  }
  # (the tool, built before the runs side by side, not by each: TESTEXE, or scripts/testexe's)
  if [ -n "${APP_EXE:-}" ] || [ -n "${REALSIZE_EXE:-}" ] || [ -n "${PAGES_TEST_EXE:-}" ] || [[ " ${runs[*]} " = *" @flows "* ]] || [[ " ${runs[*]} " = *" @pkgs "* ]] || [[ " ${runs[*]} " = *" @realsize_"* ]] || [[ " ${runs[*]} " = *" @pages_test_"* ]]; then
    # (in development the script itself: its program is Wasm, run by node)
    if [ -n "${GITHUB_ACTIONS:-}" ]; then [ -n "${TESTEXE:-}" ] || TESTEXE=$(bash "$D/testexe" path) || exit 1
    else TESTEXE=${TESTEXE:-$D/testexe}; fi
  fi
  pids=()
  for i in "${!runs[@]}"; do
    # (a run of nothing is none: moon test of no package would be every package's)
    [ -n "${runs[i]// /}" ] || continue
    # (each run's time with TIMES: the part's run is the longest of them, and which one it is is said)
    { if [ "${runs[i]%% *}" = @flows ]; then
        f=_build/$t/release/test/stillfail/sfreplay/flows
        exe_run "$fx" "${REPLAY_INFO:-$f/__blackbox_test_info.json}" ${REPLAY_SHARDS:-3} stillfail/sfreplay/flows \
          ${runs[i]#@flows } > "$out.$i" 2>&1
      elif [ "${runs[i]%% *}" = @realsize_sweep ]; then
        f=_build/$t/release/test/stillfail/sfapp_realsize
        exe_run "$rx" "${REALSIZE_INFO:-$f/__blackbox_test_info.json}" 1 stillfail/sfapp_realsize \
          ${runs[i]#@realsize_sweep } > "$out.$i" 2>&1
      elif [ "${runs[i]%% *}" = @realsize_pages ]; then
        set -- ${runs[i]}
        f=_build/$t/release/test/stillfail/sfapp_realsize
        exe_run "$rx" "${REALSIZE_INFO:-$f/__blackbox_test_info.json}" "${2}each" stillfail/sfapp_realsize \
          "${@:3}" > "$out.$i" 2>&1
      elif [ "${runs[i]%% *}" = @pages_test_pages ]; then
        set -- ${runs[i]}
        f=_build/$t/release/test/stillfail/sfapp_pages_test
        exe_run "$px" "${PAGES_TEST_INFO:-$f/__blackbox_test_info.json}" "${2}each" stillfail/sfapp_pages_test \
          "${@:3}" > "$out.$i" 2>&1
      # (the packages' programs where PKGS_EXE says: built elsewhere, at a rate; put there by this run's build on their
      # own runner, APP_GROUP=pkgs)
      elif [ "${runs[i]}" = @pkgs ]; then
        pkgs_run "$PKGS_EXE" > "$out.$i" 2>&1
      elif [ "${runs[i]%% *}" = @switches ]; then
        set -- ${runs[i]}
        sw_j=${SWITCHES_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
        [ "$sw_j" -ge 1 ] 2>/dev/null || sw_j=4
        switches_run "$APP_EXE" "$APP_INFO" "$sw_j" stillfail/sfapp "$(basename "$2")" "${@:3}" > "$out.$i" 2>&1
      elif [ "${runs[i]%% *}" = @pages ]; then
        set -- ${runs[i]}
        # (a process a file on one program too: the third's pages, on one at every rate, ran as one process and said no
        # file's time, so page-seconds.txt kept times of before for them (quote_image 99 s at 120 a second, unknown
        # ones at the median's) and app 3/4 at 120 fps part 1/2 was dealt 274-304 s of pages where its part 2/2 had
        # 114-149, cut at its 5 minutes once, main b310ef4c 43127552002, 3aa695f5 43121556932, f4d86e2a 43129595300,
        # 2026-11-12)
        # (the day's in one process: its files one after another, what one leaves behind there for the next)
        if [ -n "$one_process" ]; then j=1; else j="$3each"; fi
        exe_run "$APP_EXE" "$APP_INFO" "$j" stillfail/sfapp "${@:4}" > "$out.$i" 2>&1
      elif [ -n "${APP_EXE:-}" ] && [[ " ${runs[i]} " != *" -p "* ]]; then
        exe_run "$APP_EXE" "$APP_INFO" ${APP_JOBS:-1} stillfail/sfapp ${runs[i]} > "$out.$i" 2>&1
      else moon test $mode ${runs[i]} ${UPDATE:+--update} > "$out.$i" 2>&1; fi; c=$?
      echo "$(( $(date +%s) - s )) s: $(run_name ${runs[i]})" > "$out.time.$i"
      exit $c; } &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait $p || code=1; done
  for i in "${!runs[@]}"; do [ -f "$out.$i" ] && cat "$out.$i"; rm -f "$out.$i"; done > "$out"
  # (how what moves goes and each file's bars, said where a run says them (mbui's src/ui/tester_fps.mbt: motion_runs, at
  # 60 and 120 and with MBUI_TEST_BARS at the default rate): all of it kept, past LINES_OUT's tail)
  [ -z "${MOTION_OUT:-}" ] || grep -a '^MOTION ' "$out" >> "$MOTION_OUT"
  # (each flow's pace passes, where each split from its strict pass (src/sfreplay's orders), past LINES_OUT's tail)
  grep -a '^PACE [^ ]*: ' "$out"
  grep -v "$F" "$out" | grep -av '^MOTION ' | grep -v '^Total tests' | tail -${LINES_OUT:-60}
  # (and each test that failed, whole, its lines under it too, wherever it fell: past LINES_OUT's tail behind a run's
  # CLOCKREAD lines, main df98aad1's words_large failures were in no line of app 2/4's log nor in its What failed,
  # 42956992852, 2026-11-11)
  awk '/^\[[^]]*\] test .* failed/ { on = 1; print; next } on && /^  / { print; next } { on = 0 }' "$out" |
    sed '1s/^/test.sh: what failed, whole:\n/'
  # (and what testexe said of each run's files, its slowest and each one's seconds, which scripts/page-seconds.sh reads
  # back: behind the tail's last lines they were in no log, app 1/4 at 120 fps's pages 259-265 s of a run dealt as 139
  # with nothing to say which file grew, 42977201225 42980774839, 2026-11-11)
  grep -a '^testexe: ' "$out"
  grep '^Total tests' "$out"
  [ -z "${TIMES:-}" ] || cat "$out".time.* 2>/dev/null | sort -rn | sed 's/^/test.sh: a run of /'
  rm -f "$out".time.*
  [ -z "${TIMES:-}" ] || echo "test.sh: run in $(( $(date +%s) - s )) s"
  # (the core's answers a test asked and found not kept, src/sfkept: scripts/kept has the core work them out; KEPT_ASKS:
  # where it takes them from)
  asks=$(grep -c 'kept-answers-ask {' "$out")
  if [ "$asks" != 0 ]; then
    [ -n "$KEPT_ASKS" ] && grep 'kept-answers-ask {' "$out" >> "$KEPT_ASKS"
    echo "test.sh: $asks of the core's answers asked and not kept (src/sfkept): scripts/kept keeps them" >&2
    code=1
  fi
  rm -f "$out"
done
exit $code
