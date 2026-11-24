#!/bin/sh
# The Node the station runs on (.node-version), on this machine: ~/.local/node-v<version>-<platform>, got from
# nodejs.org once (checked against its SHASUMS256) when it is not there. Prints its bin directory, for PATH: what the
# Macs that build and check (the CI Mac's runners: .github/actions/setup-mac; a test Mac) run what they run on.
#   node-here.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(cat "$root/.node-version")
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  Linux-aarch64|Linux-arm64) platform=linux-arm64 ;;
  *) echo "no Node build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
dist="node-v$version-$platform"
home="$HOME/.local/$dist"
if [ ! -x "$home/bin/node" ]; then
  mkdir -p "$HOME/.local"
  tmp=$(mktemp -d "$HOME/.local/.node.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  direct_ip=
  if [ -n "${STILLFAIL_DIRECT_DNS:-}" ] && command -v dig > /dev/null 2>&1; then
    direct_ip=$(dig +short +time=3 +tries=2 @"$STILLFAIL_DIRECT_DNS" nodejs.org A 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || direct_ip=
  fi
  fetch_node() {
    if [ -n "$direct_ip" ]; then
      if curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 20 --retry 2 --retry-all-errors \
        --resolve "nodejs.org:443:$direct_ip" "$@"; then
        return 0
      fi
    fi
    curl -fsSL --retry 5 --retry-all-errors "$@"
  }
  fetch_node "https://nodejs.org/dist/v$version/$dist.tar.gz" -o "$tmp/$dist.tar.gz"
  want=$(fetch_node "https://nodejs.org/dist/v$version/SHASUMS256.txt" | grep " $dist.tar.gz\$" | cut -d' ' -f1)
  got=$({ shasum -a 256 "$tmp/$dist.tar.gz" 2>/dev/null || sha256sum "$tmp/$dist.tar.gz"; } | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] || { echo "$dist.tar.gz: checksum does not match" >&2; exit 1; }
  tar -xzf "$tmp/$dist.tar.gz" -C "$tmp"
  # Another runner may have put it there meanwhile: the first one stays.
  mv "$tmp/$dist" "$home" 2>/dev/null || true
fi
echo "$home/bin"
