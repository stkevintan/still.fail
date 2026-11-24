#!/bin/bash
# Comma's parts' module on its own (mbui beside it, ../ui): the determinism lint with this module's detlint.json, its
# packages type-checked on native, then its tests (CI's check-comma-ui; here as well, they take seconds).
D="$(cd "$(dirname "$0")" && pwd)"
A=$(cd "$D/.." && pwd)
MBUI_DIR=$(cd "$A/../ui" && pwd)
. "$MBUI_DIR/scripts/env.sh"
"$MBUI_DIR/scripts/detlint" "$A" || exit 1
cd "$A"
moon check --target native --output-json 2>&1 | "$MBUI_DIR/scripts/chk" errs
[ "${PIPESTATUS[0]}" = 0 ] || exit 1
# (the kinds of test program this package has none of, not built; and its test programs compiled without optimising, as
# libs/ui/scripts/check-controls.sh and mbui's test_native.sh compile library tests)
empty=""
[ -n "$(ls src/cm/*.mbt 2>/dev/null | grep -vE '_(wb)?test\.mbt$' | xargs grep -l '^test ' 2>/dev/null)" ] || empty="$empty cm/cm.internal_test"
[ -n "$(ls src/cm/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$')" ] || empty="$empty cm/cm.blackbox_test"
[ -n "$(ls src/cm/*_wbtest.mbt 2>/dev/null)" ] || empty="$empty cm/cm.whitebox_test"
export MBC_EMPTY_TESTS="$empty"
export MBC_LIGHT_TESTS="cm/cm.internal_test cm/cm.blackbox_test cm/cm.whitebox_test"
moon_test_native -p comma-ui/cm 2>&1 | tail -${LINES_OUT:-40}
exit "${PIPESTATUS[0]}"
