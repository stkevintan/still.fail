#!/bin/sh
# Reproducible Lean 4 proof gate for `pion/rules` (`fork`, `history`, `role`)
# and `pion/client-core` pure security/algorithm kernels (`views`).
#
# Steps:
#   1. Link Aeneas Lean backend (`AeneasVerif/aeneas` @ 1dc8ad31b1) from cache;
#   2. Materialize mathlib cache if needed (`lake exe cache get`);
#   3. Extract `Fork`, `History`, `Role`, `Views` directly from Pion source via
#      `pionc extract-lean --json`;
#   4. Reject any `sorry`, `admit`, `bv_decide`, `native_decide` in proofs;
#   5. `lake build` `PionLean`, extracted libs, and `RulesProofs` (0 errors, 0 sorry);
#   6. Axiom audit (`CheckAxioms.lean`): only `{propext, Classical.choice, Quot.sound}`;
#   7. Differential gate: native Pion execution vs `lake env lean Eval.lean` (`diff -u` exit 0).
set -eu

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RULES_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$RULES_DIR/../.." && pwd)
PROOFS_DIR="$RULES_DIR/proofs"
WORK_DIR="$PROOFS_DIR/.prove-work"
AENEAS_REV=1dc8ad31b1
LEAN_THREADS="${LEAN_NUM_THREADS:-4}"

mkdir -p "$PROOFS_DIR/.deps" "$WORK_DIR"

echo "=== [1/7] Aeneas Lean backend ($AENEAS_REV) ==="
if [ -z "${AENEAS_DIR:-}" ]; then
  AENEAS_CACHE="${AENEAS_CACHE:-$HOME/.cache/aeneas-$AENEAS_REV}"
  if [ ! -d "$AENEAS_CACHE/.git" ]; then
    git clone -q https://github.com/AeneasVerif/aeneas.git "$AENEAS_CACHE"
  fi
  git -C "$AENEAS_CACHE" checkout -q "$AENEAS_REV"
  AENEAS_DIR="$AENEAS_CACHE/backends/lean"
fi
ln -sfn "$AENEAS_DIR" "$PROOFS_DIR/.deps/aeneas"

echo "=== [2/7] Mathlib cache check ==="
cd "$PROOFS_DIR"
if [ ! -d "$PROOFS_DIR/.lake/packages/mathlib/.lake/build" ]; then
  if [ -n "${LEAN_PACKAGES_SEED:-}" ]; then
    mkdir -p "$PROOFS_DIR/.lake"
    cp -Rc "$LEAN_PACKAGES_SEED" "$PROOFS_DIR/.lake/packages" 2>/dev/null || cp -R "$LEAN_PACKAGES_SEED" "$PROOFS_DIR/.lake/packages"
  else
    lake exe cache get
  fi
fi

echo "=== [3/7] pionc extract-lean (fork, history, role, views) ==="
for pkg in "$RULES_DIR/packages/fork" "$RULES_DIR/packages/history" "$RULES_DIR/packages/role"; do
  OUT=$(pionc extract-lean --json --out "$PROOFS_DIR" "$pkg")
  echo "$OUT"
done
OUT=$(pionc extract-lean --json --pkg views --out "$PROOFS_DIR" "$REPO_ROOT/pion/client-core")
echo "$OUT"

for m in Fork History Role Views; do
  for f in Types Funs FunsExternal FunsExternal_Template; do
    if [ ! -f "$PROOFS_DIR/$m/$f.lean" ]; then
      echo "FAIL: missing $m/$f.lean" >&2
      exit 1
    fi
  done
done

echo "=== [4/7] Forbidden-tactic scan ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$PROOFS_DIR/RulesProofs" >/dev/null; then
  echo "FAIL: RulesProofs must not contain sorry / admit / bv_decide / native_decide" >&2
  grep -rnwE "sorry|admit|bv_decide|native_decide" "$PROOFS_DIR/RulesProofs" >&2
  exit 1
fi

echo "=== [5/7] lake build (LEAN_NUM_THREADS=$LEAN_THREADS) ==="
set +e
LEAN_NUM_THREADS="$LEAN_THREADS" lake build PionLean Fork History Role Views RulesProofs > "$WORK_DIR/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info\|^⣾\|^⣷\|^⣯\|^⣟\|^⡿\|^⢿\|^⣻\|^⣽' "$WORK_DIR/build.log" | tail -80 || true
if [ "$RC" -ne 0 ] || grep -q '^error:' "$WORK_DIR/build.log"; then
  echo "FAIL: lake build failed (rc=$RC)" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK_DIR/build.log"; then
  echo "FAIL: a declaration uses sorry" >&2
  exit 1
fi

echo "=== [6/7] Axiom audit (CheckAxioms.lean) ==="
lake env lean "$PROOFS_DIR/RulesProofs/CheckAxioms.lean" > "$WORK_DIR/axioms.out" 2>&1
cat "$WORK_DIR/axioms.out"
THEOREMS=$(grep -c "depends on axioms:\|does not depend on any axioms" "$WORK_DIR/axioms.out")
if [ "$THEOREMS" -lt 40 ]; then
  echo "FAIL: expected >= 40 audited theorems, got $THEOREMS" >&2
  exit 1
fi
BAD_AXIOMS=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
allowed = {"propext", "Classical.choice", "Quot.sound"}
bad = set()
for m in re.finditer(r"depends on axioms:\s*\[([^\]]*)\]", text, re.S):
    for ax in m.group(1).split(","):
        ax = ax.strip()
        if ax and ax not in allowed:
            bad.add(ax)
for ax in sorted(bad):
    print(ax)
' "$WORK_DIR/axioms.out")
if [ -n "$BAD_AXIOMS" ]; then
  echo "FAIL: unexpected axioms found: $BAD_AXIOMS" >&2
  exit 1
fi
echo "axioms: $THEOREMS theorems audited, only standard axioms {propext, Classical.choice, Quot.sound}"

echo "=== [7/7] Differential check (native Pion vs Lean #eval) ==="
RUNNER_DIR="$WORK_DIR/native_runner"
mkdir -p "$RUNNER_DIR/src"
cat > "$RUNNER_DIR/pion.toml" <<EOF
[workspace]
members = ["."]

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
effect = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "effect-v0.1.0", subdir = "packages/effect" }
crypto = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "crypto-v0.2.0", subdir = "packages/crypto" }
flate = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "flate-v0.1.0", subdir = "packages/flate" }
url = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "url-v0.1.0", subdir = "packages/url" }
time = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "time-v0.1.0", subdir = "packages/time" }
http1 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "http1-v0.1.0", subdir = "packages/http1" }
json5 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "json5-v0.1.0", subdir = "packages/json5" }
base_codec = { path = "$REPO_ROOT/pion/base/packages/base_codec" }
wire = { path = "$REPO_ROOT/pion/base/packages/wire" }
shell = { path = "$REPO_ROOT/pion/base/packages/shell" }
sql = { path = "$REPO_ROOT/pion/base/packages/sql" }
mesh = { path = "$REPO_ROOT/pion/base/packages/mesh" }
form = { path = "$RULES_DIR/packages/form" }
fork = { path = "$RULES_DIR/packages/fork" }
history = { path = "$RULES_DIR/packages/history" }
role = { path = "$RULES_DIR/packages/role" }
lock = { path = "$RULES_DIR/packages/lock" }
vault = { path = "$RULES_DIR/packages/vault" }
outbox = { path = "$REPO_ROOT/pion/client-core/packages/outbox" }
store = { path = "$REPO_ROOT/pion/client-core/packages/store" }
protocol = { path = "$REPO_ROOT/pion/client-core/packages/protocol" }
core_abi = { path = "$REPO_ROOT/pion/client-core/packages/core_abi" }
views = { path = "$REPO_ROOT/pion/client-core/packages/views" }

[package]
name = "rules_diff_runner"
version = "0.1.0"

[dependencies]
fork = { workspace = true }
history = { workspace = true }
role = { workspace = true }
views = { workspace = true }
EOF

cat > "$RUNNER_DIR/src/main.pion" <<'EOF'
import "fork"
import "history"
import "role"
import "views"

fn fmt_bool(b : Bool) -> String {
  if b { "true" } else { "false" }
}

fn fmt_opt_str(o : Option[String]) -> String {
  match o {
    Some(s) => "some(" + s + ")"
    None => "none"
  }
}

fn fmt_role(r : role::Role) -> String {
  match r {
    role::Role::Viewer => "Viewer"
    role::Role::Member => "Member"
    role::Role::Admin => "Admin"
    role::Role::Owner => "Owner"
  }
}

fn fmt_adm(a : role::Admission) -> String {
  match a {
    role::Admission::Admitted => "Admitted"
    role::Admission::Unknown => "Unknown"
    role::Admission::Others => "Others"
    role::Admission::RanOut => "RanOut"
    role::Admission::NoMember => "NoMember"
  }
}

fn fmt_ranges(rs : Array[views::ByteRange]) -> String {
  let mut s = "["
  for i in 0..<rs.length() {
    if i > 0 {
      s = s + ","
    }
    s = s + "[" + rs[i].start.to_string() + "," + rs[i].end.to_string() + ")"
  }
  s + "]"
}

fn main(w : World) -> Unit {
  io_println(w, "fork.ahead.1=" + fmt_bool(fork::ahead(5, false, 10, 2, 3, true, 1, 0)))
  io_println(w, "fork.ahead.2=" + fmt_bool(fork::ahead(5, true, 10, 2, 5, false, 1, 0)))
  io_println(w, "fork.ahead.3=" + fmt_bool(fork::ahead(5, false, 1, 9, 5, false, 2, 0)))
  io_println(w, "fork.ahead.4=" + fmt_bool(fork::ahead(5, false, 1, 2, 5, false, 1, 2)))
  io_println(w, "fork.best.1=" + fork::best([1, 3, 3, 2], [false, false, true, true], [0, 0, 5, 0], [0, 1, 2, 3]).to_string())
  io_println(w, "fork.best.2=" + fork::best([2, 2, 2], [false, false, false], [4, 1, 1], [9, 7, 3]).to_string())

  io_println(w, "history.follows.1=" + fmt_bool(history::follows(false, 5.to_int64(), 6.to_int64())))
  io_println(w, "history.follows.2=" + fmt_bool(history::follows(false, 5.to_int64(), 7.to_int64())))
  io_println(w, "history.follows.3=" + fmt_bool(history::follows(true, 5.to_int64(), 9.to_int64())))
  io_println(w, "history.epoch.1=" + fmt_bool(history::epoch_ok(true, 3.to_int64(), 3.to_int64())))
  io_println(w, "history.epoch.2=" + fmt_bool(history::epoch_ok(true, 3.to_int64(), 4.to_int64())))
  io_println(w, "history.deletion.1=" + fmt_bool(history::deletion_ok(true, false)))
  io_println(w, "history.deletion.2=" + fmt_bool(history::deletion_ok(true, true)))
  io_println(w, "history.item_epoch.1=" + fmt_bool(history::item_epoch_ok(false, false, 2.to_int64(), 3.to_int64())))
  io_println(w, "history.item_epoch.2=" + fmt_bool(history::item_epoch_ok(false, true, 2.to_int64(), 3.to_int64())))
  io_println(w, "history.unexpired.1=" + fmt_bool(history::unexpired(true, 10.to_int64(), 10.to_int64())))
  io_println(w, "history.unexpired.2=" + fmt_bool(history::unexpired(true, 11.to_int64(), 10.to_int64())))
  io_println(w, "history.supersedes.1=" + fmt_bool(history::supersedes(2.to_int64(), false, 1.to_int64(), 2.to_int64(), true, 9.to_int64(), 1)))
  io_println(w, "history.supersedes.2=" + fmt_bool(history::supersedes(2.to_int64(), true, 1.to_int64(), 2.to_int64(), false, 9.to_int64(), -1)))
  io_println(w, "history.item_open.1=" + fmt_bool(history::item_open(true)))

  io_println(w, "role.lower.1=" + fmt_role(role::lower(role::Role::Owner, role::Role::Admin)))
  io_println(w, "role.may.1=" + fmt_bool(role::may(role::Role::Admin, role::Change::MemberSet(false, true))))
  io_println(w, "role.may.2=" + fmt_bool(role::may(role::Role::Owner, role::Change::MemberSet(false, true))))
  io_println(w, "role.own.1=" + fmt_bool(role::own_device(false, false, role::Role::Owner, true)))
  io_println(w, "role.own.2=" + fmt_bool(role::own_device(false, false, role::Role::Admin, false)))
  io_println(w, "role.keeps.1=" + fmt_bool(role::keeps_owner(1, true, false)))
  io_println(w, "role.keeps.2=" + fmt_bool(role::keeps_owner(2, true, false)))
  io_println(w, "role.admission.1=" + fmt_adm(role::admission(true, true, true, true)))
  io_println(w, "role.admission.2=" + fmt_adm(role::admission(true, false, true, true)))
  io_println(w, "role.person_admits.1=" + fmt_bool(role::person_admits(true, true, true)))

  io_println(w, "views.admit.1=" + fmt_opt_str(views::admit_member_role(None, "owner")))
  io_println(w, "views.admit.2=" + fmt_opt_str(views::admit_member_role(Some("admin"), "member")))
  io_println(w, "views.admit_actor.1=" + fmt_opt_str(views::admit_member_role_by_actor("admin", Some("owner"), None, "owner")))
  io_println(w, "views.admit_actor.2=" + fmt_opt_str(views::admit_member_role_by_actor("member", Some("viewer"), None, "viewer")))
  io_println(w, "views.admit_actor.3=" + fmt_opt_str(views::admit_member_role_by_actor("owner", Some("admin"), None, "owner")))
  io_println(w, "views.vault_scope.1=" + fmt_bool(views::vault_allows_scope(Some("once"), "hour")))
  io_println(w, "views.vault_scope.2=" + fmt_bool(views::vault_allows_scope(Some("hour"), "hour")))
  io_println(w, "views.vault_scope.3=" + fmt_bool(views::vault_allows_scope(None, "chat")))
  let sample : Array[views::ByteRange] = [
    views::ByteRange::new(10.to_int64(), 20.to_int64()),
    views::ByteRange::new(5.to_int64(), 5.to_int64()),
    views::ByteRange::new(0.to_int64(), 8.to_int64()),
    views::ByteRange::new(8.to_int64(), 12.to_int64()),
    views::ByteRange::new(25.to_int64(), 30.to_int64()),
  ]
  io_println(w, "views.merge.1=" + fmt_ranges(views::merge_ranges(sample)))
  io_println(w, "views.missing.1=" + fmt_ranges(views::missing_ranges(views::ByteRange::new(0.to_int64(), 35.to_int64()), sample)))
}
EOF

pionc build -o "$WORK_DIR/native_runner_bin" "$RUNNER_DIR"
"$WORK_DIR/native_runner_bin" > "$WORK_DIR/native.out"
lake env lean "$PROOFS_DIR/Eval.lean" > "$WORK_DIR/lean.out"
diff -u "$WORK_DIR/native.out" "$WORK_DIR/lean.out"
CASES=$(wc -l < "$WORK_DIR/native.out" | tr -d ' ')
echo "differential: $CASES cases, diff -u exit 0"
echo "PASS: prove-lean"
