#!/usr/bin/env bash
# Which parts a change deploys and which checks it runs (pipeline.yml's plan): the paths it changed on stdin, one a
# line; `range` (all: every file, as when there is no deployed/beta) and GITHUB_REF, GITHUB_EVENT_NAME from the
# environment. Prints key=value lines (GITHUB_OUTPUT's). scripts/plan-covers.ts checks, path by path, that every file a
# deployed part is built from deploys it (sourced with PLAN_SOURCE=1: `decide` for `changed`, one path).
set -eu

# Whether a changed path matches $1 (and, has_but, not $2). One path (plan-covers.ts asks of thousands one at a time)
# is matched in the shell, many with grep.
has() {
  if [[ $changed != *$'\n'* ]]; then [[ $changed =~ $1 ]]; else printf '%s\n' "$changed" | grep -qE "$1"; fi
}
has_but() {
  if [[ $changed != *$'\n'* ]]; then [[ $changed =~ $1 ]] && ! [[ $changed =~ $2 ]]; else printf '%s\n' "$changed" | grep -E "$1" | grep -qvE "$2"; fi
}

decide() {
  # The agents' rules (AGENTS.md, CLAUDE.md) are built into nothing, and kept true by small changes of their own: one
  # deploys and releases nothing (client/core-ts/AGENTS.md alone put out the web, the admin and three apps' betas, by
  # its directory). scripts/plan-covers.ts holds it.
  # (the right side reads the caller's `changed`: it is expanded before the local one is made)
  local changed="$(printf '%s\n' "$changed" | grep -vE '(^|/)(AGENTS|CLAUDE)\.md$' || true)"
  # Part by part.
  static=()
  # A reviewed stable release gets a fresh, pinned web artifact even when only its notes changed.
  if has '^docs/releases/'; then static+=(web-beta); fi
  # (the app's page, each of the web app's pages: the app and mbui's web host built into it, apps/mbui/scripts/web-app.sh;
  # the Worker that serves them, cloud/src/web.ts)
  if has '^(web/|client/|libs/mesh-transport/|rules/js/|shared/(release-keys|moved-from|station-busy)\.ts$|apps/mbui/(src|assets)/|libs/ui/(src|web)/|package\.json$|pnpm-lock\.yaml$|cloud/(deploy\.py|build-static\.ts|wrangler\.web-beta\.jsonc|src/(web|compat)\.ts)$|apps/mbui/scripts/web-app\.sh$|libs/ui/scripts/web\.sh$)' && [ ${#static[@]} = 0 ]; then static+=(web-beta); fi
  if has '^(web/|client/|rules/js/|shared/(release-keys|moved-from|station-busy)\.ts$|package\.json$|pnpm-lock\.yaml$|cloud/(deploy\.py|build-static\.ts|wrangler\.admin\.jsonc)$)'; then static+=(admin); fi
  if has '^cloud/(src/preview\.ts|build-static\.ts|wrangler\.preview\.jsonc)$'; then static+=(preview); fi
  # (the official site, website/, with the legal pages it serves from web/public)
  if has_but '^website/' '^website/ui/' || has '^(web/public/((en/)?(terms|privacy|trademark|support)\.html|legal\.css|favicon-beta\.svg|favicon-beta-32\.png|apple-touch-icon-beta\.png)$|cloud/wrangler\.site-beta\.jsonc$)'; then static+=(site-beta); fi
  if has '^cloud/(status/|wrangler\.status\.jsonc$)'; then static+=(status); fi
  api=false
  if has_but '^cloud/(src/|wrangler\.jsonc$|package\.json$|deploy\.py$)' '^cloud/src/(relay|relay-worker|preview)\.ts$'; then api=true; fi
  # (and what cloud/src takes from outside cloud/: the lock's rules through shared/lock.ts, how the station keeps
  # a lock's forks, the client's words and limits; none of them deployed it, so a change to the rules alone reached no
  # cloud, 2026-11-05)
  if has '^(rules/js/|shared/(lock|log-keep|rules-runtime)\.ts$|client/(i18n/|limits\.ts$|core-ts/src/(picture-relay|lock-form|plain)\.ts$))'; then api=true; fi
  relay=false
  if has '^cloud/(src/(relay|relay-worker|limits|auth)\.ts|Dockerfile|relay-entrypoint\.sh|wrangler\.relay\.jsonc)$'; then relay=true; fi
  station=false
  # The station in TypeScript, its native parts (vendor/: the mesh addon's iroh), its programs in MoonBit (station/mb: the
  # shell they link, client/shell, the base's packages they take, libs/base, and mbui's effect), the rules it checks the lock and
  # vaults by (rules/js, pion/rules/js: the default engine it bundles as pion-rules/), what it shares with the core (shared/, client/core-ts/src: scripts/plan-covers.ts finds which), the words it says, the installer it carries (cloud/src/install*.ts: scripts/installers.ts), its deltas (scripts/delta.ts, delta-fast.c, release-deltas.ts).
  if has '^(station/(src|native|mb|assets)/|shared/|libs/base/(src/|moon\.mod$)|client/shell/|libs/mesh-transport/|libs/ui/src/effect/|rules/js/|pion/rules/js/|client/core-ts/src/(shapes/[^/]+|lock-form|rig-form|whitespace|titles|chat-row|cache-policy|codex-quota|mediaFacts|digest|redact|preset-records|features|model-speed)\.ts$|station/(package\.json|pnpm-lock\.yaml)$|vendor/|client/i18n/|bin/|scripts/(release|station-bundle)\.sh$|scripts/(posthog-key|native|installers|release-sign|delta|release-deltas)\.ts$|scripts/delta-fast\.c$|cloud/src/(install|install-windows|i18n)\.ts$)'; then station=true; fi
  # The beta Android app: mbui's in the Kotlin one's place (scripts/release.sh --beta android), released for a
  # change to what apps/mbui's beta is made of (scripts/beta.sh APP_SRC: its code, mbui's with its Android host's
  # Java, JZlib among it, the client's, media's, vendor's), to the tool that packs and repacks its APK (mbui's
  # tools/apk: the repacked APK is what the app's delta applier makes byte for byte), or to how it is released (its
  # deltas too). Not for the four config files the core's key ends with (apps/mbui/scripts/core.sh HBC_TREES: the
  # root's and station/'s package.json and tsconfig.json), on purpose, here and for the Mac's and Windows' below: the
  # key keeps a wrong core.hbc from being taken, this says which pushes release the apps, and those four change about
  # twice a day (station/package.json's packages) without changing the core. One that does change it ships with the
  # next release, its core made anew because the key changed.
  android_beta=false
  if has '^(apps/mbui/(src|core|android|ios|engine)/|libs/ui/(src|android)/|(apps/mbui|libs/ui)/moon\.(mod|work)$|client/|libs/mesh-transport/|rules/js/|shared/(release-keys|moved-from|station-busy)\.ts$|web/public/avatars/index\.json$|media/|vendor/|libs/ui/tools/apk/|scripts/(release\.sh|native\.ts|delta\.ts|delta-fast\.c|release-deltas\.ts)$|\.github/release\.sh$|apps/mbui/scripts/(beta|android|android-core|core)\.sh$|libs/ui/scripts/android\.sh$)'; then android_beta=true; fi
  # The beta Mac app: mbui's in the Electron one's place (scripts/release.sh --beta desktop), released, as the
  # Android one, for a change to what apps/mbui's Mac app is made of (its code, mbui's with its Mac host, the
  # client's, media's, vendor's) or to how it is built and released.
  mac_beta=false
  if has '^(apps/mbui/(src|core|engine)/|libs/ui/src/|(apps/mbui|libs/ui)/moon\.(mod|work)$|client/|libs/mesh-transport/|rules/js/|shared/(release-keys|moved-from|station-busy)\.ts$|web/public/avatars/index\.json$|media/|vendor/|scripts/(release|mac-feeds)\.sh$|scripts/(native|delta|release-deltas)\.ts$|scripts/delta-fast\.c$|\.github/(release-desktop\.sh|mac_signing\.py)$|apps/mbui/scripts/(beta|mac-app|mac|core)\.sh$|libs/ui/scripts/mac\.sh$|apps/mbui/scripts/mac-icon\.swift$)'; then mac_beta=true; fi
  # The beta Windows app: mbui's in the Electron one's place (scripts/release.sh --beta desktop-win), released, as
  # the Mac one, for a change to what apps/mbui's Windows app is made of (its code, mbui's with its Windows host,
  # its installer, the client's, media's, vendor's) or to how it is built and released.
  win_beta=false
  if has '^(apps/mbui/(src|core|engine|windows)/|libs/ui/src/|(apps/mbui|libs/ui)/moon\.(mod|work)$|client/|libs/mesh-transport/|rules/js/|shared/(release-keys|moved-from|station-busy)\.ts$|web/public/avatars/index\.json$|media/|vendor/|scripts/(release|win-feeds)\.sh$|scripts/(native|delta|release-deltas|release-sign)\.ts$|scripts/delta-fast\.c$|apps/mbui/scripts/(win|core)\.sh$|libs/ui/scripts/win\.sh$|apps/mbui/scripts/mac-icon\.swift$)'; then win_beta=true; fi
  # The mbui app's Windows shell and engine, prebuilt: fetched and the shell's tests run (windows-natives), for a
  # change to what they are made of.
  windows_natives=false
  if has '^(client/shell/|libs/mesh-transport/|client/Cargo\.(toml|lock)$|vendor/|apps/mbui/engine/|scripts/native\.ts$)'; then windows_natives=true; fi
  # The launcher's tests on Windows (launcher-windows: its own code there, a renew under stillfail-station-w), for a
  # change to it, to the Windows installer that hands over through it, or to CI's own files.
  launcher_windows=false
  if has '^(station/native/launcher/|cloud/src/install-windows\.ts$)' || has_but '^\.github/' '^\.github/workflows/(mbui-|preview\.yml$|cache-prune\.yml$|side\.yml$)'; then launcher_windows=true; fi
  # The component library's page (apps/mbui/scripts/kit-web.sh, monoid's alone: cloud/wrangler.kit.jsonc), built by
  # mbui-web and deployed by monoid-kit, for a change to what it is made of (the app's code and mbui's, mbui's web host)
  # or to how it is built and served.
  kit=false
  if has '^(apps/mbui/(src|assets)/|libs/ui/(src|web)/|(apps/mbui|libs/ui)/moon\.(mod|work)$|apps/mbui/scripts/(kit-web\.sh|kit\.html|web\.sh|env\.sh|mbui\.sh|assets)$|libs/ui/scripts/(web|env)\.sh$|apps/mbui/tools/assets/|cloud/(deploy\.py|wrangler\.kit\.jsonc)$)'; then kit=true; fi
  # The ui.monoid.build site & docs (website/ui/build.mjs, monoid's alone: cloud/wrangler.ui.jsonc), built by
  # mbui-ui and deployed by monoid-ui, for a change to its pages/assets, the embeds it builds, or how it is served.
  ui=false
  if has '^(website/ui/|apps/mbui/(src|assets)/|libs/ui/(src|web)/|(apps/mbui|libs/ui)/moon\.(mod|work)$|apps/mbui/scripts/(kit-web\.sh|kit\.html|web\.sh|env\.sh|mbui\.sh|assets)$|libs/ui/scripts/(web|env)\.sh$|apps/mbui/tools/assets/|cloud/(deploy\.py|wrangler\.ui\.jsonc)$)'; then ui=true; fi
  # The mbui app's own tests (check-mbui, mbui-check.yml; main's run there on their own): for a change to it, to mbui
  # (libs/ui), or to its component library (libs/ui).
  mbui=false
  if has '^(apps/mbui|libs/ui)/' || has '^\.github/workflows/mbui-check\.yml$'; then mbui=true; fi
  # Comma's parts' module's check (check-comma-ui: libs/comma-ui/scripts/check.sh): for a change to it, or to mbui, which
  # it is built on.
  comma_ui=false
  if has '^libs/(comma-ui|ui)/'; then comma_ui=true; fi
  # still.fail's component library's check (check-sf-ui: libs/ui/scripts/check-controls.sh): for a change to it, or to mbui,
  # which it is built on.
  sf_ui=false
  if has '^libs/ui/'; then sf_ui=true; fi
  # The station's tests (check-station: scripts/check.sh's station-tests, in slices on Linux runners): for a change to
  # what they read, as check.sh says it (its station_paths, read from there: said once), to the check itself, or to
  # CI's own files (which make every check run whole: pipeline.yml).
  station_tests=false
  station_paths=$(sed -n "s/^ *station_paths='\(.*\)'\$/\1/p" "$(dirname "${BASH_SOURCE[0]}")/check.sh")
  [ -n "$station_paths" ] || { echo "scripts/plan.sh: no station_paths in scripts/check.sh" >&2; exit 1; }
  if has "$station_paths" || has '^scripts/check\.sh$' || has_but '^\.github/' '^\.github/workflows/(mbui-|preview\.yml$|cache-prune\.yml$|side\.yml$)'; then station_tests=true; fi
  # The core's tests (check-core: scripts/check.sh's core-tests, in slices on Linux runners): for a change to what
  # they read, as check.sh says it (its core_test_paths, read from there), to the check itself, or to CI's own files.
  core_tests=false
  core_test_paths=$(sed -n "s/^ *core_test_paths='\(.*\)'\$/\1/p" "$(dirname "${BASH_SOURCE[0]}")/check.sh")
  [ -n "$core_test_paths" ] || { echo "scripts/plan.sh: no core_test_paths in scripts/check.sh" >&2; exit 1; }
  if has "$core_test_paths" || has '^scripts/check\.sh$' || has_but '^\.github/' '^\.github/workflows/(mbui-|preview\.yml$|cache-prune\.yml$|side\.yml$)'; then core_tests=true; fi
  # Exercise the GitHub-hosted web and Mac release paths, without secrets or publishing, when their CI changes.
  release_smoke=false
  if [ "${GITHUB_REF:-}" != refs/heads/main ] && { [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] || has '^(\.github/workflows/pipeline\.yml$|\.github/deploy\.sh$|\.github/actions/(setup|natives|mbui-moonbit)/|scripts/release\.sh$)'; }; then release_smoke=true; fi
  # The checks only a Mac can run (check-mac: Swift's still.fail Helper, the iOS crash reports' Objective-C test, the
  # Mac release prebuild's Mach-O symbol check, and the launcher's tests on macOS, whose own code there finds a front
  # left from before by proc_listpids and KERN_PROCARGS2; `check` runs them on Linux): only when one of them or CI's
  # own files changed.
  check_mac=false
  if has '^(station/native/helper/|station/native/launcher/|vendor/(PermissionFlow|serve-sim)/|apps/mbui/(src/host/apple_reports\.m|scripts/ios[_-]reports)|\.github/(mac-release-prebuild|test_mac_release_prebuild)\.sh$|(apps/mbui|libs/ui)/scripts/mac\.sh$)' || has_but '^\.github/' '^\.github/workflows/(mbui-|preview\.yml$|cache-prune\.yml$|side\.yml$)'; then check_mac=true; fi
  # Whether `check` tests the native parts' Rust (scripts/check.sh's cargo tests: the station's launcher, runner, mesh
  # and screen, the mesh transport, the client's shells), on ci-1, whose sccache keeps their builds short: only when
  # that Rust, what it vendors or ci-1's own setup changed. Otherwise check runs on GitHub's runners without them
  # (STILLFAIL_SKIP_RUST_TESTS), and needs no ci-1 to be up.
  check_rust=false
  if has '^(station/native/(launcher|runner|mesh|screen|screen-linux)/|libs/mesh-transport/|client/(shell|iroh-wasm)/|client/Cargo\.(toml|lock)$|vendor/|\.github/actions/setup-(linux|mac)/)'; then check_rust=true; fi
}

print() {
  {
    echo "range=$range"
    echo "parts=${static[*]}"
    echo "static=$([ ${#static[@]} -gt 0 ] && echo true || echo false)"
    echo "api=$api"
    echo "relay=$relay"
    echo "station=$station"
    echo "android_beta=$android_beta"
    echo "mac_beta=$mac_beta"
    echo "win_beta=$win_beta"
    echo "windows_natives=$windows_natives"
    echo "launcher_windows=$launcher_windows"
    echo "kit=$kit"
    echo "ui=$ui"
    echo "mbui=$mbui"
    echo "comma_ui=$comma_ui"
    echo "sf_ui=$sf_ui"
    echo "station_tests=$station_tests"
    echo "core_tests=$core_tests"
    echo "release_smoke=$release_smoke"
    echo "check_mac=$check_mac"
    echo "check_rust=$check_rust"
  }
}

if [ -z "${PLAN_SOURCE:-}" ]; then
  changed=$(cat)
  range=${range:-}
  decide
  print
fi
