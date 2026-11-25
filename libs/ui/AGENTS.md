# Working in mbui (for agents)

Follow these owner rules yourself without waiting for PR review. CI enforces what can be checked (`libs/ui/scripts/detlint` and Tester checks). Add a check whenever you can.

Subsystem rules live in narrower `AGENTS.md` files loaded when touching those directories:

- `libs/ui/src/view/AGENTS.md`: window tree, `View::comes` motion, parking and block reuse, `scrolls_window` invariants, hover, `View::fits`, signals, one-way layout, focus, detlint guards, callsite tracing, generic shells
- `libs/ui/src/ui/AGENTS.md`: tree-only and multi-window runtime, native views/streams, a11y, FPS invariance, motion smoothness bars, idle skipping, Tester diagnostics and isolation
- `libs/ui/src/headless/AGENTS.md`: 3-layer component model, `headless.mbt` contract, `kit` deprecation
- `libs/ui/src/host/AGENTS.md`: adding host calls, between-frame delivery, Android mimalloc allocator

## Its parts

- `libs/ui/src/view`: retained window tree, made once. `libs/ui/src/ui`: legacy immediate-mode `Ctx` plus shared runtime, styles (`style.mbt`, `@ui.css`), theme, text fields, Tester, and `FakeHost`.
- `libs/ui/src/signals`: alien-signals port. `libs/ui/src/motion`: motion as data. `libs/ui/src/headless`: headless tree controls. `libs/ui/src/player`: streaming audio/video player state machine. `libs/ui/src/kit`: legacy Radix-like controls on `Ctx` (frozen).
- `libs/ui/src/flex`, `text`, `shape`, `paint`, `skia`, `svg`, `pixels`: layout and drawing. `src/hostapi` and `src/host`: host interface and platform backends. `src/effect`: Effect-TS model on the frame clock.
- `libs/ui/tools`: MoonBit build and check tools (`detlint`, `mbc`, `wasmhost`, `chk`, `wasmgas`).

## It knows no app

- mbui builds and tests independently of any app. Nothing in `libs/ui/` may name an app or reach outside this directory (detlint `app-word`, configured in `detlint.json`).
- App-specific native calls pass through `@hostapi.app_said` / `app_tell` (`libs/ui/src/host/app_calls.h`), site names via `@hostapi.set_site_name`, and app identity via build settings (`MBUI_APP_ID`, Info.plist, APK resources).

## Two views: the old one and the one made once

- Make each node once in `libs/ui/src/view` when it first shows and keep it until it leaves. Bind changing properties to signals so only changed work reruns.
- Write no new code on `Ctx`. Legacy detlint counts (`old-island`, `old-list`, `click-read`, `key-read`, `submitted-read`, `build-motion`, `layout-read-back`, `ui-current`, `build-clock`) only fall, and APIs are removed at zero.
- When migrating an old view or fixing UI in `src/view`, read the existing code logic, state, data flow, and git history first, then express it with `src/view`, `src/motion`, and `src/headless`. Never guess from rendered pictures, diff `drawn_rects()` or frame coordinates against the old view, or add per-scene framework hacks to pixel-fit an old page.
- Core tree invariants (details in `libs/ui/src/view/AGENTS.md` and `libs/ui/src/ui/AGENTS.md`):
  - Layout flows strictly one way (`View::by_room`, no `layout-told`).
  - Dynamic column/row changes animate through `View::comes`, not per-page code. Initial answers settle immediately.
  - `View::scrolls_window` owns virtualization, reading anchors, unified `bands`, and `press_stays` stability.
  - State read by bindings must be a signal (`T : Eq`), and detlint performance counts only fall.
  - Interactive tree nodes must be named for screen readers (`Tester::hold_named`), and focus (`Tree::takes_keys`) stays independent of hover (`View::pointed`).

## Components: headless, their looks apart

- Keep behavior in `libs/ui/src/headless`, visual styling in look libraries (`libs/ui`, `libs/comma-ui`), and shared tree/list mechanics in `libs/ui/src/view`. Read `libs/ui/src/headless/AGENTS.md` and `libs/ui/src/headless/headless.mbt` before adding controls.

## Time in a test is declared, never waited for

- Tests execute inputs step by step, declare the exact moment (`run_for`), and assert. Output at a moment must be identical at 60, 120, 24, 7 fps, or in one jump (`libs/ui/src/ui/AGENTS.md`).
- Skip idle time (`Tester::run_shown`), represent motion as data (no `@effect.next_frame` loops or frame counters), and enforce non-increasing smoothness bars (`MBUI_TEST_MOTION`).
- Never wait for things to settle or animations to end (`rest`, `settle`, sleeps, retries, longer timeouts). `assert_idle` and `at_rest` are assertions only. End-to-end steps wait only for external named events or state facts.

## What is seen, traced to its line

- Under a Tester, tree nodes record callsites (`libs/ui/src/view/source.mbt`, while device hosts record none). Use `Tester::audit()` for layout rules and `Tester::sources_at(x, y)` / `Tester::sources_of(words)` to trace faults to callers (`mbui/…` vs `stillfail/…`) after reading the code.
- Parts and property setters forward `#callsite(autofill(loc))` / `loc~ : SourceLoc` via `made_for=loc` (detlint `part-place`).

## Pictures come from the Tester's draw list

- Compare screens via Tester draw lists at declared moments, and verify pixels via per-host offscreen renders (`libs/ui/scripts/render_*.sh`) against host references.
- Never run screenshot diffs on devices, emulators, simulators, or desktop windows. Devices run only host contracts, render contracts, and event-driven smoke flows whose pictures are for human review (detlint `device-shot` blocks new device shots).

## A test links no host

- All host calls go through `libs/ui/src/hostapi` (`Host` closure table). Only app mains import `libs/ui/src/host` (detlint `host-import`), while Tester installs `FakeHost` (`libs/ui/src/ui/fake_host.mbt`), keeping native tests runnable on Linux CI.
- Deliver external posts and picker results between frames, never deferring to frame start (`libs/ui/src/host/AGENTS.md`). Never branch app code on whether a Tester is running (detlint `tester-branch`).
- mbui's film (`libs/ui/src/film`) links on every host. Apple (`libs/ui/src/host/apple_film.m`) and Linux (`libs/ui/src/host/linux_film.c`) film natively; every other host (Android, Windows, iOS) links `libs/ui/src/host/film_none.c` (`mbf_supported` 0). Film asks a native host only through `mbf_` calls, never a renderer's own name; a new call is written in all three in the same change (`libs/ui/scripts/film_calls.sh`, run by `libs/ui/scripts/check.sh`), so no app writes stubs of its own.

## There are no flaky failures

- A check that fails and passes on the same commit means uncontrolled nondeterminism entered the system. Never rerun it green, label it flaky, or add retries/waits: find and isolate or remove the nondeterminism.
- Never call `abort` directly: use `@halt.saying(msg)` (`abort-unsaid`). Never write `test "panic …"` (`panic-test`). Keep every test isolated (`Tester::own_read_said`, `read-before-run`, `leaked_state`, see `libs/ui/src/ui/AGENTS.md`).

## Tools are MoonBit, not Python

- Write build, CI, and check tools in MoonBit under `libs/ui/tools` (built on demand by wrapper scripts like `libs/ui/scripts/chk`) or in shell when only orchestrating commands.
- In development, run tools on wasm-gc via `libs/ui/scripts/wasmrun.mjs` without compiling C. In CI, build natively (`libs/ui/scripts/tooltarget.sh`). Route OS calls through `libs/ui/tools/sys`. Write no new Python. Rewrite existing Python scripts when they need changes.

## Arrays let go of what they held

- On native, `Array::clear`, `truncate`, `pop` and `remove` leave what they took out in the slots past the end, still counted as held. On a long-lived or pooled array of references or closures (a node's children or handlers, a tree's queues, a frame's tells, a reuse pool), follow them with `release_unused(placeholder=…)`, or `shrink_to_fit()` once it is empty, or what they held stays alive and two such arrays can hold each other in a ring.

## Before a PR

- Keep generic tree/list functions as thin shells over non-generic bodies to prevent C monomorphization bloat (`libs/ui/src/view/AGENTS.md`).
- Every compiler warning is an error or explicitly disabled (`libs/ui/moon.mod`, matching `apps/mbui/AGENTS.md` Warnings).
- Open one PR per task, squash with `git reset --soft $(git merge-base HEAD origin/main)` (never directly onto `origin/main`), and verify `git diff origin/main --stat` contains only your files.

## Controls and Liquid Glass (`src/controls`, `src/glass`)

still.fail's design system as a component library beside mbui (`libs/ui`): `src` (`ui/controls`, `@sf`) holds the parts
still.fail's app (`apps/mbui`) is made of, and `src/glass` (`ui/glass`, `@glass`) holds its liquid glass
material recipes, physics, surface decorators, and glass controls. It lived inside `apps/mbui` till it was made a
module of its own (`name = "ui"`), so that a program outside still.fail's app (a workspace of another
repository: `moon.work` naming `libs/ui`, `moon.mod` importing `"ui@0.1.0"`) uses
the parts still.fail itself ships and tests (左子健, 2026-11-17: 「感觉最好用有项目用的 UI 吧，不然都没人测」).

- It knows no app: it imports only mbui and MoonBit's core (detlint's `library-import`), and what it needs of an app
  (its words, the core's answers, its pictures) is given to it as the app starts. The rules of how its parts are made,
  look and move are the app's (`apps/mbui/AGENTS.md`: The component library, Made once as nodes, Motion) and mbui's
  (`libs/ui/AGENTS.md`): they hold here as there.
- Its tests have no core: what they ask of the core's pure calls (`markdown`, `code.ink`, `reader.*`, `ref.words`) is
  answered from what the real core answered, kept beside them (`src/controls/kept_wbtest.mbt`, `src/controls/kept_test.mbt`, each
  a copy of the lines of the app's `apps/mbui/src/sfkept/kept.mbt` these tests ask). A test that asks one more fails
  saying which (`kept-answers-ask {…}`, `scripts/check-controls.sh`): the core works it out into that file as it does the app's
  (those lines saved to a file, `node client/core-ts/scripts/kept-answers.ts <file>`), and its line is copied here.
- Some of its files are made, never edited: `src/controls/palette_data.mbt` (`scripts/palette.ts`), `src/controls/font_assets.mbt`
  (`apps/mbui/scripts/fontassets.py`), `src/controls/math_glyphs.mbt` and `src/controls/math.json` (`client/core-ts/scripts`'
  `math-font.ts`, `math-fixture.ts`), and `src/controls/icon_data.mbt` (`apps/mbui/scripts/icons.py`). App-specific brand
  drawables live in `apps/mbui/src/sfbase/drawable_data.mbt` and register via `register_drawables` / `register_station_glyphs`.
- `scripts/check-controls.sh` is its check, CI's `check-sf-ui`: the determinism lint with this module's `detlint.json` (its
  counts, as the app's, only fall), its packages type-checked on native and js, its tests on native.
- A `SourceLoc` of a part made here reads `ui/src/controls/<file>`: a test that names one (an audit's fault, what a node
  was made at) says it so.
- Only general parts and design atoms go in `src`: a part bound to one kind of the app's things (a station, an agent,
  a vault item, a login's step) is the app's, made in `apps/mbui` from these parts, so the library stays one any
  program can use.
- A public part here takes at most 8 arguments. One that needs more is split into a compound part with slots, as
  `src/controls/row_compound_node.mbt` is (`row_box_node` and its `RowScope`'s parts), never grown further: `link_row_node`
  takes no new arguments, and a row that needs one more says it in parts.
- Outlined controls (`input_node`, `textarea_node`, `select_node`, `filter_pill_node`, `choice_card`, `accordion_card`,
  framed bar fields, swatch and avatar tiles) share one hairline edge (`B0_5`, `control_edge_w` in
  `src/controls/control_edge.mbt`): `Line` at rest, `Border` pointed at or written in. `B2` in `Fg` is kept for a chosen ring.
- Every line that only parts things (a menu's or panel's groups, a sheet's rows, a tab bar's foot, a table's rows, the
  segments of a capsule) is one faint hairline: `rule_line` across or `rule_down` in a row (`rule_w`, `rule_ink`,
  `rule_color` in `src/controls/tokens.mbt`), never a thickness or colour of its own.
- Floating overlay spacing follows three tokens in `src/controls/transient_overlay.mbt`: `floating_trigger_gap` (6 pt,
  trigger control to overlay), `floating_surface_gap` (8 pt, outer-edge-to-outer-edge gap between a floating surface or
  side panel and a side-mounted secondary overlay), and `floating_viewport_pad` (8 pt, viewport safety margin). Every
  floating surface or side panel registers itself via `floating_host_lend`, and side-mounted secondary overlays
  (`Left`/`Right`) align against the host's outer edge via `View::beside(..., host?)`—never hardcode `panel_pad +
  panel_pad` or let floating surfaces touch (`< 8 pt`).
