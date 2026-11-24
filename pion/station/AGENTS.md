# Working in `pion/station` (for agents)

Standalone Pion station workspace (`pion.toml`) with pinned `AFK-surf/pion` toolchain bootstrap, cross-platform C host/SQLite shims, and real `libstillfail_shell.a` static-link verification.

## Boundaries

- Keep `pion/station/` self-contained: do not depend on `pion/client-core/`, `pion/app/`, or UI packages.
- Do not modify `pion/base/`, `pion/client-core/`, or `pion/app/` from station-migration work (propose upstream `pion/base/` fixes separately). Slice-wiring PRs may update the corresponding `station/src/` switch entrypoints and `station/mb/` parity fixes alongside `pion/station/`.
- Foreign threads in `packages/host_shim/native/station_host.c` never invoke Pion callbacks; they only enqueue native events and signal the single-threaded event loop. `sth_stop` drops only `STH_EV_SHELL_DONE` events and preserves queued stdin data and EOF.
- Direct SQLite FFI in `packages/sqlite_ffi/native/station_sqlite.c` calls the `sqlite3_*` symbols bundled in `libstillfail_shell.a` without JSON serialization, behind generation-checked handle tables to prevent UAF on double-close or double-finalize.
- `--smoke-rc-soak` verifies deterministic RC reclamation and bounded RSS plateau for **acyclic object graphs** only; Pion RC does not auto-collect strong reference cycles, so long-lived station workers must break cycles via owner IDs or explicit `close()`.

## Packages and Scripts

- `TOOLCHAIN`: pinned `AFK-surf/pion` commit SHA bootstrapped by `scripts/ensure-pionc.sh`.
- `scripts/ensure-pionc.sh`: pinned upstream SHA bootstrap + local cache SHA-256 integrity verification across `pionc`, `qbe`, `libpionrt.a`, and runtime sources/headers (serialized with a lock directory).
- `scripts/build.sh`: builds `packages/smoke` (`stillfail-pion`) for `darwin-arm64`, `linux-x64` (glibc 2.28), `linux-arm64` (glibc 2.28), or `win32-x64` (MinGW GNU) linked against real `libstillfail_shell.a`.
- `packages/host_shim`: C11 POSIX + `_WIN32` host bridge (strict <= 16 MiB stdin backpressure, shell completion queue, stdout framing, args/pid/exit/RSS/fd-count) + Pion wrapper + C concurrency test (`packages/host_shim/native/host_shim_test.c`).
- `packages/sqlite_ffi`: direct `sqlite3_*` C11 FFI bridge + Pion wrapper (`open`, `prepare`, `bind_*`, `step`, `readonly`, `bind_parameter_count`, `column_*`, `reset`, `clear_bindings`, `finalize`, `exec`, `wal_checkpoint`, `wal_checkpoint_hard`) + C unit test (`packages/sqlite_ffi/native/station_sqlite_test.c`).
- `packages/sql_db`: high-level SQLite database layer over `sqlite_ffi` and `base_codec` matching `station/mb/src/sql/sql.mbt` (256-entry prepared statement cache, reset + clear_bindings, strict Int64/float/BLOB/WHATWG lossy UTF-8 binding and decoding, `Db::tx`/`Db::tx_err` transaction safety with rollback on body or commit error, `Db::rollback_if_in_tx`, nestable `Db::savepoint_err` and `Db::savepoint_swallow_err`, `is_busy`, schema helpers). Only `sql_db.pion` (plus the low-level `sqlite_ffi` smoke helper `run_smoke_sqlite` in `packages/smoke/src/main.pion`) may contain raw transaction SQL.
- `packages/js_json`: lossless UTF-16 JSON (`JValue`, `parse`, `parse_units`, `stringify`, `stringify_line`, `stringify_with_num`) and UTF-16 code-unit helpers (`utf16_units`, `utf16_len`, `utf16_slice`, `utf16_find_from`, `utf16le_bytes`, `sanitize_str`, `text`, `utf8_bytes`, `is_safe_integer`) matching `station/mb/src/jsjson/jsjson.mbt` (lone-surrogate and NUL preservation, duplicate-key first-place/last-value, canonical array-index key ordering, depth limit 1024, UTF-16 error offsets, ECMAScript number formatting via `sqlite_ffi::format_js_double`).
- `packages/builders_core`: shared SQLite builder stdio event loop (`builder_loop` with unbounded `\n` framing, WHATWG lossy UTF-8, U+2028/U+2029 escaping, `StepError::Fallback`, `db.rollback_if_in_tx()` transaction leak guard, and `Permit` with deferred FIFO queue) and the 10 core SQLite builders (`archive-marks`, `session-bindings`, `session-counts`, `signin-save`, `post-blocks`, `usage-retire`, `widget-sources`, `card-posts`, `closed-cards`, `people-since`; all write transactions via `Db::tx`/`Db::tx_err`).
- `packages/builders_index`: 5 index/job SQLite builders over `sql_db` and `builders_core` (`--builder session-up-jobs` including `job_name_first_step`, `--builder workspace-up-jobs`, `--builder outflow-chats`, stateful `--builder search-scope` with per-process `turn` rotation, and `--builder session-list` with short-circuit `step && audit`; all write transactions via `Db::tx_err`).
- `packages/builders_stateful`: stateful trigger-installing SQLite builders (`archive-last`, `page-letters` including `Letters::gc_step`) holding per-process `schema_version` install caches across requests over `builders_core::builder_loop`, `sql_db::Db::tx_err`, and `base_codec` (all write transactions via `Db::tx_err`; self-contained `CREATE TRIGGER ... BEGIN ... END;` literals).
- `packages/footprint`: production disk footprint worker (`--builder footprint`) with thin cross-platform C11 FFI (`packages/footprint/native/footprint_fs.c`: `lstat`, sorted `readdir`, `exists`, `is_dir`, non-blocking regular-file-only `head`, monotonic clock) + pure Pion traversal/rebuildable/budget engine + C unit test (`packages/footprint/native/footprint_fs_test.c`).
- `packages/memory`: production agent memory & shared skills worker (`--builder memory [--shell-dir <dir>] [--sep <sep>]`) in pure Pion over `host_shim` (`libstillfail_shell.a` `fs.*`), `base_codec`, and `crypto` (all 16 JSON-RPC ops, JS UTF-16 ordering/tags, 3-way line merge, union lines, blob storage, path-safe atomic skill writes, streaming pipelined stdin loop).
- `packages/packed`: production cold-storage worker (`--builder packed [--shell-dir <dir>]`) in pure Pion over `host_shim` (`libstillfail_shell.a`: `fs.meta`, `fs.bytes`, `fs.put`, `zstd.segments`, `zstd.check`, `tar.pack`, `tar.unpack`, `tar.file`), matching `station/mb/src/packed` seek-table and streaming line-JSON RPC contracts.
- `packages/smoke`: `stillfail-pion` binary (`--version` with `modes:footprint,packed,memory,archive-marks,session-bindings,session-counts,signin-save,post-blocks,usage-retire,widget-sources,card-posts,closed-cards,people-since,session-up-jobs,workspace-up-jobs,outflow-chats,search-scope,session-list,archive-last,page-letters`, `--smoke-stdio`, `--smoke-sqlite`, `--smoke-sql-db`, `--smoke-shell`, `--smoke-rc-soak`, `--builder footprint [--sep <sep>]`, `--builder memory [--shell-dir <dir>] [--sep <sep>]`, `--builder packed [--shell-dir <dir>]`, and `--builder <mode> --db <file>` for all 10 `builders_core` + 5 `builders_index` + 2 `builders_stateful` modes).

## Verification

- `sh pion/station/scripts/ensure-pionc.sh`
- `pionc fmt --check pion/station`
- `pionc check --json pion/station`
- `pionc test --json pion/station`
- `cc -std=c11 -O2 -Wall -Wextra -Werror pion/station/packages/host_shim/native/station_host.c pion/station/packages/host_shim/native/host_shim_test.c -lpthread -o /tmp/host_shim_test && /tmp/host_shim_test`
- `bash pion/station/scripts/build.sh linux-x64 /tmp/stillfail-pion-linux-x64`
