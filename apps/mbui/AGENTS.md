# Working on still.fail's apps (for agents)

still.fail's single app on every platform (`apps/mbui/README.md`), in MoonBit on `libs/ui` (unpinned, changed in the same PR). `libs/ui/AGENTS.md` applies here too.

Narrower rules:

- `apps/mbui/src/sfbase/AGENTS.md`: data readiness, SWR, open gates, kept roots, workspace switch < 300 ms, ahead reads, `press_wait`, beside-chat tabs, topics, feature registry
- `apps/mbui/src/sfpages/AGENTS.md`: card block granularity, keyed chat page, block reuse, chat page and composer, width bindings
- `apps/mbui/src/sfapp/AGENTS.md`: screen sweeps, `fixed_outgrown`, `shown_known`, real-size budgets, replay topic bytes and trace switches, offscreen stills/video, latency

## The terms (术语)

Use these four terms in PR descriptions and user-facing text (never 电脑版, 手机版, 桌面端, 移动端, or 触屏设备):

- **屏幕** (`@sf.layout`: `Small` / `Medium` / `Large`, 小屏 / 中屏 / 大屏, plus half-open foldables laid out as 小屏 and upright phones): decides pane layout, bottom sheets by default on 小屏 (with anchored popovers only for upper-half short `Menu`, short `Pick`, and explicit `popover=true` switcher panels), and popovers beside triggers on 中屏/大屏.
- **原生操控** (`@sf.native_input()`): touch or keyboard-and-mouse, fixed at startup. Decides drawn sizes (press targets >= 44x44 without overlap on every input), hover affordances vs. touch equivalents, Enter, scrollbars, and ⌘K (the list-top search field shows on every input).
- **当前操控** (`@ui.pointing()`): live input mode. Decides interaction feedback only, never what shows, where, or how big.
- **页面宽窄** (`@sf.look()`): 窄排法 / 宽排法 based on the page's own box width.

## The app

- One app runs on every native platform and the web (`web/mbui.html`, `apps/mbui/scripts/web-app.sh`): build each page here once for all screens. `web/` keeps only the host and a few Preact pages (sign-in callback, share page, admin console).
- Do not restore mbui self-comparisons removed in #881.

## The component library

- Shared UI parts live once in `libs/ui/src/controls` (`ui/controls`, `libs/ui/AGENTS.md`), which imports nothing from the app (detlint `library-import`).
- Controls wrap `libs/ui/src/headless` for behavior and add only styling: `@headless.button`, `@headless.toggle`, `@headless.disclosure`, `@headless.choice`, `@headless.combobox` (`combo_node`, `offers_node`, `pick_node`, `search_combo_node`), `@headless.menu` (`menu_node`), `@headless.toaster` (`toaster_node`), `@headless.radio_group`, `@headless.slider`, `@headless.split`, and `@headless.table`. Conditional buttons use `button_while_node`; a disabled button that fades stays disabled while hidden. Detlint `button-by-hand` forbids hand-rolled buttons. Pass long-press tips/ripples via `@headless.Hold` and switch holds via `hold_press`.
- Show components and states in `apps/mbui/src/sfstorybook` (`foundations.mbt`, `stories.mbt`, `apps/mbui/src/sfstories`), built by `apps/mbui/scripts/kit-web.sh` to `kit.monoid.zone` (`cloud/wrangler.kit.jsonc`). Show a part's states side by side with `state_matrix_node` (`apps/mbui/src/sfstorybook/matrix.mbt`, under the bar's 环境 panel: size of words, current input, language), and draw and compare them offscreen across theme, words, input and window with `apps/mbui/scripts/story-diff.sh`.
- Beside a multi-line block, align icons, marks, chevrons, and one-line parts to the first line, never centered on block height (`Tester::first_line_faults`, `corners_first_line_known`). Below a line starting with a mark and words, start following lines at the mark or at those words, never in between (`Tester::line_start_faults`, `corners_line_start_known`).
- Never end a label in `…` for a further step (menu, dialog, sub-page): use full words and a trailing chevron (`@sf.menu_item_of` `further=true`). `…` only marks ongoing work (`正在…`) and macOS menu bar items.
- Write constant top-level styles as `@ui.css("...")`, not `@ui.style(...)` (megabytes of generated startup C, detlint `style-text`). Use `@ui.style(...)` only for computed values or inside functions.

## One app: tiers, input, pages, shell

- Six principles: equal ease on both inputs, >= 44x44 non-overlapping press targets, bottom sheets by default on Small (anchored popovers only for upper-half short `Menu`, short `Pick`, and explicit `popover=true` switcher panels) and anchored popovers on Medium/Large, screen decides layout and input decides feedback and drawn scale, the same capabilities on every tier, actions near their targets.
- Packages while legacy pages merge: `libs/ui/src/controls` (library), `apps/mbui/src/sfbase` (model, topics, `Source`, `Page`, `Shell`; imports no pages), `apps/mbui/src/sfdesk` (unmerged Medium/Large pages and frame), `apps/mbui/src/sfapp` (Small frame and pages, `pub using` `sfbase`), `apps/mbui/src/sfpages` (merged cross-screen pages).
- Move shared code down to `sfbase` or `libs/ui`. Keep business logic in the core and copy in `@sf.t`. Navigate via `@sfbase.open_page` and `@sfbase.open_detail`, never pushing onto `app.nav`.
- Never branch inside a page on `@sf.layout`, `@sf.native_input()`, or `@ui.pointing()`: adapt layout by page width, ask the library for input-aware parts, and use library primitives (`c.lit`, `c.menu_asked`, tips). Merged pages must be no worse on any screen than before.
- Presenters (`libs/ui/src/controls/presenters.mbt`) own stepping deeper in overlays (弹层里往里走): pages call `close()` and open the next, with no step state or back buttons. On 小屏 chained panels, confirms, menus, and picks slide inside one `sheet_node` (`sheet_shows_node.mbt`) and keep the scrim.

## Made once, as nodes

- Build new and rewritten UI as tree nodes (`@sf.page_node`, `@sf.panel_nodes`, `View::each`, `View::scrolls_window`, `*_node.mbt`), acting in handlers (`on_press`, `on_pick`, `on_change`). Never wrap a node part back into `Ctx`.
- To migrate or fix UI, read the logic, state, subscriptions, and git history first, then write it as nodes. Never diff `drawn_rects()`, pixel-fit the old view, or guess from screenshots.
- Legacy detlint counts (`old-island`, `old-list`, `old-panel`, `click-read`, `key-read`, `submitted-read`, `build-motion`, `layout-read-back`, `ui-current`) only fall: migrate touched code.
- See `apps/mbui/src/sfpages/AGENTS.md` for keyed chat nodes, block reuse, the chat page and composer, and width bindings.

## Motion

- Read `libs/ui/src/controls/motion.mbt` first. Every motion is one of its nine kinds with presets. Move position or size only from its cause frame, never from layout diffs or measured targets (window, sidebar, keyboard, or tier changes are not motions). Never use time windows as causes or read in logic whether a motion runs. Scale transitions keep full scale from origin and stay invisible at <= 0.5 scale (`@sf.seen_at(scale)`).

## Running in development

- Source `apps/mbui/scripts/env.sh` before running MoonBit (including remote tasks) and keep its `moon` wrapper on `PATH` so diagnostics stay compact. Never call the raw `moon` binary directly.
- Run dev builds in Wasm inside the native shell without compiling app C: `apps/mbui/scripts/wasm-app.sh run` (or `build`), or `PLATFORM=android|ios|windows apps/mbui/scripts/wasm-app.sh run`. Use `apps/mbui/e2e/run.sh mac|android|ios` for local E2E. Native scripts (`mac.sh`, `android.sh`, `ios.sh`, `win.sh`) are for CI and releases.
- On a borrowed user phone (`device_use`), install only the dev package `fail.still.android.dev` (default `VARIANT`), never a per-chat id and never overwriting stable or beta. Enable test hooks with `adb shell setprop debug.mbui.hooks 1`.

## Checks, host boundary, and where tests run

- Check changed screens with `t.audit()`, `t.sources_of(words)`, and `t.sources_at(x, y)` after reading code logic.
- App code calls the host through `@hostapi` or `@ui` and never imports `libs/ui/src/host` (detlint `host-import`, only mains like `apps/mbui/src/stillfail` import it), so native tests run on Linux (`TARGETS=native apps/mbui/scripts/test.sh`).
- `apps/mbui/scripts/test.sh` and `libs/ui/scripts/test.sh` run in CI only (they refuse elsewhere: serial wasm-gc queues on shared Macs). Locally or on build stations run `check`, `libs/ui/scripts/detlint` (which tracks per-package ceiling counts in `apps/mbui/detlint.counts/` referenced by `apps/mbui/detlint.json`), targeted test files (`moon test --target wasm-gc --release src/sfapp/<file>_wbtest.mbt`), and benchmarks for speed changes. Never ask an agent to run the full suite before opening a PR.
- Measure speed with `apps/mbui/scripts/instrbench.sh` (`compare` side by side, numbers without pass/fail verdicts) and frame time with `apps/mbui/scripts/appbench.sh`. Build size and idle memory: `.github/workflows/mbui-size.yml` (`scripts/size.sh`, `scripts/idlemem.sh`, `mbui-size` branch; report before/after on size work).
- Push only when ready to merge (`station_task` `dir` for remote checks). Watch PR CI with `ci-wait.sh` (`stillfail-github-ci`) and fix failures from logs.

## Warnings

- Every compiler warning is an error or disabled (`warnings` in `apps/mbui/moon.mod`, `libs/ui/moon.mod`, `libs/ui/tools`, `apps/mbui/tools`, `libs/ui/bench/signals`) so `moon check` skips unchanged packages. Always disabled: `33` (one-line asset data), `79` (`derive` on public types), `29` (side-effect/target imports).
- Use `Repr(x)` or `#derive(Debug)` for debugging, `Show` for human-readable text, and `some_text`/`list_text`/`rect_text` (`libs/ui/src/ui/shown_text.mbt`) for serialized values in keys or tests.
- Suppress intended unused items locally (`#warnings("-unused_value")`, `-unused_field`, `-unused_constructor`, `-struct_never_constructed`) with a comment giving the reason (and the field on structs). Delete all other unused code.
- CI tracks the latest MoonBit hourly (`.github/workflows/mbui-moonbit.yml`): fix new warnings or deprecations forward with CI's `moon version --all`.

## Before a PR

- Do not run `moon fmt` here because it reformats untouched files across the tree.
