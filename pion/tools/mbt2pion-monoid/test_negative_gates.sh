#!/bin/sh
# Wave M1.1 Negative Mutation CI Gates (plan_wave_m1_v3.md §6 #12c)
# Runs positive controls FIRST (so broken tools / missing env / bad sentinel never
# masquerade as a passing negative gate), then executes all 4 negative mutations
# with REAL Stage A.5 probes (probes always enabled) and asserts exact failure
# codes & zero `--out` pollution:
#   (a) Mutate `api_map.json`:
#       (a1) delete a string-offset `unit` annotation -> publish exits non-zero with
#            `MBT2PION_UNTAGGED_UNIT` & legal `--out` sentinel untouched
#       (a2) tamper a signature ACTUALLY CALLED by the source -> `--check` exits non-zero
#            with generated code mismatch
#   (b) Mutate an upstream function body anchored by a declaration-granularity overlay
#       (preserving line shape) -> first prove valid overlay succeeds (rc=0), then mutated
#       source fails with `MBT2PION_OVERLAY_STALE_SOURCE` & `--out` sentinel untouched
#   (c) Toggle platform branch (`native` vs `wasm32`) on real `moon.pkg` target-split files ->
#       first verify stripped non-comment code differs between targets, then `--check` fails
#   (d) Differential Oracle (`oracle.py`):
#       positive control baseline MUST exit 0 first, then:
#       (d1) drop 1 assertion -> strict rc=1 (never rc=2 SETUP FAILED) + `assertions != expected`
#       (d2) mutate `film_facts_guard` + tautologize check (WITHOUT touching trace) -> strict rc=1 + `trace mismatch vs moon`
#       (d3) mutate real transpiled `numbers.pion` (`dmin` `<` -> `>`) -> strict rc=1!
#
# Environment:
#   MBT2PION_BIN   Path to compiled `mbt2pion` binary (or MBT2PION_CLI_DIR)
#   MBT_COMPAT_DIR Path to `mbt_compat` package directory
#   INVAR_DIR      Optional path to pinned `invar` checkout

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export PATH="$HOME/.pion/bin:$HOME/.moon/bin:$PATH"
if [ -d /opt/homebrew/bin ]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
PIONC="${PIONC:-$(command -v pionc)}"
MOON="${MOON:-$(command -v moon)}"

if [ -z "${MBT_COMPAT_DIR:-}" ] || [ ! -d "$MBT_COMPAT_DIR" ]; then
  echo "ERROR: set MBT_COMPAT_DIR to the mbt_compat package directory" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/m11-neg-gates.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -z "${MBT2PION_BIN:-}" ]; then
  if [ -n "${MBT2PION_CLI_DIR:-}" ] && [ -d "$MBT2PION_CLI_DIR" ]; then
    MBT2PION_BIN="$WORK/mbt2pion"
    "$PIONC" build "$MBT2PION_CLI_DIR" -o "$MBT2PION_BIN"
  else
    echo "ERROR: set MBT2PION_BIN (or MBT2PION_CLI_DIR)" >&2
    exit 2
  fi
fi

export MBT2PION_BIN

INVAR_REV="$(grep 'AFK-surf/invar\.git' "$REPO_ROOT/pion/ui/pion.toml" | head -n 1 | sed -n 's/.*rev *= *"\([0-9a-f]\{40\}\)".*/\1/p')"
if [ -z "${INVAR_DIR:-}" ]; then
  if [ ! -d "$HOME/.cache/pion/git/checkouts/$INVAR_REV" ]; then
    "$PIONC" fetch "$REPO_ROOT/pion/ui" >/dev/null
  fi
  INVAR_DIR="$HOME/.cache/pion/git/checkouts/$INVAR_REV"
fi
CONTROLS_DIR="$REPO_ROOT/libs/ui/src/controls"

# Valid Pion sentinel file (must compile cleanly so failures are never caused by invalid sentinel syntax)
SENTINEL_DIR="$WORK/publish_sentinel"
mkdir -p "$SENTINEL_DIR"
printf 'pub fn sentinel_keep() -> Int {\n  1\n}\n' > "$SENTINEL_DIR/sentinel.pion"
SENTINEL_SHA="$(shasum -a 256 "$SENTINEL_DIR/sentinel.pion" | awk '{print $1}')"

verify_sentinel_untouched() {
  NOW_COUNT="$(ls -1 "$SENTINEL_DIR" | wc -l | tr -d ' ')"
  NOW_SHA="$(shasum -a 256 "$SENTINEL_DIR/sentinel.pion" | awk '{print $1}')"
  if [ "$NOW_COUNT" -ne 1 ] || [ "$NOW_SHA" != "$SENTINEL_SHA" ]; then
    echo "FAIL: --mode publish polluted --out ($1): count=$NOW_COUNT sha=$NOW_SHA" >&2
    exit 1
  fi
}

# =============================================================================
# Positive control 1: legal sentinel + real api_map.json publish & --check MUST pass (rc=0)
# =============================================================================
BASE_SRC="$WORK/base_src"
BASE_OUT="$WORK/base_out"
mkdir -p "$BASE_SRC" "$BASE_OUT"
cp "$SCRIPT_DIR/pilot/mbt_transpile_src/pilot_core.mbt" "$BASE_SRC/pilot_core.mbt"
cp "$CONTROLS_DIR/numbers.mbt" "$BASE_SRC/numbers.mbt"
cp "$CONTROLS_DIR/marked.mbt" "$BASE_SRC/marked.mbt"
cp "$CONTROLS_DIR/tokens_data.mbt" "$BASE_SRC/tokens_data.mbt"

SENTINEL_POS="$WORK/sentinel_pos"
cp -R "$SENTINEL_DIR" "$SENTINEL_POS"
sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$SENTINEL_POS" \
  --target native \
  --mode publish \
  --mbt-compat "$MBT_COMPAT_DIR"

sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$BASE_OUT" \
  --target native \
  --mode publish \
  --mbt-compat "$MBT_COMPAT_DIR"

sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$BASE_OUT" \
  --target native \
  --check \
  --mbt-compat "$MBT_COMPAT_DIR"
echo "[neg-gate] positive control 1 OK (sentinel publish + baseline --check rc=0)"

# =============================================================================
# (a) Mutate api_map.json:
#     (a1) drop unit tag on offset param -> exact MBT2PION_UNTAGGED_UNIT & sentinel untouched
#     (a2) tamper target_name of an ACTUALLY CALLED symbol -> --check fails on code diff
# =============================================================================
BAD_UNIT_MAP="$WORK/bad_unit_api_map.json"
TAMPER_SIG_MAP="$WORK/tamper_sig_api_map.json"
A2_SRC="$WORK/a2_src"
A2_OUT="$WORK/a2_out"
mkdir -p "$A2_SRC" "$A2_OUT"
cat > "$A2_SRC/call_mapped.mbt" << 'EOF'
pub fn probe_space() -> Double {
  @dmath.floor(3.7)
}
EOF

sh "$SCRIPT_DIR/regen.sh" \
  --src "$A2_SRC" \
  --out "$A2_OUT" \
  --target native \
  --mode publish \
  --mbt-compat "$MBT_COMPAT_DIR" \
  --dep "dmath=$INVAR_DIR/packages/dmath"

python3 - "$SCRIPT_DIR/api_map.json" "$BAD_UNIT_MAP" "$TAMPER_SIG_MAP" << 'PY'
import json, sys

with open(sys.argv[1]) as f:
    doc = json.load(f)

# (a1) Add a symbol with an offset-like Int param missing `unit`
doc_unit = json.loads(json.dumps(doc))
doc_unit["symbols"].append({
    "src_pkg": "text",
    "src_name": "mutated_slice_probe",
    "kind": "fn",
    "params": [{"name": "byte_offset", "ty": "Int"}]
})
with open(sys.argv[2], "w") as f:
    json.dump(doc_unit, f, indent=2)

# (a2) Tamper the actually-called `@dmath.floor` symbol in api_map.json
doc_sig = json.loads(json.dumps(doc))
found = False
for s in doc_sig["symbols"]:
    if s.get("src_pkg") == "dmath" and s.get("src_name") == "floor":
        s["target_name"] = "TAMPERED_FLOOR_SIG"
        found = True
        break
if not found:
    doc_sig["symbols"].append({
        "src_pkg": "dmath",
        "src_name": "floor",
        "kind": "fn",
        "target_pkg": "dmath",
        "target_name": "TAMPERED_FLOOR_SIG",
        "params": [{"name": "x", "ty": "Double", "unit": "none"}],
        "ret_ty": "Double",
        "ret_unit": "none",
        "ret_map_boundary": "none",
    })
with open(sys.argv[3], "w") as f:
    json.dump(doc_sig, f, indent=2)
PY

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$BASE_SRC" \
  --out "$SENTINEL_DIR" \
  --target native \
  --mode publish \
  --api-map "$BAD_UNIT_MAP" \
  --mbt-compat "$MBT_COMPAT_DIR" \
  --report "$WORK/neg_a1_report.json" >"$WORK/neg_a1.log" 2>&1; then
  echo "FAIL (a1): missing unit annotation in api_map.json was NOT rejected!" >&2
  cat "$WORK/neg_a1.log" >&2
  exit 1
fi
grep -Eq '"code"[[:space:]]*:[[:space:]]*"MBT2PION_UNTAGGED_UNIT"' "$WORK/neg_a1_report.json" || {
  echo "FAIL (a1): expected MBT2PION_UNTAGGED_UNIT in neg_a1_report.json!" >&2
  cat "$WORK/neg_a1_report.json" >&2
  exit 1
}
verify_sentinel_untouched "gate (a1)"

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$A2_SRC" \
  --out "$A2_OUT" \
  --target native \
  --api-map "$TAMPER_SIG_MAP" \
  --check \
  --mbt-compat "$MBT_COMPAT_DIR" \
  --dep "dmath=$INVAR_DIR/packages/dmath" >"$WORK/neg_a2.log" 2>&1; then
  echo "FAIL (a2): tampered api_map.json signature on called symbol was NOT rejected by --check!" >&2
  cat "$WORK/neg_a2.log" >&2
  exit 1
fi
grep -q "mismatch in call_mapped.pion" "$WORK/neg_a2.log" || {
  echo "FAIL (a2): expected mismatch in call_mapped.pion in neg_a2.log!" >&2
  cat "$WORK/neg_a2.log" >&2
  exit 1
}
echo "[neg-gate] PASS (a): MBT2PION_UNTAGGED_UNIT + tampered called symbol both rejected (--out untouched)"

# =============================================================================
# (b) Mutate upstream function body anchored by declaration-granularity overlay
# =============================================================================
OV_SRC="$WORK/ov_src"
OV_DIR="$WORK/ov_dir"
OV_OUT_OK="$WORK/ov_out_ok"
mkdir -p "$OV_SRC" "$OV_DIR" "$OV_OUT_OK"
cp "$SCRIPT_DIR/pilot/mbt_transpile_src/pilot_core.mbt" "$OV_SRC/pilot_core.mbt"

cat > "$OV_DIR/pilot_guard.json" << 'EOF'
{
  "id": "ov-film-facts-guard",
  "source_file": "pilot_core.mbt",
  "decl_identity": "fn:film_facts_guard",
  "target": "native",
  "normalized_source_cst_hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "pre_overlay_generated_hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "replacement": "pub fn film_facts_guard(w : Double, h : Double) -> String {\n  if !(w > 0.0 && h > 0.0) { \"\" } else { \"ok\" }\n}",
  "reason": "negative-gate-overlay-anchor-test",
  "behavior_test": "pilot/run_pilot.sh::guard_init_order",
  "upstream_issue_or_removal_condition": "remove after Wave M1.2"
}
EOF

sh "$SCRIPT_DIR/regen.sh" --src "$OV_SRC" --out "$WORK/ov_probe1" --target native --mode audit \
  --overlay-dir "$OV_DIR" --report "$WORK/ov_probe1.json" --mbt-compat "$MBT_COMPAT_DIR" >/dev/null 2>&1 || true
SRC_HASH="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
for x in d.get("diagnostics", []):
    if x.get("code") == "MBT2PION_OVERLAY_STALE_SOURCE":
        m = re.search(r"got ([0-9a-f]+)", x.get("message", ""))
        if m:
            print(m.group(1))
            sys.exit(0)
sys.exit(1)
' "$WORK/ov_probe1.json")"

python3 - "$OV_DIR/pilot_guard.json" "$SRC_HASH" << 'PY'
import json, sys
p, h = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["normalized_source_cst_hash"] = h
json.dump(d, open(p, "w"), indent=2)
PY

sh "$SCRIPT_DIR/regen.sh" --src "$OV_SRC" --out "$WORK/ov_probe2" --target native --mode audit \
  --overlay-dir "$OV_DIR" --report "$WORK/ov_probe2.json" --mbt-compat "$MBT_COMPAT_DIR" >/dev/null 2>&1 || true
GEN_HASH="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
for x in d.get("diagnostics", []):
    if x.get("code") == "MBT2PION_OVERLAY_STALE_GEN":
        m = re.search(r"got ([0-9a-f]+)", x.get("message", ""))
        if m:
            print(m.group(1))
            sys.exit(0)
sys.exit(1)
' "$WORK/ov_probe2.json")"

python3 - "$OV_DIR/pilot_guard.json" "$GEN_HASH" << 'PY'
import json, sys
p, h = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["pre_overlay_generated_hash"] = h
json.dump(d, open(p, "w"), indent=2)
PY

# Positive overlay control: valid double-hash MUST succeed (rc=0)
sh "$SCRIPT_DIR/regen.sh" --src "$OV_SRC" --out "$OV_OUT_OK" --target native --mode publish \
  --overlay-dir "$OV_DIR" --mbt-compat "$MBT_COMPAT_DIR"

# Mutate upstream function body semantics while keeping identical line shape (`>` -> `>=`)
python3 - "$OV_SRC/pilot_core.mbt" << 'PY'
import sys
p = sys.argv[1]
txt = open(p).read()
assert 'guard w > 0.0 && h > 0.0 else { "" }' in txt
open(p, "w").write(txt.replace('guard w > 0.0 && h > 0.0 else { "" }', 'guard w >= 0.0 && h >= 0.0 else { "" }', 1))
PY

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$OV_SRC" \
  --out "$SENTINEL_DIR" \
  --target native \
  --mode publish \
  --overlay-dir "$OV_DIR" \
  --report "$WORK/ov_mut_report.json" \
  --mbt-compat "$MBT_COMPAT_DIR" >"$WORK/neg_b.log" 2>&1; then
  echo "FAIL (b): mutated upstream function under overlay was NOT rejected!" >&2
  cat "$WORK/neg_b.log" >&2
  exit 1
fi
grep -q "MBT2PION_OVERLAY_STALE_SOURCE" "$WORK/ov_mut_report.json" || {
  echo "FAIL (b): expected MBT2PION_OVERLAY_STALE_SOURCE diagnostic!" >&2
  cat "$WORK/ov_mut_report.json" >&2
  exit 1
}
verify_sentinel_untouched "gate (b)"
echo "[neg-gate] PASS (b): overlay valid hit rc=0 + mutated body rejected (MBT2PION_OVERLAY_STALE_SOURCE, --out untouched)"

# =============================================================================
# (c) Toggle platform branch (`native` vs `wasm32`) with REAL code-body diff
# =============================================================================
PLAT_SRC="$WORK/plat_src"
PLAT_NAT="$WORK/plat_nat"
PLAT_WASM="$WORK/plat_wasm"
mkdir -p "$PLAT_SRC" "$PLAT_NAT" "$PLAT_WASM"
cat > "$PLAT_SRC/moon.pkg" << 'EOF'
options(
  targets: {
    "plat_native.mbt": [ "native" ],
    "plat_wasm.mbt": [ "wasm-gc" ],
  },
)
EOF
cat > "$PLAT_SRC/plat_native.mbt" << 'EOF'
pub fn platform_id() -> String {
  "native-host"
}
EOF
cat > "$PLAT_SRC/plat_wasm.mbt" << 'EOF'
pub fn platform_id() -> String {
  "wasm-host"
}
EOF

sh "$SCRIPT_DIR/regen.sh" --src "$PLAT_SRC" --out "$PLAT_NAT" --target native --mode publish --mbt-compat "$MBT_COMPAT_DIR"
sh "$SCRIPT_DIR/regen.sh" --src "$PLAT_SRC" --out "$PLAT_WASM" --target wasm32 --mode publish --mbt-compat "$MBT_COMPAT_DIR"

# Assert stripped non-comment code differs between native and wasm32 (not merely header comments!)
NAT_CODE="$(cat "$PLAT_NAT"/*.pion | grep -v '^//')"
WASM_CODE="$(cat "$PLAT_WASM"/*.pion | grep -v '^//')"
if [ "$NAT_CODE" = "$WASM_CODE" ]; then
  echo "FAIL (c): native and wasm32 produced identical non-comment code!" >&2
  exit 1
fi

if sh "$SCRIPT_DIR/regen.sh" \
  --src "$PLAT_SRC" \
  --out "$PLAT_NAT" \
  --target wasm32 \
  --check \
  --mbt-compat "$MBT_COMPAT_DIR" >"$WORK/neg_c.log" 2>&1; then
  echo "FAIL (c): platform branch toggle (native vs wasm32) was NOT rejected by --check!" >&2
  cat "$WORK/neg_c.log" >&2
  exit 1
fi
echo "[neg-gate] PASS (c): platform branch toggle (native vs wasm32) verified real code diff & rejected by --check"

# =============================================================================
# (d) Differential Oracle: Positive baseline MUST exit 0, then (d1)/(d2)/(d3) MUST exit 1!
# =============================================================================
make_pilot_ws() {
  MUT_WS="$1"
  mkdir -p "$MUT_WS/pilot/src"
  cp "$BASE_OUT"/*.pion "$MUT_WS/pilot/src/"
  cp "$SCRIPT_DIR/pilot/pion_pilot/src/main.pion" "$MUT_WS/pilot/src/main.pion"
  cat > "$MUT_WS/pion.toml" << EOF
[workspace]
members = ["pilot"]

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
mbt_compat = { path = "$MBT_COMPAT_DIR" }
sf = { path = "$REPO_ROOT/pion/ui/packages/sf" }
signals = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/signals" }
view = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/view" }
ui = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/ui" }
zip = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/zip" }
pixels = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/pixels" }
paint = { git = "https://github.com/AFK-surf/invar.git", rev = "$INVAR_REV", subdir = "packages/paint" }
EOF
  cat > "$MUT_WS/pilot/pion.toml" << EOF
[package]
name = "m11_neg_pilot"
version = "0.1.0"

[dependencies]
mbt_compat = { workspace = true }
sf = { workspace = true }
signals = { workspace = true }
view = { workspace = true }
ui = { workspace = true }
EOF
}

run_oracle_cmd() {
  PION_DIR="$1"
  LOG_FILE="$2"
  set +e
  python3 "$SCRIPT_DIR/pilot/oracle.py" \
    --moon-dir "$SCRIPT_DIR/pilot/moon_pilot" \
    --moon-extra-src "$CONTROLS_DIR/numbers.mbt" \
    --moon-extra-src "$CONTROLS_DIR/marked.mbt" \
    --moon-extra-src "$CONTROLS_DIR/tokens_data.mbt" \
    --moon-extra-src "$SCRIPT_DIR/pilot/mbt_transpile_src/pilot_core.mbt" \
    --pion-dir "$PION_DIR" \
    --moon-bin "$MOON" \
    --pionc-bin "$PIONC" \
    --no-bench >"$LOG_FILE" 2>&1
  ORACLE_RC=$?
  set -e
}

# Positive Oracle control: unmodified baseline MUST exit 0 (catches MOON=/usr/bin/false immediately!)
POS_ORACLE="$WORK/pos_oracle"
make_pilot_ws "$POS_ORACLE"
run_oracle_cmd "$POS_ORACLE/pilot" "$WORK/pos_oracle.log"
if [ "$ORACLE_RC" -ne 0 ]; then
  echo "FAIL (oracle positive control): unmodified baseline exited $ORACLE_RC (expected 0)!" >&2
  cat "$WORK/pos_oracle.log" >&2
  exit 1
fi
echo "[neg-gate] positive control 2 OK (unmodified differential oracle rc=0)"

# (d1) Drop one assertion from `signal_by` -> strict rc=1 + `assertions != expected`
MUT_D1="$WORK/mut_d1"
make_pilot_ws "$MUT_D1"
python3 - "$MUT_D1/pilot/src/main.pion" << 'PY'
import sys
p = sys.argv[1]
txt = open(p).read()
needle = '  check(world, "sig.one_wake_past_tol", wakes.v == 1)\n'
assert needle in txt
open(p, "w").write(txt.replace(needle, '', 1))
PY
run_oracle_cmd "$MUT_D1/pilot" "$WORK/neg_d1.log"
if [ "$ORACLE_RC" -ne 1 ] || grep -q "SETUP FAILED" "$WORK/neg_d1.log" || ! grep -q "assertions != expected" "$WORK/neg_d1.log"; then
  echo "FAIL (d1): expected strict rc=1 without SETUP FAILED and with 'assertions != expected' (got rc=$ORACLE_RC)!" >&2
  cat "$WORK/neg_d1.log" >&2
  exit 1
fi

# (d2) Mutate transpiled `film_facts_guard` implementation + tautologize check WITHOUT editing any trace(...)
MUT_D2="$WORK/mut_d2"
make_pilot_ws "$MUT_D2"
python3 - "$MUT_D2/pilot/src/pilot_core.pion" "$MUT_D2/pilot/src/main.pion" << 'PY'
import sys
pc_p, main_p = sys.argv[1], sys.argv[2]
pc = open(pc_p).read()
assert '""' in pc
open(pc_p, "w").write(pc.replace('""', '"wrong"', 1))
mp = open(main_p).read()
needle = '  check(world, "guard.false_branch", film_facts_guard(0.0, 10.0) == "")'
assert needle in mp
open(main_p, "w").write(mp.replace(needle, '  check(world, "guard.false_branch", true)', 1))
PY
run_oracle_cmd "$MUT_D2/pilot" "$WORK/neg_d2.log"
if [ "$ORACLE_RC" -ne 1 ] || grep -q "SETUP FAILED" "$WORK/neg_d2.log" || ! grep -q "trace mismatch vs moon" "$WORK/neg_d2.log"; then
  echo "FAIL (d2): expected strict rc=1 without SETUP FAILED and with 'trace mismatch vs moon' (got rc=$ORACLE_RC)!" >&2
  cat "$WORK/neg_d2.log" >&2
  exit 1
fi

# (d3) Mutate transpiled real production `numbers.pion` (`dmin` `<` -> `>`) -> strict rc=1
MUT_D3="$WORK/mut_d3"
make_pilot_ws "$MUT_D3"
python3 - "$MUT_D3/pilot/src/numbers.pion" << 'PY'
import sys
p = sys.argv[1]
txt = open(p).read()
assert 'if a < b' in txt
open(p, "w").write(txt.replace('if a < b', 'if a > b', 1))
PY
run_oracle_cmd "$MUT_D3/pilot" "$WORK/neg_d3.log"
if [ "$ORACLE_RC" -ne 1 ] || grep -q "SETUP FAILED" "$WORK/neg_d3.log"; then
  echo "FAIL (d3): expected strict rc=1 without SETUP FAILED for mutated real numbers.pion (got rc=$ORACLE_RC)!" >&2
  cat "$WORK/neg_d3.log" >&2
  exit 1
fi
echo "[neg-gate] PASS (d): (d1) dropped assert, (d2) mutated guard+tautology, (d3) mutated real numbers.pion all strict rc=1"

# =============================================================================
# (e) Single-invar-pin URL-normalization negative gates (no .git / case / ssh / git@)
# =============================================================================
for url_case in \
  "no_dot_git|https://github.com/AFK-surf/invar" \
  "lowercase|https://github.com/afk-surf/invar.git" \
  "ssh_scheme|ssh://git@github.com/AFK-surf/invar" \
  "scp_ssh|git@github.com:AFK-surf/invar"; do
  CASE_ID="${url_case%%|*}"
  ALT_URL="${url_case#*|}"
  PIN_TMP="$WORK/pin_url_$CASE_ID"
  mkdir -p "$PIN_TMP/pion/ui/packages/sf" "$PIN_TMP/pion/app" "$PIN_TMP/pion/tools/mbt2pion-monoid"
  cp "$REPO_ROOT/pion/ui/pion.toml" "$PIN_TMP/pion/ui/pion.toml"
  cp "$REPO_ROOT/pion/ui/pion.lock" "$PIN_TMP/pion/ui/pion.lock"
  cp "$REPO_ROOT/pion/app/pion.toml" "$PIN_TMP/pion/app/pion.toml"
  cp "$REPO_ROOT/pion/app/pion.lock" "$PIN_TMP/pion/app/pion.lock"
  cp "$REPO_ROOT/pion/tools/mbt2pion-monoid/manifest.toml" "$PIN_TMP/pion/tools/mbt2pion-monoid/manifest.toml"
  cp "$SCRIPT_DIR/check_single_invar_pin.sh" "$PIN_TMP/pion/tools/mbt2pion-monoid/check_single_invar_pin.sh"
  cat > "$PIN_TMP/pion/ui/packages/sf/pion.toml" << EOF
[package]
name = "sf"
version = "0.1.0"

[dependencies]
textdiff = { git = "$ALT_URL", rev = "ff2ed93000000000000000000000000000000000", subdir = "packages/textdiff" }
EOF
  if sh "$PIN_TMP/pion/tools/mbt2pion-monoid/check_single_invar_pin.sh" >"$WORK/neg_pin_${CASE_ID}.log" 2>&1; then
    echo "FAIL (pin-url:$CASE_ID): invar URL variant '$ALT_URL' with second SHA bypassed check_single_invar_pin.sh!" >&2
    cat "$WORK/neg_pin_${CASE_ID}.log" >&2
    exit 1
  fi
done
echo "[neg-gate] PASS (e): check_single_invar_pin.sh rejected all 4 invar URL variants (no .git, lowercase, ssh://, git@)"

echo "=== ALL 5 NEGATIVE MUTATION CI GATES + 2 POSITIVE CONTROLS PASSED ==="
