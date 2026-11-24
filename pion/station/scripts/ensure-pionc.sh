#!/bin/sh
# Ensure the pinned Pion toolchain (pionc, qbe, libpionrt.a, pion_rt.c/h) is installed and verified.
# Reads the pinned AFK-surf/pion commit SHA from pion/station/TOOLCHAIN and verifies local cache
# integrity with SHA256SUMS across all 5 required toolchain artifacts.
#
# Environment:
#   PIONC              Override path to an existing pionc binary (PION_BUILD_SHA is tagged
#                      override(...) unless ALL 5 artifacts — pionc, qbe, libpionrt.a, pion_rt.c/h —
#                      come from the exact same SHA256SUMS-verified pinned TOOLCHAIN_DIR).
#   PION_QBE           Override path to qbe binary (forces PION_BUILD_SHA=override(qbe=...) if
#                      different from the verified TOOLCHAIN_DIR/bin/qbe).
#   PION_TOOLCHAIN_DIR Override install/cache directory (default: $XDG_CACHE_HOME/pion-station-toolchain/<sha>).
#   PION_RT_DIR        Override runtime source/header directory (forces PION_BUILD_SHA=override(rt=...) if
#                      different from the verified TOOLCHAIN_DIR/share/pion/runtime).
#   PION_REPO_URL      Override upstream git URL (default: https://github.com/AFK-surf/pion.git).
#   PION_DEPLOY_KEY    Optional SSH private key for private AFK-surf/pion.
#   PION_TOKEN         Optional GitHub token for private AFK-surf/pion.
#
# Usage:
#   sh pion/station/scripts/ensure-pionc.sh [--print-path | --print-env | --env]
set -eu

MODE="summary"
MODE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print-path) MODE="path"; MODE_ARG="--print-path"; shift ;;
    --print-env|--env) MODE="env"; MODE_ARG="--print-env"; shift ;;
    -h|--help)
      echo "usage: sh pion/station/scripts/ensure-pionc.sh [--print-path | --print-env | --env]"
      exit 0
      ;;
    *)
      echo "ensure-pionc.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
STATION_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TOOLCHAIN_FILE="$STATION_DIR/TOOLCHAIN"
PINNED_SHA="$(sed -n 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d; p; q' "$TOOLCHAIN_FILE" | tr -d '[:space:]')"
if [ "${#PINNED_SHA}" -ne 40 ]; then
  echo "ensure-pionc.sh: invalid commit SHA in $TOOLCHAIN_FILE: '$PINNED_SHA'" >&2
  exit 1
fi

REQUIRED_FILES="bin/pionc bin/qbe lib/libpionrt.a share/pion/runtime/pion_rt.c share/pion/runtime/pion_rt.h"

canon_dir() {
  CDPATH= cd -- "$1" 2>/dev/null && pwd -P
}

canon_file() {
  f_dir="$(canon_dir "$(dirname -- "$1")" || true)"
  [ -n "$f_dir" ] || return 1
  printf '%s/%s\n' "$f_dir" "$(basename -- "$1")"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_sums() {
  dir="$1"
  sums="$dir/SHA256SUMS"
  [ -s "$sums" ] || return 1
  for req in $REQUIRED_FILES; do
    [ -f "$dir/$req" ] || return 1
    want="$(awk -v target="$req" '$2 == target { print $1; exit }' "$sums")"
    if [ "${#want}" -ne 64 ]; then
      echo "ensure-pionc.sh: missing or malformed checksum entry for $req in $sums" >&2
      return 1
    fi
    got="$(sha256_file "$dir/$req")"
    if [ "$got" != "$want" ]; then
      echo "ensure-pionc.sh: checksum mismatch for $dir/$req (got $got, expected $want)" >&2
      return 1
    fi
  done
  return 0
}

write_sums() {
  dir="$1"
  tmp="$dir/SHA256SUMS.tmp.$$"
  : > "$tmp"
  for rel in $REQUIRED_FILES; do
    if [ ! -f "$dir/$rel" ]; then
      rm -f "$tmp"
      echo "ensure-pionc.sh: missing installed artifact $dir/$rel" >&2
      return 1
    fi
    printf '%s  %s\n' "$(sha256_file "$dir/$rel")" "$rel" >> "$tmp"
  done
  mv -f "$tmp" "$dir/SHA256SUMS"
}

emit_result() {
  pionc_bin="$1"
  qbe_bin="$2"
  tc_dir="$3"
  rt_dir="$4"
  build_sha="$5"
  case "$MODE" in
    path)
      printf '%s\n' "$pionc_bin"
      ;;
    env)
      printf 'export PIONC=%s\n' "'$pionc_bin'"
      printf 'export PION_QBE=%s\n' "'$qbe_bin'"
      printf 'export PION_TOOLCHAIN_DIR=%s\n' "'$tc_dir'"
      printf 'export PION_RT_DIR=%s\n' "'$rt_dir'"
      printf 'export PION_PINNED_SHA=%s\n' "'$PINNED_SHA'"
      printf 'export PION_BUILD_SHA=%s\n' "'$build_sha'"
      printf 'export PATH="%s:%s"\n' "$(dirname "$pionc_bin")" '$PATH'
      ;;
    summary)
      echo "pionc=$pionc_bin qbe=$qbe_bin build_sha=$build_sha rt=$rt_dir" >&2
      "$pionc_bin" --version >&2 || true
      ;;
  esac
}

if [ -n "${PIONC:-}" ]; then
  if [ ! -x "$PIONC" ]; then
    echo "ensure-pionc.sh: PIONC=$PIONC is not executable" >&2
    exit 1
  fi
  bin_dir="$(canon_dir "$(dirname -- "$PIONC")")"
  pionc_base="$(basename -- "$PIONC")"
  tc_dir_raw="${PION_TOOLCHAIN_DIR:-$(dirname -- "$bin_dir")}"
  tc_dir="$(canon_dir "$tc_dir_raw")"
  rt_dir_raw="${PION_RT_DIR:-$tc_dir/share/pion/runtime}"
  rt_dir="$(canon_dir "$rt_dir_raw" || true)"
  if [ -n "${PION_QBE:-}" ]; then
    if [ ! -x "$PION_QBE" ]; then
      echo "ensure-pionc.sh: PION_QBE=$PION_QBE is not executable" >&2
      exit 1
    fi
    qbe_bin="$(canon_file "$PION_QBE")"
  elif [ -x "$bin_dir/qbe" ]; then
    qbe_bin="$bin_dir/qbe"
  elif [ -x "$tc_dir/bin/qbe" ]; then
    qbe_bin="$tc_dir/bin/qbe"
  else
    echo "ensure-pionc.sh: PIONC override missing sibling qbe in $bin_dir or $tc_dir/bin" >&2
    exit 1
  fi
  if [ ! -f "$tc_dir/lib/libpionrt.a" ]; then
    echo "ensure-pionc.sh: PIONC override missing $tc_dir/lib/libpionrt.a" >&2
    exit 1
  fi
  if [ -z "$rt_dir" ] || [ ! -f "$rt_dir/pion_rt.c" ] || [ ! -f "$rt_dir/pion_rt.h" ]; then
    echo "ensure-pionc.sh: PIONC override missing runtime headers/source in $rt_dir_raw" >&2
    exit 1
  fi
  expected_bin_dir="$(canon_dir "$tc_dir/bin" || true)"
  expected_rt_dir="$(canon_dir "$tc_dir/share/pion/runtime" || true)"
  expected_qbe="$expected_bin_dir/qbe"
  if [ "$pionc_base" = "pionc" ] && \
     [ "$bin_dir" = "$expected_bin_dir" ] && \
     [ "$rt_dir" = "$expected_rt_dir" ] && \
     [ "$qbe_bin" = "$expected_qbe" ] && \
     [ "$(cat "$tc_dir/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && \
     verify_sums "$tc_dir"; then
    emit_result "$tc_dir/bin/pionc" "$expected_qbe" "$tc_dir" "$expected_rt_dir" "$PINNED_SHA"
  elif [ "$qbe_bin" != "$expected_qbe" ]; then
    emit_result "$PIONC" "$qbe_bin" "$tc_dir" "$rt_dir" "override(qbe=$qbe_bin)"
  elif [ "$rt_dir" != "$expected_rt_dir" ]; then
    emit_result "$PIONC" "$qbe_bin" "$tc_dir" "$rt_dir" "override(rt=$rt_dir)"
  else
    emit_result "$PIONC" "$qbe_bin" "$tc_dir" "$rt_dir" "override($PIONC)"
  fi
  exit 0
fi

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/pion-station-toolchain"
TOOLCHAIN_DIR="${PION_TOOLCHAIN_DIR:-$CACHE_BASE/$PINNED_SHA}"
REPO_URL="${PION_REPO_URL:-https://github.com/AFK-surf/pion.git}"

check_verified_dir() {
  dir="$1"
  [ -x "$dir/bin/pionc" ] || return 1
  [ -x "$dir/bin/qbe" ] || return 1
  [ "$(cat "$dir/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] || return 1
  verify_sums "$dir" || return 1
  c_dir="$(canon_dir "$dir")"
  expected_rt="$(canon_dir "$c_dir/share/pion/runtime")"
  expected_qbe="$c_dir/bin/qbe"
  c_rt="$(canon_dir "${PION_RT_DIR:-$expected_rt}" || true)"
  if [ -z "$c_rt" ] || [ ! -f "$c_rt/pion_rt.c" ] || [ ! -f "$c_rt/pion_rt.h" ]; then
    echo "ensure-pionc.sh: PION_RT_DIR=$c_rt missing runtime sources" >&2
    exit 1
  fi
  if [ -n "${PION_QBE:-}" ]; then
    if [ ! -x "$PION_QBE" ]; then
      echo "ensure-pionc.sh: PION_QBE=$PION_QBE is not executable" >&2
      exit 1
    fi
    c_qbe="$(canon_file "$PION_QBE")"
  else
    c_qbe="$expected_qbe"
  fi
  if [ "$c_rt" = "$expected_rt" ] && [ "$c_qbe" = "$expected_qbe" ]; then
    emit_result "$c_dir/bin/pionc" "$expected_qbe" "$c_dir" "$expected_rt" "$PINNED_SHA"
  elif [ "$c_qbe" != "$expected_qbe" ]; then
    emit_result "$c_dir/bin/pionc" "$c_qbe" "$c_dir" "$c_rt" "override(qbe=$c_qbe)"
  else
    emit_result "$c_dir/bin/pionc" "$c_qbe" "$c_dir" "$c_rt" "override(rt=$c_rt)"
  fi
  return 0
}

if check_verified_dir "$TOOLCHAIN_DIR"; then
  exit 0
fi

if [ -z "${PION_TOOLCHAIN_DIR:-}" ] && check_verified_dir "$HOME/.pion"; then
  exit 0
fi

# Serialize concurrent bootstraps for the same TOOLCHAIN_DIR using kernel-managed flock.
# In perl/python3 fallback modes, clear FD_CLOEXEC and exec directly into this script so the
# bootstrap process itself owns the lock fd until exit (zero wrapper-kill or stale-PID races).
mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
FLOCK_FILE="${TOOLCHAIN_DIR}.flock"

if [ "${PION_ENSURE_UNDER_LOCK:-0}" != "1" ]; then
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$FLOCK_FILE"
    flock 9
  elif command -v perl >/dev/null 2>&1; then
    PION_ENSURE_UNDER_LOCK=1 exec perl -MFcntl=:flock,F_SETFD -e '
      my $lf = shift @ARGV;
      open my $fh, ">>", $lf or die "open $lf: $!";
      fcntl($fh, F_SETFD, 0) or die "fcntl F_SETFD $lf: $!";
      flock($fh, LOCK_EX) or die "flock $lf: $!";
      exec @ARGV or die "exec $ARGV[0]: $!";
    ' "$FLOCK_FILE" sh "$0" ${MODE_ARG:+"$MODE_ARG"}
  elif command -v python3 >/dev/null 2>&1; then
    PION_ENSURE_UNDER_LOCK=1 exec python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o666)
fcntl.flock(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
os.execvp(sys.argv[2], sys.argv[2:])
' "$FLOCK_FILE" sh "$0" ${MODE_ARG:+"$MODE_ARG"}
  else
    echo "ensure-pionc.sh: flock, perl, or python3 is required to serialize toolchain bootstrap" >&2
    exit 1
  fi
fi

WORK_DIR=""
STAGE_DIR=""
cleanup() {
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" || true
  [ -n "$STAGE_DIR" ] && [ -e "$STAGE_DIR" ] && rm -rf "$STAGE_DIR" || true
}
trap cleanup EXIT

# Re-check after acquiring lock: another process may have finished installing cleanly.
if check_verified_dir "$TOOLCHAIN_DIR"; then
  exit 0
fi

echo "ensure-pionc.sh: bootstrapping AFK-surf/pion @ $PINNED_SHA into $TOOLCHAIN_DIR" >&2
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pion-bootstrap.XXXXXX")"
SRC_DIR="$WORK_DIR/pion-src"
STAGE_DIR="$(mktemp -d "$(dirname "$TOOLCHAIN_DIR")/.stage-$PINNED_SHA.XXXXXX")"
mkdir -p "$SRC_DIR"

git -C "$SRC_DIR" init -q
if [ -n "${PION_DEPLOY_KEY:-}" ]; then
  umask 077
  printf '%s\n' "$PION_DEPLOY_KEY" > "$WORK_DIR/pion_deploy_key"
  export GIT_SSH_COMMAND="ssh -i '$WORK_DIR/pion_deploy_key' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
  FETCHED=0
  for url in "git@github.com:AFK-surf/pion.git" "ssh://git@ssh.github.com:443/AFK-surf/pion.git"; do
    git -C "$SRC_DIR" remote remove origin 2>/dev/null || true
    git -C "$SRC_DIR" remote add origin "$url"
    if git -C "$SRC_DIR" fetch --depth 1 origin "$PINNED_SHA" >&2; then
      FETCHED=1
      break
    fi
  done
  if [ "$FETCHED" -ne 1 ]; then
    echo "ensure-pionc.sh: failed to fetch $PINNED_SHA via PION_DEPLOY_KEY" >&2
    exit 1
  fi
elif [ -n "${PION_TOKEN:-}" ] && [ "${REPO_URL#https://}" != "$REPO_URL" ]; then
  AUTH_B64="$(printf 'x-access-token:%s' "$PION_TOKEN" | base64 | tr -d '\n\r')"
  git -C "$SRC_DIR" remote add origin "$REPO_URL"
  git -C "$SRC_DIR" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $AUTH_B64" \
    fetch --depth 1 origin "$PINNED_SHA" >&2
else
  git -C "$SRC_DIR" remote add origin "$REPO_URL"
  git -C "$SRC_DIR" fetch --depth 1 origin "$PINNED_SHA" >&2
fi
git -C "$SRC_DIR" checkout -q FETCH_HEAD

GOT_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$GOT_SHA" != "$PINNED_SHA" ]; then
  echo "ensure-pionc.sh: checked out SHA $GOT_SHA != pinned $PINNED_SHA" >&2
  exit 1
fi

(
  cd "$SRC_DIR"
  sh scripts/install.sh --prefix "$STAGE_DIR" >&2
)

printf '%s\n' "$PINNED_SHA" > "$STAGE_DIR/TOOLCHAIN_SHA"
write_sums "$STAGE_DIR"

if [ -e "$TOOLCHAIN_DIR" ]; then
  mv "$TOOLCHAIN_DIR" "${TOOLCHAIN_DIR}.old.$$"
  mv "$STAGE_DIR" "$TOOLCHAIN_DIR"
  STAGE_DIR=""
  rm -rf "${TOOLCHAIN_DIR}.old.$$"
else
  mv "$STAGE_DIR" "$TOOLCHAIN_DIR"
  STAGE_DIR=""
fi

check_verified_dir "$TOOLCHAIN_DIR"
