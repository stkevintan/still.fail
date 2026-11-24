#!/bin/sh
# What the directories hold, as a key (16 hex digits): their files' names, sizes and modification times (the CI caches
# saved by it, .github/workflows/preview.yml: one holding what the restored one held is not saved again).
#   sh apps/mbui/scripts/held.sh DIR…
# Not their contents: what is given is MBC_STORE (a unit's directory named by its command, compiler and source, written
# whole by a rename) and HBC_CACHE (core.hbc named by what it is made of), whose files are not changed in place, and
# reading all of macos-26's 300 MB of units took 6-8 s of the Mac app's job. The time too: mbc writes a unit again under
# the same name when its headers changed (its deps), which may leave the sizes as they were; the Actions cache, rsync -a
# and mv keep a file's time, so only a file written again moves it. (perl's stat, as moon-mtimes.sh's: the same on
# macOS, Linux and Windows' Git Bash; sha256sum where there is no shasum: Windows' Git Bash, 41292344719)
if command -v shasum > /dev/null; then sum() { shasum -a 256; }; else sum() { sha256sum; }; fi
find "$@" -type f ! -name "*.lock" 2>/dev/null | LC_ALL=C sort \
  | perl -ne 'chomp; my @s = stat($_); print "$_\t", ($s[7] // 0), "\t", ($s[9] // 0), "\n"' | sum | cut -c1-16
