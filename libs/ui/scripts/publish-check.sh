#!/bin/sh
# Standalone release readiness preflight for ui.monoid (mbui).
# Checks:
#   1. detlint (including app-word = 0)
#   2. Required release metadata & docs exist and are non-empty
#   3. No outside-repo '../../' path coupling in src/ or tools/ (excluding unit test files)
#   4. Module size summary and recommended publish-exclude directories report
set -eu

D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$D/.." && pwd)
FAIL=0

echo "=== [1/4] detlint (app-word & determinism gates)"
if "$D/detlint"; then
  echo "OK: detlint passed (app-word = 0)"
else
  echo "FAIL: detlint failed" >&2
  FAIL=1
fi

echo ""
echo "=== [2/4] required release files"
for rel in LICENSE THIRD_PARTY_NOTICES.md README.md docs/PACKAGING.md docs/RELEASING.md; do
  if [ -s "$ROOT/$rel" ]; then
    echo "OK: $rel"
  else
    echo "FAIL: missing or empty $rel" >&2
    FAIL=1
  fi
done

echo ""
echo "=== [3/4] outside-repo path coupling scan (src/ & tools/)"
COUPLED=$(
  find "$ROOT/src" "$ROOT/tools" -type f \
    ! -name '*_test.mbt' \
    ! -name '*_wbtest.mbt' \
    ! -path '*/_build/*' \
    -exec grep -n '\.\./\.\./' {} + 2>/dev/null || true
)
if [ -n "$COUPLED" ]; then
  echo "FAIL: found outside-repo '../../' references in non-test sources:" >&2
  printf '%s\n' "$COUPLED" >&2
  FAIL=1
else
  echo "OK: no outside-repo '../../' references in src/ or tools/ (excluding tests)"
fi

echo ""
echo "=== [4/4] module size & recommended publish excludes"
TOTAL_KB=$(du -sk "$ROOT" | awk '{print $1}')
TOTAL_H=$(du -sh "$ROOT" | awk '{print $1}')
echo "Total module size: $TOTAL_H (${TOTAL_KB} KB)"
EXCL_KB=0
for excl in goldens bench src/skiatest/images out _build tools/_build; do
  if [ -e "$ROOT/$excl" ]; then
    SZ_KB=$(du -sk "$ROOT/$excl" | awk '{print $1}')
    SZ_H=$(du -sh "$ROOT/$excl" | awk '{print $1}')
    EXCL_KB=$((EXCL_KB + SZ_KB))
    printf '  exclude %-22s %s (%s KB)\n' "$excl/" "$SZ_H" "$SZ_KB"
  else
    printf '  exclude %-22s (absent)\n' "$excl/"
  fi
done
EST_KB=$((TOTAL_KB - EXCL_KB))
if [ "$EST_KB" -lt 0 ]; then EST_KB=0; fi
echo "Estimated publishable size (excluding above): ~${EST_KB} KB"

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "publish-check: FAILED" >&2
  exit 1
fi
echo "publish-check: ALL CHECKS PASSED"
