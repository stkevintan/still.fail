#!/usr/bin/env python3
"""Wave M1.1 Vertical Dual-Oracle Pilot Harness (MoonBit wasm-gc vs Pion native vs Pion wasm32).

Compares across all 3 engines:
  (a) Outcome class: `ok` or `panic:<kind>` (SIGSEGV/139, raw wasm trap, timeout,
      unknown exit, or 0 executed traces+assertions are HARD FAIL);
  (b) Verbatim `T key=value` trace lines in exact order;
  (c) Verbatim `A <assertion_id>` lines in exact order + frozen per-case assertion count.

Also runs hot-path micro-benchmarks (`div_checked`, `OrderedMap`, `utf16_len`) on
both `pion-native` and `pion-wasm32`.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

TIMEOUT_S = 120

# Frozen per-case expectations: case -> (outcome_class, expected_assertion_count)
CASES = {
    "signal_by": ("ok", 4),
    "window_kept": ("ok", 3),
    "style_css": ("ok", 6),
    "guard_init_order": ("ok", 6),
    "opt_param_relay": ("ok", 5),
    "utf16_boundary": ("ok", 5),
    "arrayview_isolation": ("ok", 2),
    "ordered_map_double": ("ok", 5),
    "div_mod_nonzero": ("ok", 5),
    "cross_pkg_ref_sourceloc": ("ok", 3),
    "real_controls_numbers_marked": ("ok", 6),
    "real_controls_tokens_layout": ("ok", 2),
    "div_i32_const_zero": ("panic:div_zero", 0),
    "div_i32_rt_zero": ("panic:div_zero", 0),
    "mod_i32_rt_zero": ("panic:rem_zero", 0),
    "div_u32_rt_zero": ("panic:div_zero", 0),
    "mod_u32_rt_zero": ("panic:rem_zero", 0),
    "div_i64_rt_zero": ("panic:div_zero", 0),
    "div_i32_ovf": ("panic:div_overflow", 0),
}

MOON_TRAPS = {
    "divide by zero": "div_zero",
    "remainder by zero": "rem_zero",
    "divide result unrepresentable": "div_overflow",
    "integer overflow": "div_overflow",
    "unreachable": "abort",
    "array element access out of bounds": "oob",
}

PION_PANICS = [
    ("divide by zero", "div_zero"),
    ("remainder by zero", "rem_zero"),
    ("divide result unrepresentable", "div_overflow"),
    ("index out of bounds", "oob"),
    ("abort:", "abort"),
    ("assertion failed", "abort"),
]

ENGINES = ["moon", "pion-native", "pion-wasm32"]


def run_cmd(cmd, cwd=None, env=None):
    t0 = time.time()
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT_S,
        )
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
            False,
            time.time() - t0,
        )
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        err = (e.stderr or b"").decode("utf-8", "replace")
        return (None, out, err, True, time.time() - t0)


def classify(engine, rc, out, err, timed_out):
    if timed_out:
        return "HARD:timeout"
    if rc == 0:
        return "ok"
    if engine == "moon":
        m = re.search(r"RuntimeError: ([^\n]+)", err + "\n" + out)
        if rc == 1 and m:
            msg = m.group(1).strip()
            kind = MOON_TRAPS.get(msg)
            if kind is None:
                return f"HARD:unknown-moon-trap({msg})"
            return "panic:" + kind
        return f"HARD:moon-exit-{rc}"
    m = re.search(r"pion panic at [^\n]*?:\d+: ([^\n]*)", err)
    native_ok = rc in (134, -6)
    wasm_ok = rc == 1
    if m and ((engine == "pion-native" and native_ok) or (engine == "pion-wasm32" and wasm_ok)):
        msg = m.group(1)
        for prefix, kind in PION_PANICS:
            if msg.startswith(prefix):
                return "panic:" + kind
        return f"HARD:unclassified-pion-panic({msg})"
    if engine == "pion-wasm32" and "RuntimeError:" in err:
        t = re.search(r"RuntimeError: ([^\n]+)", err).group(1).strip()
        return f"HARD:raw-wasm-trap({t})"
    if rc in (139, -11):
        return "HARD:SIGSEGV"
    if rc is not None and rc < 0:
        return f"HARD:signal-{-rc}"
    return f"HARD:exit-{rc}"


def parse_lines(out):
    traces, asserts, junk = [], [], []
    for line in out.splitlines():
        if line.startswith("T "):
            traces.append(line[2:])
        elif line.startswith("A "):
            asserts.append(line[2:])
        elif line.strip():
            junk.append(line)
    return traces, asserts, junk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--moon-dir", required=True)
    ap.add_argument("--moon-extra-src", action="append", default=[])
    ap.add_argument(
        "--libs-ui-dir",
        default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../../libs/ui")),
    )
    ap.add_argument("--pion-dir", required=True)
    ap.add_argument("--moon-bin", default="moon")
    ap.add_argument("--pionc-bin", default="pionc")
    ap.add_argument("--no-bench", action="store_true")
    ap.add_argument("--report", default="")
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="m11-pilot-oracle.")
    try:
        moon_work = os.path.join(work, "moon_pilot")
        shutil.copytree(args.moon_dir, moon_work)
        # Stage real `libs/ui/src/{ui,...}` production packages so `moon_pilot`
        # calls real `@ui.css_read` (`libs/ui/src/ui/style_css.mbt`) directly.
        libs_ui_src = os.path.join(args.libs_ui_dir, "src")
        for dep_pkg in (
            "halt",
            "dmath",
            "zip",
            "codec",
            "signals",
            "pixels",
            "paint",
            "text",
            "flex",
            "effect",
            "damage",
            "hostapi",
            "view",
            "ui",
        ):
            src_pkg = os.path.join(libs_ui_src, dep_pkg)
            if not os.path.isdir(src_pkg):
                print(f"SETUP FAILED: missing real libs/ui package {src_pkg}", file=sys.stderr)
                return 2
            shutil.copytree(
                src_pkg,
                os.path.join(moon_work, "src", dep_pkg),
                ignore=shutil.ignore_patterns("*_test.mbt", "*_wbtest.mbt"),
            )
        moon_pkg_dir = os.path.join(moon_work, "src", "controls")
        for extra in args.moon_extra_src:
            shutil.copy2(extra, os.path.join(moon_pkg_dir, os.path.basename(extra)))
        native_bin = os.path.join(work, "pilot_native")
        wasm_bin = os.path.join(work, "pilot.wasm")

        setup_steps = [
            ([args.moon_bin, "build", "--target", "wasm-gc"], moon_work, "moon build --target wasm-gc"),
            ([args.pionc_bin, "check", "--json", args.pion_dir], None, "pionc check pion_pilot"),
            ([args.pionc_bin, "build", args.pion_dir, "-o", native_bin], None, "pionc build pion_pilot"),
            ([args.pionc_bin, "build", "--target", "wasm32", args.pion_dir, "-o", wasm_bin], None, "pionc build --target wasm32 pion_pilot"),
        ]
        for cmd, cwd, label in setup_steps:
            rc, out, err, to, secs = run_cmd(cmd, cwd=cwd)
            if rc != 0 or to:
                print(f"SETUP FAILED: {label} (rc={rc}, timeout={to})\n{out[-1500:]}\n{err[-1500:]}", file=sys.stderr)
                return 2
            print(f"[pilot-oracle] setup ok  {label:<40s} ({secs:.2f}s)")

        failures = []
        case_reports = {}
        total_asserts = 0

        for case, (expect_cls, expect_n) in CASES.items():
            # Run on all 3 engines
            moon_r = run_cmd([args.moon_bin, "run", "--target", "wasm-gc", "src/controls", "--", case], cwd=moon_work)
            nat_r = run_cmd([native_bin, case])
            wasm_r = run_cmd([args.pionc_bin, "run", "--target", "wasm32", args.pion_dir, "--", case])
            results = {
                "moon": moon_r[:4],
                "pion-native": nat_r[:4],
                "pion-wasm32": wasm_r[:4],
            }

            errs = []
            parsed = {}
            for eng in ENGINES:
                rc, out, err, to = results[eng]
                cls = classify(eng, rc, out, err, to)
                traces, asserts, junk = parse_lines(out)
                parsed[eng] = (cls, traces, asserts)
                if cls.startswith("HARD:"):
                    errs.append(f"{eng}: hard fail {cls} (rc={rc}) stderr={err.strip()[-300:]}")
                if not traces and not asserts:
                    errs.append(f"{eng}: executed 0 traces and 0 assertions")
                if junk:
                    errs.append(f"{eng}: unexpected stdout {junk[:3]!r}")
                if cls != expect_cls:
                    errs.append(f"{eng}: outcome {cls} != expected {expect_cls}")
                if len(asserts) != expect_n:
                    errs.append(f"{eng}: {len(asserts)} assertions != expected {expect_n}")

            ref_t, ref_a = parsed["moon"][1], parsed["moon"][2]
            for eng in ENGINES[1:]:
                t, a = parsed[eng][1], parsed[eng][2]
                if t != ref_t:
                    errs.append(f"{eng}: trace mismatch vs moon: moon={ref_t!r} {eng}={t!r}")
                if a != ref_a:
                    errs.append(f"{eng}: assertion IDs mismatch vs moon: moon={ref_a!r} {eng}={a!r}")

            status = "PASS" if not errs else "FAIL"
            total_asserts += len(ref_a)
            print(f"[pilot-oracle] {status:<4s} {case:<26s} outcome={parsed['moon'][0]:<19s} asserts={len(ref_a)} traces={len(ref_t)}")
            for e in errs:
                print(f"    ERROR: {e}", file=sys.stderr)
                failures.append(f"{case}: {e}")
            case_reports[case] = {
                "ok": not errs,
                "outcome": parsed["moon"][0],
                "asserts": ref_a,
                "traces": ref_t,
                "errors": errs,
            }

        bench_out = {}
        if not args.no_bench:
            for eng, cmd in [
                ("pion-native", [native_bin, "bench"]),
                ("pion-wasm32", [args.pionc_bin, "run", "--target", "wasm32", args.pion_dir, "--", "bench"]),
            ]:
                rc, out, err, to, _ = run_cmd(cmd)
                if rc != 0:
                    print(f"[pilot-oracle] BENCH WARN ({eng} rc={rc}): {err[-300:]}", file=sys.stderr)
                else:
                    lines = [l for l in out.splitlines() if l.startswith("BENCH ")]
                    bench_out[eng] = lines
                    for l in lines:
                        print(f"[pilot-bench:{eng}] {l}")

        if args.report:
            with open(args.report, "w") as f:
                json.dump(
                    {
                        "ok": len(failures) == 0,
                        "cases_total": len(CASES),
                        "cases_passed": sum(1 for v in case_reports.values() if v["ok"]),
                        "assertions_per_engine": total_asserts,
                        "engines": ENGINES,
                        "cases": case_reports,
                        "bench": bench_out,
                    },
                    f,
                    indent=2,
                )
                f.write("\n")

        if failures:
            print(f"\n[pilot-oracle] FAILED ({len(failures)} error(s))", file=sys.stderr)
            return 1
        print(f"\n[pilot-oracle] ALL {len(CASES)}/{len(CASES)} CASES PASSED 100% ACROSS 3 ENGINES ({total_asserts} assertions/engine)")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
