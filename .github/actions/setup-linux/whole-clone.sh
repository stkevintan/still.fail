#!/bin/sh
# The checkout kept on ci-1 (each runner's _work, kept between jobs) made whole again where an earlier job left it a
# partial clone (a checkout with `filter: blob:none` sets remote.origin.promisor and partialclonefilter, and they stay):
# a later job's checkout with no filter then fetched each missing blob as git came to it, one HTTPS request at a time and
# never tried again, and failed on one broken handshake (`gnutls_handshake() failed`, 2026-11-16). Run in the job's own
# checkout (setup-linux, after it), where no other job writes: from outside, a runner's next checkout races it.
#   - no promisor pack left (its objects all here): the settings alone taken out, at once;
#   - promisor packs: the packs of ci-1's whole clone (~/stillfail-ci/monoid-full.git, kept apart from any runner's
#     _work, which is bind-mounted onto /home/runner/work) put into objects/pack (`git repack -a` while promisor packs
#     exist skips promised objects in alternates), what it lacks of this checkout's fetched, then the settings and the
#     promisor marks taken out once nothing is missing. Once; a checkout already whole costs a `git config` read.
set -u
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 0
G=$(git rev-parse --absolute-git-dir)
[ ! -f "$G/shallow" ] || exit 0
whole() {
  git config --local --unset-all remote.origin.promisor 2>/dev/null || true
  git config --local --unset-all remote.origin.partialclonefilter 2>/dev/null || true
  git config --local --unset-all extensions.partialclone 2>/dev/null || true
}
# Collapse duplicate packfiles left by earlier shallow/unshallow cycles once no promisor pack remains.
repack_many() {
  [ -z "$(find "$G/objects/pack" -maxdepth 1 -name '*.promisor' 2>/dev/null | head -1)" ] || return 0
  packs=$(find "$G/objects/pack" -maxdepth 1 -name 'pack-*.pack' 2>/dev/null | wc -l | tr -d ' ')
  [ "${packs:-0}" -gt 50 ] || return 0
  rt0=$(date +%s)
  if git repack -adq --threads=4 && git prune-packed -q; then
    echo "whole-clone: repacked $packs packs in $(( $(date +%s) - rt0 )) s"
  fi
}
if [ "$(git config --local --get remote.origin.promisor 2>/dev/null)" != true ]; then
  repack_many
  exit 0
fi
if [ -z "$(find "$G/objects/pack" -maxdepth 1 -name '*.promisor' 2>/dev/null | head -1)" ]; then
  whole
  repack_many
  echo "whole-clone: no promisor pack; the partial clone's settings taken out"
  exit 0
fi
full=$HOME/stillfail-ci/monoid-full.git
[ -d "$full/objects/pack" ] || { echo "whole-clone: a partial clone, and no $full to make it whole from"; exit 0; }
t0=$(date +%s)
# (the refs the jobs use alone: other branches' history is what was never fetched whole)
head=$(git symbolic-ref -q HEAD || true)
git for-each-ref --format='%(refname)' refs/remotes refs/heads refs/tags | while read -r r; do
  [ "$r" = refs/remotes/origin/main ] || [ "$r" = "$head" ] || git update-ref -d "$r"
done
# (reflogs name what the refs taken out had; their history is as partial)
git reflog expire --expire=now --all
mkdir -p "$G/objects/pack"
copied=""
for p in "$full"/objects/pack/pack-*; do
  [ -f "$p" ] || continue
  dst="$G/objects/pack/${p##*/}"
  [ -f "$dst" ] && continue
  # shellcheck disable=SC2086 # pack file paths have no spaces
  ln "$p" "$dst" 2>/dev/null || cp -p "$p" "$dst" || { rm -f $copied; exit 1; }
  copied="$copied $dst"
done
missing() { git rev-list --objects --missing=print --all HEAD 2>/dev/null | sed -n 's/^?//p'; }
m=$(missing)
if [ -n "$m" ]; then
  # shellcheck disable=SC2086 # pack file paths have no spaces
  printf '%s\n' "$m" | git -c fetch.negotiationAlgorithm=noop fetch -q --no-tags --no-write-fetch-head --stdin origin || { rm -f $copied; exit 1; }
fi
n=$(missing | wc -l | tr -d ' ')
# shellcheck disable=SC2086 # pack file paths have no spaces
[ "$n" = 0 ] || { rm -f $copied; echo "whole-clone: $n objects still missing; left a partial clone"; exit 1; }
rm -f "$G"/objects/pack/*.promisor
whole
repack_many
echo "whole-clone: made whole in $(( $(date +%s) - t0 )) s ($(echo "$m" | grep -c . || true) fetched)"
