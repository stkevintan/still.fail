# Working on CI (for agents)

- `workflows/pipeline.yml` is the one for pushes: its plan (`scripts/plan.sh`) decides from the paths changed which
  checks run and, on main, what is deployed (the beta of each part); `scripts/plan-covers.ts` checks that every file a
  deployed part is built from deploys it. `contributions` runs forks' pull requests on GitHub's runners with no
  secrets; never give pipeline a fork's trigger.
- A pull request merges once its own checks passed (`gh pr merge --squash`), no queue before it. What a branch's
  pushes leave out, the mbui app's tests and mbui's own at 120, 60, 24 and 7 frames a second, runs on main after the
  merge (`workflows/mbui-check.yml`, `workflows/mbui-ci.yml`; the user, 2026-11-11 15:51 UTC: 「直接合，帧率在 main 上合并后
  跑」); a branch runs at 120, 60 and 24 only the test files it changed of sfapp and of the small packages (sfpages, settings,
  gallery, player, sfgraphic) (`rates-changed`; the user, 2026-11-14:
  「PR 上也跑改到文件的帧率检查」, after four pull requests' own changed tests went red at a rate on main). Red on main
  holds no one back and is mended forward by whoever brought it, never rolled back: the run's
  `rates-said` says what merged since the last run that went through, the likeliest first (`scripts/rates-said.sh`).
- Every job says `timeout-minutes`, 5 at most, except the limits listed in `scripts/ci-timeouts.py`'s `LONGER`.
  Those allow 10 minutes, except `prebuild.yml`'s `build` job, which allows 15. Cold Windows shell builds take around
  540 seconds and can exceed 10 minutes with setup and packaging. Other jobs that need longer are made faster,
  never finished over several pushes or reruns: a branch's
  mbui-check run cut before its programs were all built keeps none of the units it compiled (test.sh's
  `MBUI_BUILT_MARK`), and main's store keeps what its runs used for three hours. Minutes are whole (the runner cut a
  step's 3.8 at 3): a step that
  must end some seconds before its job, for the caches saved after it, runs under `scripts/with-timeout.sh`
  `@$((JOB_END - 35))` (by what follows it: mbui-check's 25, its app build's 35 on a branch and 25 on main, its replay build's 65 on main and 45 on a branch), JOB_END written by the
  job's first step, less its 5 s of setting up (preview's ios 8). The units' stores of GitHub's Linux images are keyed by
  their compiler (`IMG`, `cc` and 12 hex digits of clang, its `--version` and the C standard headers it preprocesses,
  not `linux-libc-dev`'s version, which moves weekly with the kernel), its Mac's
  by its `ImageVersion`: two compilers in turn kept only the last run's units in one, and four `ubuntu-24.04` images
  of one clang and libc, each its own store, left a push's image's units hours behind main's.
- No paid runners (GitHub's larger ones): horizontal Linux test slices (`check-station`, `check-core`, and `mbui-check`
  unless `vars.CI_1_MBUI == 'on'`) and small deploy jobs run on GitHub's standard elastic runners; non-Apple `natives`
  (any `ci-1` runner; a branch's Windows reader in `natives-win-reader`, one concurrency group there, each cold reader
  at -O2 a job's five minutes' worth when they shared the cores; main's in `natives-win-reader-main`, which `needs`
  natives: taking the group first, it held natives and every job waiting for the readers), `natives-main` and cross-platform
  `side` parts run on `ci-1` (`linux-ci`, `linux-quick`, a 16-core Linux machine; `vars.CI_1 = 'off'` falls back to
  `macos-ci` for the non-Apple parts, `natives-mac` building the Apple ones all the same), unloading `Mini1`. Every `natives*` job builds only what plan found missing (`missing_list`,
  `missing_win_list`, `missing_mac_list`, `missing_mac_reader_list`, `missing_harness_list`). On
  `ci-1` the readers keep `mbc`'s 768 KB package units and `MBC_DATA_LAYOUTS` (never `MBC_INIT_SPLIT=0`, which turns
  the layouts off, so that a changed type compiles all of `moonbit_init` again). A branch missing only
  `reader:linux-x64` builds `natives` on `ubuntu-24.04`, and `natives-win-reader` there whenever `shell-station` is
  published (plan's `natives_runner`, `natives_win_runner`), side by side, with no `natives-main`: on GitHub's runners
  a branch's reader's C is compiled at -O0 in units of 8 MB with `moonbit_init` one unit on every core
  (`MBC_UNIT_KB=8192 MBC_INIT_SPLIT=0`, cold in 71 s where 2 MB's took 105; zig cc's UBSan off), its units kept in the
  Actions cache by branch keys of their own (`mbui-reader-linux-branch-v2-`, `-win-branch-v2-`, `-mac-branch-v2-`,
  apart from main's -O2 `mbui-reader-mac-`), which a branch's first push cannot read (a branch sees only main's
  caches). Main's moon build of the reader is not kept for branches: moon builds all of it again in another checkout
  path or `MOON_HOME`, and one line changed in `station/mb/src/reader` took as long as cold; `check` runs there only when
  the Rust it tests changed (`scripts/plan.sh`'s `check_rust`: ci-1's sccache keeps those builds short), otherwise on
  `ubuntu-24.04` with them left out (`STILLFAIL_SKIP_RUST_TESTS`), so a pull request's check needs no `ci-1` (with its
  line down every one queued until cancelled, 44383403135); a branch's `check-mac`
  runs on GitHub's `macos-26` (main's too with `vars.MINI1 = 'off'`), and a branch plans `natives-mac` only when a job
  of its uses the Apple parts (`check-mac`, `mac-build`, `desktop-build`), on `macos-26` too unless `mesh` or
  `shell-apple` is missing, and the Mac's reader in `natives-mac-reader` only for `check-mac` and `mac-build`, on
  Mini1 (cold builds of the first two there took 228 and 323 s before packing, the
  reader's 248-260 s at -O0 and its branch units evicted within 17 minutes: on Mini1 its `MBC_STORE` stays on disk; with
  `vars.MINI1 = 'off'` a branch's reader compiles on `macos-26` at -O0); the other Apple parts,
  Xcode/Simulator checks (`side-mac`, iOS/macOS builds), Android's release and main's `station-update` stay on `Mini1`
  (`macos-ci`, `quick`; `vars.MINI1 = 'off'` leaves `station-update` out), the
  Mac app's and the station's release signing on `macos-26` (`desktop`, `station`: their uploads over Mini1's home line
  were cut at five minutes, 2026-11-17), and
  a branch's `natives-mac-main` runs only with `vars.MINI1 = 'on'`. The tests' MoonBit program (`reader-harness`, which
  `check-station` and `check-core` run) builds in `natives-harness` alone, never in `natives`' list or `natives-main`, on
  `ubuntu-24.04` at -O0 wherever `shell-station` is published, main's too: a concurrency group pends one job and cancels
  the one pending before it, so the readers' group on `ci-1` takes no third. Runners on one
  self-hosted machine share its cores and queue bursts of multi-job workflows, so keep bursty multi-job PR builds and
  parallel real-time test slices on GitHub's separate VMs rather than stacking them on one host.
- A job that needs another job's output says that job's result in its `if:` (`contains(fromJSON('["success","skipped"]'),
  needs.natives.result)`): one cut at its `timeout-minutes` is `cancelled`, not `failure`, and the run is not
  cancelled, so `!cancelled() && !failure()` alone ran nine jobs without the readers (main 44466921858).
- A check that failed and passed on the same commit is never rerun green (the root AGENTS.md): a branch's `gate`, in a
  run attempted again, fails unless every job that failed or was cancelled before failed for GitHub's or the network's
  sake (`scripts/gate-rerun-check.mjs`). The gate also allows a job stopped only by `native.ts`'s exact missing-prebuild
  diagnostic, with no other failure: its build or test never started. Supplying the artifact lets that work start.
  Do not rerun an old commit's main pipeline: it deploys that commit's beta over
  the newer one.
- An artifact uploaded for people to look at (pictures, logs, what moved) says `continue-on-error: true`: a runner's
  connection to GitHub's artifact service reset fails a check that had passed (main acb00686, 2026-11-01; #5157's
  `offscreen`, 2026-11-10). One a later job downloads does not: there the upload's failure is the job's, unless that
  job is skipped without it (monoid's betas, `monoid-upload`'s outcome in the job's outputs) or does without it (mbui-size's measures and what they measure: `record` carries the one before's for a measure
  missing). mbui-size downloads what it measures by `scripts/download-artifact.sh --optional`, not
  actions/download-artifact, which once ended 0 with half a zip on the disk (43955196994, 2026-11-16): a zip is
  checked by its size and digest, a cut one taken on by Range, and the directory is there only when it came whole.
- A release's deltas (`scripts/release-deltas.ts`: the `deltas-<part>` jobs, each waiting for its own part's build
  alone, `put_feed` in `scripts/release.sh`) never fail or hold back a release: what goes wrong is a warning and that
  delta is left out, the feed whole without it. Their time is bounded by `--deadline` inside the job's own 5 minutes;
  a part that needs more is made faster, split (the station's, a job a platform: `--platform`, put's `--merge`) or gets
  fewer bases, not longer (10 bases: the owner, 2026-11-11). `deltas-desktop-win` and the station's two Linux
  platforms run on `ci-1` (`ubuntu-24.04` with `vars.CI_1 = 'off'`); the rest (`deltas-android`, its `javac`
  `ubuntu-24.04`'s JDK, `deltas-desktop` and the station's macOS and Windows platforms) on `ubuntu-24.04`: the five
  let go together queued one after another on `ci-1`'s 2 runners.
- Stable (`workflows/stable.yml`) runs from main's head against the release's older checkout: a step that needs newer
  scripts takes them from `$GITHUB_SHA` (`git show`, a sparse checkout). Its station is built into a directory and
  staged; only `station-put` puts it, packages then `station.json` seconds apart, so a run cut before leaves the channel
  as it was. Its native parts come from `station-natives-*`, which build only what neither the release
  `native-artifacts` (20 of a part, hours of main's) nor the store (`natives/`: main's `natives-store`, after its natives
  jobs; readers kept 14 days, `scripts/release-prune.ts`) has.
- `desktop-build` waits for `natives-mac` alone (it uses only the Apple parts, not the Mac's reader, which
  `natives-mac-reader` builds beside it) and `desktop` for `desktop-build` alone, never for `natives`' slower Linux build
  nor the reader's. The release's upload jobs (`deltas-*`, `desktop`, `put`, `changelog`) take Node
  alone (`.github/actions/node`; on `ci-1`, `scripts/node-here.sh`), no pnpm: `release-put.sh` and `changelog-put.sh` go through Cloudflare's API with the
  token (wrangler only without it). `release-prune` deletes old files after `put` in a job of its own, which neither
  `done` nor `station-update` waits for.
- The Mac's beta never holds back the others' (`put` runs whatever `desktop` and its build, `desktop-build`, came to): its signing waits on Apple's
  notary service, which can take a job's five minutes (2026-11-12, four runs in a row). Nor does Windows' (`desktop-win`): a new MoonBit's cold
  build was cut at its five minutes run after run and held every part's beta back (the user, 2026-11-17). Nor do the
  station's and Android's (`station`, `android`): each hands `put` only what it finished, and one cut at its upload held
  the signed Mac and Windows betas back (main 44147606865, 2026-11-17). A failed or cancelled part leaves its feed as
  it was; it is main's red, and `done` waits for it, so the next run plans it again.
- The Android delta's deflater is part of the format: JZlib's version (`libs/ui/android/jzlib`) and the level and settings
  `Delta.java` deflates with must be what every installed app carries, or what it makes no longer is the release's APK
  (each delta is checked by the Java applier before it is published, so such a change only stops Android's deltas).
