# Wave M1.1 Production Audit Diagnostic Histogram (`libs/ui/src/controls`)

- **Reproduce**: `MBT2PION_BIN=<path> MBT_COMPAT_DIR=<dir> sh pion/tools/mbt2pion-monoid/run_audit_histogram.sh`
- **File Accounting**: **255** tracked production `.mbt` files in `libs/ui/src/controls` − **2** JS-only files excluded by `moon.pkg` (`font_assets_js.mbt`, `math_glyphs_js.mbt`) = **253** native-target `.pion` files + **1** `00_init_order.pion` = **254** generated `.pion` files (**0 hand edits**, **real Stage A.5 probes**).
- **Toolchain**: `AFK-surf/pion@6d22ff1f` (`mbt2pion` + `mbt_compat`), `AFK-surf/invar@339c271e`, `pionc 0.1.0`
- **Runtime**: `mbt2pion --mode audit` **5363 ms**; `pionc check --json` **<1 s** (0 compiler crashes)

## 1. Summary

- `mbt2pion` Gate #12a blockers: **4983** (explicit per-site drift accounting; zero silent drift)
- `pionc check --json` total diagnostics: **36516** (`E_PARSE`: **14258**, `E_TYPE_MISMATCH`: **21850**)
- Clean native-target production files (0 `pionc` diagnostics): **21 / 253**
- Layer 2 `m1_invar_blockers.json` hits: **641** (75 distinct symbols)

## 2. `mbt2pion` Stage Diagnostics (`MBT2PION_*`)

| Code | Count |
|---|---:|
| `MBT2PION_UNDISPOSED_PROBE_SITE` | 1955 |
| `MBT2PION_UNDISPOSED_DIV_MOD` | 526 |
| `MBT2PION_PROBE_RESIDUAL` | 18 |
| `MBT2PION_UNKNOWN_DERIVE` | 2 |
| `MBT2PION_PROBE_MISMATCH` | 1 |

## 3. Remaining Top 15 `mbt2pion_engine` Mechanical Buckets

| # | Count | Mechanical Bucket | Sample |
|---:|---:|---|---|
| 1 | 10120 | E_TYPE_MISMATCH: undefined identifier (parse cascade / missing local/import) | `00_init_order.pion:84:59 (undefined identifier `Ui`)` |
| 2 | 6913 | E_TYPE_MISMATCH: cannot call undefined function | `00_init_order.pion:418:84 (cannot call undefined function `A`)` |
| 3 | 2813 | E_PARSE: unexpected `:` where expression expected | `accent_pick.pion:69:67 (expected expression, found `:`)` |
| 4 | 2268 | E_PARSE: Pion keyword `val` used as field/ident (`r.val` unlowered when Stage A.5 aborts) | `00_init_order.pion:1236:49 (expected field or method name, found `val`)` |
| 5 | 2174 | E_PARSE: unexpected `,` where expression expected | `accent_pick.pion:69:60 (expected expression, found `,`)` |
| 6 | 1363 | E_PARSE: unexpected `->` where expression expected | `accent_pick.pion:69:72 (expected expression, found `->`)` |
| 7 | 1064 | E_PARSE: expected `<tok>`, found `<tok>` (found `(`) | `accent_pick.pion:139:19 (expected `)`, found `(`)` |
| 8 | 1001 | E_TYPE_MISMATCH: struct `<sym>` has no field `<sym>` | `00_init_order.pion:1236:48 (struct `signals::Ref` has no field `<error>`)` |
| 9 | 969 | E_PARSE: unexpected `)` where expression expected | `00_init_order.pion:7237:48 (expected expression, found `)`)` |
| 10 | 582 | E_PARSE: expected `<tok>`, found `<tok>` (found `:`) | `accent_pick.pion:139:27 (expected `)`, found `:`)` |
| 11 | 540 | E_PARSE: unexpected `pub` where expression expected | `00_init_order.pion:7244:1 (expected expression, found `pub`)` |
| 12 | 382 | E_TYPE_MISMATCH: type mismatch in assignment | `00_init_order.pion:1236:49 (type mismatch in assignment)` |
| 13 | 336 | E_TYPE_MISMATCH: unknown named argument `<sym>` in call to `<sym>` | `00_init_order.pion:155:83 (unknown named argument `w` in call to `text_style`)` |
| 14 | 326 | E_TYPE_MISMATCH: missing/unmapped Invar symbol in `view::*` | `accent_pick.pion:139:29 (unknown path `view::View`)` |
| 15 | 295 | E_PARSE: expected `<tok>`, found `<tok>` (found `::`) | `align.pion:70:13 (expected `(`, found `::`)` |

## 4. Remaining Top 15 Layer 2 `invar_layer2_blocker` Symbols

| # | Count | Symbol (`expected_invar`) |
|---:|---:|---|
| 1 | 420 | `ui::css` |
| 2 | 25 | `ui::span` |
| 3 | 24 | `ui::CornerOf` |
| 4 | 14 | `ui::long_press_ms` |
| 5 | 14 | `ui::style_words` |
| 6 | 12 | `ui::CornerRoots` |
| 7 | 10 | `ui::sp_at` |
| 8 | 8 | `lg::in_liquid_pill` |
| 9 | 6 | `ui::shape_of` |
| 10 | 6 | `ui::window_keys_own` |
| 11 | 5 | `lg::liquid_pill_hover_ink` |
| 12 | 5 | `ui::text_advance` |
| 13 | 5 | `ui::words_shaped` |
| 14 | 4 | `ui::has_image` |
| 15 | 4 | `ui::field_edit_now` |
