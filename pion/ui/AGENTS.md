# Working in `pion/ui` (for agents)

App-agnostic pure-Pion UI component library workspace (`pion.toml`), mirroring `libs/ui/src/controls` (`@sf`) on top of `AFK-surf/invar`.

## It knows no app

- `pion/ui` builds and tests independently of any app. Nothing in `pion/ui/` may import `pion/app`, `pion/client-core`, `pion/rules`, or name an app.
- What `sf` needs from a host (embedded native binaries vs Web lazy-loaded assets, brand drawables) is registered at startup via `sf::register_faces`, `sf::register_math_glyphs`, `sf::register_icons`, and `sf::register_palettes`.

## Packages

- `packages/sf`: Wave M1.1 asset registration hooks (`assets.pion`, with `valid_math_glyph_table` binary-layout validation), palette contract (`palette.pion` + `palette_test.pion`), style CSS parser (`style_css.pion` + `style_css_test.pion`, 1:1 parity with `libs/ui/src/ui/style_css.mbt`), and cross-workspace probe entrypoint (`probe.pion`). Full 255-file `@sf` (`libs/ui/src/controls`) transpilation lands in Wave M1.2; M1.1 proves 6 real production controls + real `@ui.css_read` vs `sf::css_read` parity live in `pion/tools/mbt2pion-monoid/pilot/` (where `pion/tools/mbt2pion-monoid/pilot/oracle.py` is strictly a test-oracle harness).
- `packages/sf_assets_native`: native/headless embedded asset package generated directly by `pion/tools/mbt2pion-monoid/gen_assets.mjs` (never transpiled via `mbt2pion`). Carries JetBrains Mono TTF (300,144 B), gzipped math glyph outlines (293,607 B), 164-icon stroke table, and light/dark palettes.
- `packages/sf_assets_web`: Web host-provider asset adapter supporting absent initial state, late-arrival registration with redraw callbacks, post-decompress cache release, and graceful fallback on missing/corrupt/invalid-table payloads (zero 2 MB embedded binary bloat on `wasm32`).

## Rules

- Single repo-wide `AFK-surf/invar` pin: every `pion/**/pion.toml`, `pion/**/pion.lock`, and `manifest.toml` must pin the exact same 40-char `invar` commit SHA (`sh pion/tools/mbt2pion-monoid/check_single_invar_pin.sh`).
- Verify with:
  - `sh pion/tools/mbt2pion-monoid/check_single_invar_pin.sh`
  - `node pion/tools/mbt2pion-monoid/gen_assets.mjs --check`
  - `pionc fmt --check pion/ui`
  - `pionc check --json pion/ui`
  - `pionc test --json pion/ui`
  - `pionc build --target wasm32 pion/ui`
