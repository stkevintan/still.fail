#!/usr/bin/env bash
# Deepen a normal shallow checkout with commit and tree objects only. Its HEAD blobs are already local, so checkout
# never has to fetch them through Git's unbounded promisor path.
set -euo pipefail
refs=("HEAD")
for r in "$@"; do refs+=("+refs/heads/$r:refs/remotes/origin/$r"); done
for i in 1 2 3; do
  shallow=()
  [ ! -f "$(git rev-parse --git-dir)/shallow" ] || shallow=(--unshallow)
  # Bash 3.2 with nounset treats an empty array expansion as unbound.
  if git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=20 fetch -q ${shallow[@]+"${shallow[@]}"} --filter=blob:none --no-tags origin "${refs[@]}"; then
    exit 0
  fi
  [ "$i" -lt 3 ] || exit 1
  sleep $((i * 2))
done
