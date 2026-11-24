#!/bin/sh
# Installer for the ui.monoid (ui) CLI and prebuilt runtime shells.
# Hosted at: https://ui.monoid.build/install.sh
#
# Usage:
#   curl -fsSL https://ui.monoid.build/install.sh | sh
#   sh install.sh [--version VER] [--prefix DIR] [--no-runtime] [--dry-run]
set -eu

VERSION="${MBUI_VERSION:-latest}"
PREFIX="${MBUI_PREFIX:-$HOME/.local}"
BASE_URL="${MBUI_RELEASE_BASE_URL:-https://github.com/AFK-surf/mbui/releases}"
DRY_RUN=0
INSTALL_RUNTIME=1

usage() {
  cat <<'EOF'
usage: install.sh [--version VER] [--prefix DIR] [--no-runtime] [--dry-run] [-h|--help]

Options:
  --version VER   Release tag to install (e.g. v0.1.0, default: latest)
  --prefix DIR    Install prefix (default: $HOME/.local; binary in DIR/bin/ui,
                  prebuilt runtime in DIR/share/ui/runtime)
  --no-runtime    Install only the ui CLI without prebuilt ui-runtime shell
  --dry-run       Print resolved platform, URLs, and paths without downloading or writing
  -h, --help      Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || { echo "install.sh: --version requires a value" >&2; exit 2; }
      VERSION=$2
      shift 2
      ;;
    --prefix)
      [ $# -ge 2 ] || { echo "install.sh: --prefix requires a value" >&2; exit 2; }
      PREFIX=$2
      shift 2
      ;;
    --no-runtime)
      INSTALL_RUNTIME=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

detect_platform() {
  OS=$(uname -s)
  ARCH=$(uname -m)
  case "$OS" in
    Darwin) OS_SLUG="macos" ;;
    Linux)  OS_SLUG="linux" ;;
    *)
      echo "install.sh: unsupported OS '$OS' (expected Darwin or Linux)" >&2
      exit 1
      ;;
  esac
  case "$ARCH" in
    arm64|aarch64) ARCH_SLUG="arm64" ;;
    x86_64|amd64)  ARCH_SLUG="x64" ;;
    *)
      echo "install.sh: unsupported architecture '$ARCH' (expected arm64 or x86_64)" >&2
      exit 1
      ;;
  esac
  TARGET="${OS_SLUG}-${ARCH_SLUG}"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "install.sh: neither sha256sum nor shasum found for SHA-256 verification" >&2
    exit 1
  fi
}

verify_sha256() {
  ARCHIVE_PATH=$1
  ARCHIVE_NAME=$2
  SUMS_FILE=$3
  EXPECTED=$(awk -v f="$ARCHIVE_NAME" '$2 == f || $2 == ("*" f) { print $1; exit }' "$SUMS_FILE")
  if [ -z "$EXPECTED" ]; then
    echo "install.sh: no checksum entry for $ARCHIVE_NAME in SHA256SUMS" >&2
    exit 1
  fi
  ACTUAL=$(sha256_file "$ARCHIVE_PATH")
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "install.sh: SHA-256 mismatch for $ARCHIVE_NAME" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL" >&2
    exit 1
  fi
  echo "Verified SHA-256 for $ARCHIVE_NAME ($ACTUAL)"
}

detect_platform

if [ "$VERSION" = "latest" ]; then
  DL_BASE="${BASE_URL}/latest/download"
else
  case "$VERSION" in
    v*) TAG="$VERSION" ;;
    *)  TAG="v$VERSION" ;;
  esac
  DL_BASE="${BASE_URL}/download/${TAG}"
fi

CLI_ARCHIVE="mbui-cli-${TARGET}.tar.gz"
RUNTIME_ARCHIVE="mbui-runtime-${TARGET}.tar.gz"
SUMS_URL="${DL_BASE}/SHA256SUMS"
CLI_URL="${DL_BASE}/${CLI_ARCHIVE}"
RUNTIME_URL="${DL_BASE}/${RUNTIME_ARCHIVE}"

BIN_DIR="${PREFIX}/bin"
RUNTIME_DIR="${PREFIX}/share/ui/runtime"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "ui.monoid installer — dry run"
  echo "  platform:    ${TARGET}"
  echo "  version:     ${VERSION}"
  echo "  prefix:      ${PREFIX}"
  echo "  bin dir:     ${BIN_DIR}"
  echo "  checksums:   ${SUMS_URL}"
  echo "  cli archive: ${CLI_URL}"
  if [ "$INSTALL_RUNTIME" -eq 1 ]; then
    echo "  runtime dir: ${RUNTIME_DIR}"
    echo "  runtime url: ${RUNTIME_URL}"
  else
    echo "  runtime:     skipped (--no-runtime)"
  fi
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "install.sh: curl is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "install.sh: tar is required" >&2; exit 1; }

TMPDIR_PATH=$(mktemp -d 2>/dev/null || mktemp -d -t mbui-install)
cleanup() {
  rm -rf "$TMPDIR_PATH"
}
trap cleanup EXIT INT TERM

echo "Downloading SHA256SUMS from ${SUMS_URL}..."
curl -fsSL --retry 3 -o "$TMPDIR_PATH/SHA256SUMS" "$SUMS_URL"

echo "Downloading ${CLI_ARCHIVE}..."
curl -fsSL --retry 3 -o "$TMPDIR_PATH/$CLI_ARCHIVE" "$CLI_URL"
verify_sha256 "$TMPDIR_PATH/$CLI_ARCHIVE" "$CLI_ARCHIVE" "$TMPDIR_PATH/SHA256SUMS"

mkdir -p "$BIN_DIR"
tar -xzf "$TMPDIR_PATH/$CLI_ARCHIVE" -C "$BIN_DIR"
if [ -f "$BIN_DIR/ui" ]; then chmod +x "$BIN_DIR/ui"; elif [ -f "$BIN_DIR/mbui" ]; then mv "$BIN_DIR/mbui" "$BIN_DIR/ui" && chmod +x "$BIN_DIR/ui"; fi

if [ "$INSTALL_RUNTIME" -eq 1 ]; then
  echo "Downloading ${RUNTIME_ARCHIVE}..."
  curl -fsSL --retry 3 -o "$TMPDIR_PATH/$RUNTIME_ARCHIVE" "$RUNTIME_URL"
  verify_sha256 "$TMPDIR_PATH/$RUNTIME_ARCHIVE" "$RUNTIME_ARCHIVE" "$TMPDIR_PATH/SHA256SUMS"
  mkdir -p "$RUNTIME_DIR"
  tar -xzf "$TMPDIR_PATH/$RUNTIME_ARCHIVE" -C "$RUNTIME_DIR"
fi

echo ""
echo "Installed ui to ${BIN_DIR}/ui"
if [ "$INSTALL_RUNTIME" -eq 1 ]; then
  echo "Installed prebuilt ui.monoid runtime to ${RUNTIME_DIR}"
fi
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *)
    echo "Add ${BIN_DIR} to your PATH:"
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
    ;;
esac
echo "Verify with: ui version"
