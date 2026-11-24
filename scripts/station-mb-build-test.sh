#!/bin/bash
# station/mb/build.sh with every tool it runs made up (moon, mbc, cc, ar, getconf: none compiles anything): the jobs it
# gives mbc (every core alone, shared among the readers scripts/native.ts builds side by side, MBC_JOBS over both),
# MoonBit headers taken from the store by their names and contents (so ci-1's runners compile the same units),
# MoonBit's runtime archived once and kept in MBC_STORE until what it is made of changes, moon's lock left by a
# build gone taken over, and --harness building the tests' program (src/reader_harness) beside the reader, each its own.
#   bash scripts/station-mb-build-test.sh [BUILD_SH]     (BUILD_SH: another build.sh to hold to the same, e.g. an older one)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
build=${1:-$here/station/mb/build.sh}
t=$(mktemp -d)
pids=()
trap 'for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$t"' EXIT
fail() { echo "station-mb-build-test: $*" >&2; exit 1; }

# The tree build.sh is run in: its own place, libs/ui/scripts/mbc beside it, the tools on PATH.
mkdir -p "$t/root/station/mb/src/reader" "$t/root/libs/ui/scripts" "$t/bin" "$t/moon/lib/runtime" "$t/moon/include" "$t/log" "$t/home" \
  "$t/root/rules/src" "$t/root/libs/base/src" "$t/root/libs/ui/src/effect" "$t/root/libs/ui/src/halt"
# (what the prepared C's key reads: build.sh's own tree's files)
for f in station/mb/moon.mod station/mb/moon.work station/mb/src/reader/reader.mbt rules/moon.mod rules/src/a.mbt libs/base/moon.mod libs/base/src/a.mbt \
  libs/ui/moon.mod libs/ui/scripts/mbc-stub.sh libs/ui/src/effect/a.mbt libs/ui/src/halt/a.mbt; do
  echo "$f" > "$t/root/$f"
done
cp "$build" "$t/root/station/mb/build.sh"
echo 'int moonbit_x;' > "$t/moon/lib/runtime/runtime.c"
echo 'int moonbit_y;' > "$t/moon/lib/runtime/other.c"
echo '#define MOONBIT 1' > "$t/moon/include/moonbit.h"
: > "$t/shell.a"

cat > "$t/bin/moon" <<'EOF'
#!/bin/bash
# (moon build of the reader: its C; of cprep, into --target-dir: a cprep that copies the C as it is)
[ "${1:-}" = version ] && { echo "moon made-up"; exit 0; }
dir= prev=
for a in "$@"; do [ "$prev" = --target-dir ] && dir=$a; prev=$a; done
if [ -n "$dir" ]; then
  mkdir -p "$dir/native/release/build/station/cprep"
  printf '#!/bin/sh\ncp "$1" "$2"\n' > "$dir/native/release/build/station/cprep/cprep.exe"
  chmod +x "$dir/native/release/build/station/cprep/cprep.exe"
  exit 0
fi
pkg=$(basename "${@: -1}")
mkdir -p "_build/native/release/build/station/$pkg"
echo "int main(void){return 0;} /* $pkg */" > "_build/native/release/build/station/$pkg/$pkg.c"
echo "$pkg" >> "$LOG/moon-builds"
EOF
cat > "$t/bin/getconf" <<'EOF'
#!/bin/bash
echo "${CORES:-16}"
EOF
cat > "$t/root/libs/ui/scripts/mbc" <<'EOF'
#!/bin/bash
[ "$1" = path ] && { echo /made-up/mbc; exit 0; }
[ "$1" = key ] && { echo made-up-mbc; exit 0; }
obj= j=none prev=
for a in "$@"; do
  case "$a" in --obj=*) obj=${a#--obj=} ;; -j=*) j=${a#-j=} ;; --cflags=*) echo "${a#--cflags=}" > "$LOG/cflags" ;; --extra=*) echo "${a#--extra=}" >> "$LOG/extras" ;; esac
  [ "$prev" = -j ] && j=$a
  prev=$a
done
cat "$a" > "$LOG/c"
echo "$j" > "$LOG/jobs"
mkdir -p "$obj"; echo unit > "$obj/unit.o"; echo "$obj/unit.o"
EOF
cat > "$t/bin/cc" <<'EOF'
#!/bin/bash
[ "${1:-}" = --version ] && { echo "made-up cc 1"; exit 0; }
[ "${1:-}" = -dumpmachine ] && { echo arm64-apple-darwin; exit 0; }
out= c=
prev=
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  [ "$prev" = -c ] && c=$a
  prev=$a
done
if [ -n "$c" ]; then
  echo "$c" >> "$LOG/runtime-compiles"
  cat "$c" > "$out"
else
  printf '%s\n' "$@" > "$out"
fi
EOF
cat > "$t/bin/zig" <<'EOF'
#!/bin/bash
# (zig cc / zig ar: the made-up cc and ar)
tool=$1; shift
exec "$(dirname "$0")/$tool" "$@"
EOF
cat > "$t/bin/ar" <<'EOF'
#!/bin/bash
lib=$2; shift 2
cat "$@" > "$lib"
EOF
chmod +x "$t/bin/zig" "$t/bin/moon" "$t/bin/getconf" "$t/bin/cc" "$t/bin/ar" "$t/root/libs/ui/scripts/mbc"

export PATH="$t/bin:$PATH" HOME="$t/home" MOON_HOME="$t/moon" SHELL_LIB="$t/shell.a" MBC_STORE="$t/store" LOG="$t/log"
unset MBUI_TOOLS MBC_JOBS STILLFAIL_NATIVE_ONE STILLFAIL_NATIVE_READERS STATION_READER_OPT RUNNER_ENVIRONMENT GITHUB_REF
run() { bash "$t/root/station/mb/build.sh" "${TARGET:-darwin-arm64}" "$t/out/$1" > "$t/log/build-$1.out" 2>&1; }
fresh() { rm -rf "$t/log"; mkdir -p "$t/log"; }
compiles() { [ -f "$t/log/runtime-compiles" ] && grep -c . "$t/log/runtime-compiles" || echo 0; }
jobs() { cat "$t/log/jobs" 2>/dev/null || echo "no compile"; }
# (a build that does not end in 20 s is waiting on a lock that is never let go)
bounded() {
  local p=$1 name=$2
  for _ in $(seq 1 200); do kill -0 "$p" 2>/dev/null || { wait "$p"; return $?; }; sleep 0.1; done
  kill "$p"; fail "$name: not ended in 20 s (a lock never let go?)"
}

# 1. mbc's jobs: every core for a build alone, shared by the readers side by side (2 at least; three where only
#    STILLFAIL_NATIVE_ONE says there are several: scripts/native.ts's three), MBC_JOBS over all.
fresh; CORES=16 run alone || fail "a build alone: $(cat "$t/log/build-alone.out")"
[ "$(jobs)" = 16 ] || fail "a build alone on 16 cores: mbc compile -j $(jobs), not 16"
fresh; TARGET=linux-x64 CORES=16 STILLFAIL_NATIVE_ONE=1 run third || fail "one of three: $(cat "$t/log/build-third.out")"
[ "$(jobs)" = 6 ] || fail "several parts side by side (STILLFAIL_NATIVE_ONE alone) on 16 cores: mbc compile -j $(jobs), not 6"
fresh; TARGET=linux-x64 CORES=12 STILLFAIL_NATIVE_ONE=1 run third12 || fail "one of three on 12: $(cat "$t/log/build-third12.out")"
[ "$(jobs)" = 4 ] || fail "several parts side by side (STILLFAIL_NATIVE_ONE alone) on 12 cores: mbc compile -j $(jobs), not 4"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 STILLFAIL_NATIVE_READERS=2 run two || fail "one of two: $(cat "$t/log/build-two.out")"
[ "$(jobs)" = 8 ] || fail "one of two readers side by side on 16 cores: mbc compile -j $(jobs), not 8"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 STILLFAIL_NATIVE_READERS=1 run onereader || fail "one reader: $(cat "$t/log/build-onereader.out")"
[ "$(jobs)" = 16 ] || fail "the one reader of several parts on 16 cores: mbc compile -j $(jobs), not 16"
fresh; TARGET=linux-x64 CORES=3 STILLFAIL_NATIVE_ONE=1 run few || fail "one of three on 3: $(cat "$t/log/build-few.out")"
[ "$(jobs)" = 2 ] || fail "several parts side by side (STILLFAIL_NATIVE_ONE alone) on 3 cores: mbc compile -j $(jobs), not 2"
fresh; CORES=3 STILLFAIL_NATIVE_ONE=1 run mac || fail "darwin-arm64 among several: $(cat "$t/log/build-mac.out")"
[ "$(jobs)" = 3 ] || fail "darwin-arm64, the Apple parts' one reader (STILLFAIL_NATIVE_ONE alone) on 3 cores: mbc compile -j $(jobs), not 3"
fresh; STATION_READER_OPT=-O0 run o0 || fail "STATION_READER_OPT=-O0: $(cat "$t/log/build-o0.out")"
grep -q -- ' -O0 ' "$t/log/cflags" || fail "STATION_READER_OPT=-O0: mbc's cflags $(cat "$t/log/cflags")"
fresh; run o2 || fail "-O2 by default: $(cat "$t/log/build-o2.out")"
grep -q -- ' -O2 ' "$t/log/cflags" || fail "-O2 by default: mbc's cflags $(cat "$t/log/cflags")"
fresh; RUNNER_ENVIRONMENT=github-hosted GITHUB_REF=refs/heads/x run hosted || fail "a branch on GitHub's runner: $(cat "$t/log/build-hosted.out")"
grep -q -- ' -O0 ' "$t/log/cflags" || fail "a branch on GitHub's runner: mbc's cflags $(cat "$t/log/cflags"), not -O0"
fresh; RUNNER_ENVIRONMENT=github-hosted GITHUB_REF=refs/heads/main run hostedmain || fail "main on GitHub's runner: $(cat "$t/log/build-hostedmain.out")"
grep -q -- ' -O2 ' "$t/log/cflags" || fail "main on GitHub's runner: mbc's cflags $(cat "$t/log/cflags"), not -O2"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 STILLFAIL_NATIVE_READERS=3 run three || fail "one of three: $(cat "$t/log/build-three.out")"
[ "$(jobs)" = 6 ] || fail "one of three readers side by side on 16 cores: mbc compile -j $(jobs), not 6"
fresh; CORES=4 STILLFAIL_NATIVE_READERS=3 run three4 || fail "one of three on 4: $(cat "$t/log/build-three4.out")"
[ "$(jobs)" = 2 ] || fail "one of three readers side by side on 4 cores: mbc compile -j $(jobs), not 2"
fresh; CORES=16 STILLFAIL_NATIVE_ONE=1 MBC_JOBS=5 run said || fail "MBC_JOBS: $(cat "$t/log/build-said.out")"
[ "$(jobs)" = 5 ] || fail "MBC_JOBS=5: mbc compile -j $(jobs), not 5"
for n in alone third said; do grep -q 'unit.o' "$t/out/$n" || fail "build $n: not linked with its units"; done

# 2. The runtime: compiled once, then taken from MBC_STORE; compiled again once one of its files or headers changed.
rm -rf "$t/store"; fresh
run first || fail "first build: $(cat "$t/log/build-first.out")"
[ "$(compiles)" = 2 ] || fail "first build: $(compiles) runtime files compiled, not 2"
grep -q "^$t/store/libruntime-darwin-arm64-" "$t/out/first" || fail "first build: not linked with the runtime kept in MBC_STORE"
fresh
run again || fail "second build: $(cat "$t/log/build-again.out")"
[ "$(compiles)" = 0 ] || fail "second build, nothing changed: $(compiles) runtime files compiled again, not 0"
grep -q "^$t/store/libruntime-darwin-arm64-" "$t/out/again" || fail "second build: not linked with the kept runtime"
echo 'int moonbit_x2;' > "$t/moon/lib/runtime/runtime.c"
fresh
run changed || fail "build after the runtime changed: $(cat "$t/log/build-changed.out")"
[ "$(compiles)" = 2 ] || fail "the runtime changed: $(compiles) runtime files compiled, not 2"
echo '#define MOONBIT 2' > "$t/moon/include/moonbit.h"
fresh
run header || fail "build after a header changed: $(cat "$t/log/build-header.out")"
[ "$(compiles)" = 2 ] || fail "a runtime header changed: $(compiles) runtime files compiled, not 2"

# 3. Adding or changing a sibling of moonbit.h changes mbc's include directory. Two moons with the same headers
#    (ci-1's runners, each its own _tool/moon-ci) share the include directory, cflags, and runtime.
moon_include() { sed -n 's/^-I"\([^"]*\)".*/\1/p' "$t/log/cflags"; }
inc_before=$(moon_include)
case "$inc_before" in
  "$MBC_STORE"/moon-include-*) ;;
  *) fail "expected a cached MoonBit include directory in mbc's cflags: $(cat "$t/log/cflags")" ;;
esac
printf '%s\n' 'int moonbit_unsafe_string_substring(void);' > "$t/moon/include/extra.h"
fresh; run added || fail "build after adding extra.h: $(cat "$t/log/build-added.out")"
inc_added=$(moon_include)
[ "$inc_added" != "$inc_before" ] || fail "adding extra.h reused $inc_before"
cmp -s "$t/moon/include/extra.h" "$inc_added/extra.h" || fail "extra.h missing or out of date in $inc_added"

printf '%s\n' 'int moonbit_unsafe_string_substring(int);' > "$t/moon/include/extra.h"
fresh; run home1 || fail "build after changing extra.h: $(cat "$t/log/build-home1.out")"
inc_changed=$(moon_include)
[ "$inc_changed" != "$inc_added" ] || fail "changing extra.h reused $inc_added"
cmp -s "$t/moon/include/extra.h" "$inc_changed/extra.h" || fail "extra.h missing or out of date in $inc_changed"

c1=$(cat "$t/log/cflags")
cp -R "$t/moon" "$t/moon2"
fresh; MOON_HOME="$t/moon2" run home2 || fail "MOON_HOME two: $(cat "$t/log/build-home2.out")"
c2=$(cat "$t/log/cflags")
[ "$c1" = "$c2" ] || fail "two moons with identical headers: mbc given different cflags ($c1 / $c2)"
case "$c1" in *"$t/moon"*) fail "mbc's cflags name a moon's own directory: $c1" ;; esac
[ "$(compiles)" = 0 ] || fail "the second moon, its runtime the same: $(compiles) runtime files compiled, not 0"

# 3b. A moon-include directory CI's cleanup (find -type f -mtime +3 -delete) left empty or short of a header: filled
#     in place, never with the copy moved inside it (main 45350580866: 177 units without moonbit.h); headers reused
#     get a fresh mtime so that cleanup spares them.
inc_now=$(moon_include)
rm -rf "$inc_now"; mkdir -p "$inc_now"
fresh; run emptyinc || fail "build over an empty moon-include directory: $(cat "$t/log/build-emptyinc.out")"
[ "$(moon_include)" = "$inc_now" ] || fail "empty moon-include: mbc given $(moon_include), not $inc_now"
[ -f "$inc_now/moonbit.h" ] || fail "empty moon-include: moonbit.h not put in $inc_now ($(ls -A "$inc_now"))"
cmp -s "$t/moon/include/extra.h" "$inc_now/extra.h" || fail "empty moon-include: extra.h not put in $inc_now"
ls -d "$inc_now"/*.tmp.* > /dev/null 2>&1 && fail "empty moon-include: a copy moved inside $inc_now ($(ls -A "$inc_now"))"
rm -f "$inc_now/extra.h"
fresh; run partialinc || fail "build over a moon-include directory short of extra.h: $(cat "$t/log/build-partialinc.out")"
cmp -s "$t/moon/include/extra.h" "$inc_now/extra.h" || fail "moon-include short of extra.h: not put back in $inc_now"
ls -d "$inc_now"/*.tmp.* > /dev/null 2>&1 && fail "moon-include short of extra.h: a copy moved inside $inc_now ($(ls -A "$inc_now"))"
touch -t 202001010000 "$inc_now/moonbit.h"
fresh; run oldinc || fail "build over old headers: $(cat "$t/log/build-oldinc.out")"
[ -z "$(find "$inc_now/moonbit.h" -mtime +3)" ] || fail "reused moonbit.h kept its 2020 mtime: CI's cleanup deletes it"

# 4. moon's lock left by a build gone (killed where no trap ran): taken over, not waited on.
sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir -p "$t/root/station/mb/_build/moon-gen.lock"; echo "$dead" > "$t/root/station/mb/_build/moon-gen.lock/pid"
fresh
run stale & p=$!; pids=("$p")
bounded "$p" "a build after one gone left moon's lock" || fail "a build after one gone left moon's lock: $(cat "$t/log/build-stale.out")"
pids=()
[ ! -e "$t/root/station/mb/_build/moon-gen.lock" ] || fail "moon's lock left after a build ended"

# 5. --harness: the tests' program from src/reader_harness, into stillfail-reader-harness-TARGET by default, its C
#    prepared and kept apart from the reader's (prepped-reader_harness.c), each taken as it was made thereafter.
rm -rf "$t/root/station/mb/_build"; fresh
bash "$t/root/station/mb/build.sh" --harness darwin-arm64 > "$t/log/build-harness.out" 2>&1 || fail "--harness: $(cat "$t/log/build-harness.out")"
[ -f "$t/root/station/mb/_build/stillfail-reader-harness-darwin-arm64" ] || fail "--harness: not built into _build/stillfail-reader-harness-darwin-arm64"
[ ! -e "$t/root/station/mb/_build/stillfail-reader-darwin-arm64" ] || fail "--harness: built the reader too"
[ "$(cat "$t/log/moon-builds")" = reader_harness ] || fail "--harness: moon built $(cat "$t/log/moon-builds"), not reader_harness"
grep -q 'reader_harness' "$t/log/c" || fail "--harness: mbc given $(cat "$t/log/c"), not the harness's C"
[ -f "$t/root/station/mb/_build/prepped-reader_harness.c" ] || fail "--harness: its prepared C not kept as prepped-reader_harness.c"
fresh; run plain || fail "the reader after the harness: $(cat "$t/log/build-plain.out")"
[ "$(cat "$t/log/moon-builds")" = reader ] || fail "the reader after the harness: moon built $(cat "$t/log/moon-builds"), not reader"
grep -q '/\* reader \*/' "$t/log/c" || fail "the reader after the harness: mbc given $(cat "$t/log/c"), not the reader's C"
fresh; bash "$t/root/station/mb/build.sh" --harness darwin-arm64 "$t/out/harness2" > "$t/log/build-harness2.out" 2>&1 || fail "--harness again: $(cat "$t/log/build-harness2.out")"
[ ! -e "$t/log/moon-builds" ] || fail "--harness again, nothing changed: moon built $(cat "$t/log/moon-builds") again"
grep -q 'reader_harness' "$t/log/c" || fail "--harness again: mbc given $(cat "$t/log/c"), not the harness's kept C"
grep -q 'unit.o' "$t/out/harness2" || fail "--harness into OUT: not linked there"

# 5b. Changing frozen station_main never invalidates reader's gen_key, and reader only compiles its own C stubs.
mkdir -p "$t/root/station/mb/src/station_main" "$t/root/station/mb/src/drive" "$t/root/station/mb/src/host"
echo 'int sm_stub;' > "$t/root/station/mb/src/station_main/sys.c"
echo 'int drv_stub;' > "$t/root/station/mb/src/drive/drive.c"
echo 'int host_stub;' > "$t/root/station/mb/src/host/host.c"
echo 'pub fn v() -> Int { 1 }' > "$t/root/station/mb/src/station_main/a.mbt"
fresh; run cache1 || fail "reader before station_main edit: $(cat "$t/log/build-cache1.out")"
grep -q 'host/host.c' "$t/log/extras" || fail "reader extras missing host/host.c: $(cat "$t/log/extras" 2>/dev/null)"
if grep -qE 'station_main/|drive/drive\.c' "$t/log/extras"; then
  fail "reader extras unexpectedly included frozen C stubs: $(cat "$t/log/extras")"
fi
echo 'pub fn v() -> Int { 2 }' > "$t/root/station/mb/src/station_main/a.mbt"
fresh; run cache2 || fail "reader after station_main edit: $(cat "$t/log/build-cache2.out")"
[ ! -e "$t/log/moon-builds" ] || fail "editing station_main invalidated reader gen_key (rebuilt $(cat "$t/log/moon-builds"))"
fresh; bash "$t/root/station/mb/build.sh" --harness darwin-arm64 "$t/out/harness3" > "$t/log/build-harness3.out" 2>&1 || fail "--harness after station_main edit: $(cat "$t/log/build-harness3.out")"
[ "$(cat "$t/log/moon-builds")" = reader_harness ] || fail "--harness did not rebuild after station_main edit"
grep -q 'station_main/sys.c' "$t/log/extras" || fail "--harness extras missing station_main/sys.c"
grep -q 'drive/drive.c' "$t/log/extras" || fail "--harness extras missing drive/drive.c"

# 5c. Changing libs/ui/tools/mbc/csplit.mbt or libs/ui/tools/moon.{mod,work} invalidates both reader and harness gen_key.
mkdir -p "$t/root/libs/ui/tools/mbc"
echo '// csplit v1' > "$t/root/libs/ui/tools/mbc/csplit.mbt"
echo '{"name":"ui/tools"}' > "$t/root/libs/ui/tools/moon.mod"
echo 'version = 1' > "$t/root/libs/ui/tools/moon.work"
fresh; run mbc1 || fail "reader with mbc v1: $(cat "$t/log/build-mbc1.out")"
[ "$(cat "$t/log/moon-builds")" = reader ] || fail "reader did not rebuild when libs/ui/tools/mbc/csplit.mbt appeared"
fresh; bash "$t/root/station/mb/build.sh" --harness darwin-arm64 "$t/out/harness-mbc1" > "$t/log/build-hmbc1.out" 2>&1 || fail "harness with mbc v1: $(cat "$t/log/build-hmbc1.out")"
[ "$(cat "$t/log/moon-builds")" = reader_harness ] || fail "harness did not rebuild when libs/ui/tools/mbc/csplit.mbt appeared"
echo '// csplit v2' > "$t/root/libs/ui/tools/mbc/csplit.mbt"
fresh; run mbc2 || fail "reader with mbc v2: $(cat "$t/log/build-mbc2.out")"
[ "$(cat "$t/log/moon-builds")" = reader ] || fail "editing libs/ui/tools/mbc/csplit.mbt did not invalidate reader gen_key"
fresh; bash "$t/root/station/mb/build.sh" --harness darwin-arm64 "$t/out/harness-mbc2" > "$t/log/build-hmbc2.out" 2>&1 || fail "harness with mbc v2: $(cat "$t/log/build-hmbc2.out")"
[ "$(cat "$t/log/moon-builds")" = reader_harness ] || fail "editing libs/ui/tools/mbc/csplit.mbt did not invalidate harness gen_key"
echo '{"name":"ui/tools","version":"0.2"}' > "$t/root/libs/ui/tools/moon.mod"
fresh; run mbc3 || fail "reader with tools moon.mod v2: $(cat "$t/log/build-mbc3.out")"
[ "$(cat "$t/log/moon-builds")" = reader ] || fail "editing libs/ui/tools/moon.mod did not invalidate reader gen_key"
fresh; bash "$t/root/station/mb/build.sh" --harness darwin-arm64 "$t/out/harness-mbc3" > "$t/log/build-hmbc3.out" 2>&1 || fail "harness with tools moon.mod v2: $(cat "$t/log/build-hmbc3.out")"
[ "$(cat "$t/log/moon-builds")" = reader_harness ] || fail "editing libs/ui/tools/moon.mod did not invalidate harness gen_key"
echo 'version = 2' > "$t/root/libs/ui/tools/moon.work"
fresh; run mbc4 || fail "reader with tools moon.work v2: $(cat "$t/log/build-mbc4.out")"
[ "$(cat "$t/log/moon-builds")" = reader ] || fail "editing libs/ui/tools/moon.work did not invalidate reader gen_key"
fresh; bash "$t/root/station/mb/build.sh" --harness darwin-arm64 "$t/out/harness-mbc4" > "$t/log/build-hmbc4.out" 2>&1 || fail "harness with tools moon.work v2: $(cat "$t/log/build-hmbc4.out")"
[ "$(cat "$t/log/moon-builds")" = reader_harness ] || fail "editing libs/ui/tools/moon.work did not invalidate harness gen_key"

# 6. ~/stillfail-ci/reader-mbc-prepped self-pruning: stale locks/tmps (>30m), old prepared C (>180m), and cap at newest 16.
prepped_ci="$t/ci-home/stillfail-ci/reader-mbc-prepped"
mkdir -p "$prepped_ci"
mkdir -p "$prepped_ci/gen-stale.lock" "$prepped_ci/gen-fresh.lock"
touch -t 202001010000 "$prepped_ci/gen-stale.lock"
: > "$prepped_ci/prepped-stale.c.tmp.123"
touch -t 202001010000 "$prepped_ci/prepped-stale.c.tmp.123"
: > "$prepped_ci/prepped-old.c"
touch -t 202001010000 "$prepped_ci/prepped-old.c"
node -e '
  const fs = require("node:fs");
  const path = require("node:path");
  const dir = process.argv[1];
  const now = Date.now() / 1000;
  for (let i = 1; i <= 20; i++) {
    const p = path.join(dir, `prepped-recent-${String(i).padStart(2, "0")}.c`);
    fs.writeFileSync(p, `/* ${i} */\n`);
    const ts = now - (25 - i) * 60;
    fs.utimesSync(p, ts, ts);
  }
' "$prepped_ci"
fresh; HOME="$t/ci-home" run preppedprune || fail "prepped prune build: $(cat "$t/log/build-preppedprune.out")"
[ ! -e "$prepped_ci/gen-stale.lock" ] || fail "prepped prune: stale lock not removed"
[ -d "$prepped_ci/gen-fresh.lock" ] || fail "prepped prune: fresh lock removed"
[ ! -e "$prepped_ci/prepped-stale.c.tmp.123" ] || fail "prepped prune: stale tmp file not removed"
[ ! -e "$prepped_ci/prepped-old.c" ] || fail "prepped prune: expired prepped-old.c not removed"
kept_prepped=$(ls -1 "$prepped_ci"/prepped-*.c 2>/dev/null | wc -l | tr -d ' ')
[ "$kept_prepped" = 16 ] || fail "prepped prune: expected 16 prepped-*.c files, got $kept_prepped"
[ ! -e "$prepped_ci/prepped-recent-01.c" ] || fail "prepped prune: oldest recent file not pruned"
[ ! -e "$prepped_ci/prepped-recent-05.c" ] || fail "prepped prune: 5th oldest recent file not pruned"
[ -f "$prepped_ci/prepped-recent-20.c" ] || fail "prepped prune: newest recent file removed"

echo "station-mb-build-test: mbc's jobs by the builds side by side, the runtime kept until it changes, a gone build's lock taken over, --harness's program apart from the reader, reader-mbc-prepped pruned, moon-include emptied by CI's cleanup filled again"
