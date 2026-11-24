#!/bin/sh
# The Node a station runs on (.node-version's), for PLATFORM, as the releases keep it apart from the station's own
# (cloud/src/install.ts gets it once per version, when the machine lacks it): DIR/node/node-v<version>-<platform>.tar.gz
# (bin/node and its LICENSE, as nodejs.org builds them, checked against its SHASUMS256) and its .sha256.
#   node-dist.sh DIR [darwin-arm64|linux-x64|linux-arm64|win32-x64]   prints the tarball's path
# win32-x64: nodejs.org's own node-v<version>-win-x64.zip as it is (checked the same way), which install.ps1
# (cloud/src/install-windows.ts) takes node.exe out of.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: node-dist.sh DIR [PLATFORM]}
platform=${2:-darwin-arm64}
version=$(cat "$root/.node-version")
cache="${STATION_TS_TARGET_DIR:-$HOME/Library/Caches/stillfail-build/station-ts}/node"
mkdir -p "$cache" "$out/node"
# Run for several platforms side by side (scripts/release.sh) into one cache: each download, checksum list and unpacked
# directory is written under a name of this process's own and moved into place whole, so one never reads another's
# half-written file. sums FILE NAME: FILE checked against nodejs.org's SHASUMS256 for NAME.
sums() {
  list="$cache/SHASUMS256-$version.$$.txt"
  curl -fsSL --retry 5 --retry-all-errors "https://nodejs.org/dist/v$version/SHASUMS256.txt" -o "$list"
  want=$(grep " $2\$" "$list" | cut -d' ' -f1)
  rm -f "$list"
  got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] || { rm -f "$1"; echo "$2: checksum does not match" >&2; exit 1; }
}
if [ "$platform" = win32-x64 ]; then
  zip="node-v$version-win-x64.zip"
  if [ ! -f "$cache/$zip" ]; then
    curl -fsSL --retry 5 --retry-all-errors "https://nodejs.org/dist/v$version/$zip" -o "$cache/$zip.part.$$"
    sums "$cache/$zip.part.$$" "$zip"
    mv "$cache/$zip.part.$$" "$cache/$zip"
  fi
  cp "$cache/$zip" "$out/node/$zip"
  shasum -a 256 "$out/node/$zip" | cut -d' ' -f1 > "$out/node/$zip.sha256"
  echo "$out/node/$zip"
  exit 0
fi
dist="node-v$version-$platform"
if [ ! -x "$cache/$dist/bin/node" ]; then
  curl -fsSL --retry 5 --retry-all-errors "https://nodejs.org/dist/v$version/$dist.tar.gz" -o "$cache/$dist.tar.gz.part.$$"
  sums "$cache/$dist.tar.gz.part.$$" "$dist.tar.gz"
  # (bin/node and its LICENSE alone, what the package below holds: not the thousands of files of npm and the headers)
  tmp="$cache/$dist.tmp.$$"
  rm -rf "$tmp" && mkdir -p "$tmp"
  tar -xzf "$cache/$dist.tar.gz.part.$$" -C "$tmp" "$dist/bin/node" "$dist/LICENSE"
  rm -f "$cache/$dist.tar.gz.part.$$"
  if [ -d "$cache/$dist" ]; then rm -rf "$tmp"; else mv "$tmp/$dist" "$cache/$dist" 2>/dev/null || true; rm -rf "$tmp"; fi
  [ -x "$cache/$dist/bin/node" ] || { echo "$dist: bin/node not unpacked" >&2; exit 1; }
fi
# The package made once per version and kept beside it (gzip of a 40 MB bin/node, seconds each time): copied as it is.
packed="$cache/packed-$dist.tar.gz"
if [ ! -f "$packed" ] || [ ! -f "$packed.sha256" ]; then
  tar -czf "$packed.$$" -C "$cache/$dist" bin/node LICENSE
  shasum -a 256 "$packed.$$" | cut -d' ' -f1 > "$packed.sha256.$$"
  mv "$packed.$$" "$packed" && mv "$packed.sha256.$$" "$packed.sha256"
fi
file="$out/node/$dist.tar.gz"
cp "$packed" "$file"
cp "$packed.sha256" "$file.sha256"
echo "$file"
