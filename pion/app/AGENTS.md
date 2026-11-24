# Working in `pion/app` (for agents)

Pure-Pion headless application state workspace connecting `pion/client-core` (`sync::ClientCore`) directly to Invar reactive `signals::Signal` state via zero-serialization `outbox::FrameOutbox[sync::CoreEvent]` + `ui::wake_frame` / `ui::on_frame_take` (zero Hermes, zero MoonBit, zero JSON UI protocol, zero visual skin coupling).

## Packages

- `packages/app_state`:
  - `packages/app_state/src/controller.pion`: `AppController` headless ViewModel / Signal bridge (`open_initial`, `select_chat`, `send_text`, `answer_decision`, `rename_chat`, `archive_chat`, `dismiss_notice`, `drain_core_events`) ready to mount directly onto the unified `invar` iOS 26/27 `PageShell` and component system.
  - `packages/app_state/src/sim_backend_test.pion`: deterministic `SimAccountDb`, `SimStation`, and signed Ed25519 `pion/rules` lock-chain test fixture over `effect::Runtime` virtual clock (excluded from production `pionc build`).
  - `packages/app_state/src/app_state_test.pion`: 5 headless `ui::Tester` end-to-end closed-loop tests (minimal `view::View` probe tree) verified across `INVAR_TEST_FPS=60 / 120 / 24 / 7`.
- `packages/sf_smoke`:
  - Isolated cross-workspace smoke member depending on both `app_state` and `../ui/packages/sf` to verify zero same-name `signals`/`view`/`ui` conflict while keeping `packages/app_state` 100% headless.

## Pinned Baselines

- `AFK-surf/invar`: `main` rev `339c271e0bd4ea9e2680f13adcec8075d6da9cf3` (`signals`, `view`, `ui` — single repo-wide pin shared with `pion/ui/pion.toml`, zero package conflict with `effect-v0.1.0`).
- `AFK-surf/pion-packages`: official release tags (`crypto-v0.4.1`, `markdown-v0.3.0`, `regex-v0.1.0`, and `v0.1.0` for `base64`, `effect`, `flate`, `url`, `time`, `http1`, `json5`).
- `packages/app_state` stays aligned with `pion/client-core` (`sync::ClientCore` / `store::MdStore`) compile and test contracts across `INVAR_TEST_FPS=60/120/24/7`.

## Rules

- Keep `packages/app_state` strictly headless and visual-skin agnostic (no `lg` or custom visual chrome).
- Verify with:
  - `pionc fmt --check pion/app`
  - `pionc check --json pion/app`
  - `for fps in 60 120 24 7; do INVAR_TEST_FPS=$fps INVAR_FPS=$fps pionc test --json --package app_state pion/app || exit 1; done`
