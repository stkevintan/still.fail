# Working on the station (for agents)

Narrower rules:

- `station/src/agents/AGENTS.md`: runtime drivers, output parsers, MCP tools, silent subagents, bug-report replies, sandboxes
- `station/src/sessions/AGENTS.md`: actors, `--sessions` `#jobs`/`#remote`/`#live`, turn states, cards, usage, cold storage, footprint
- `station/src/cloud/AGENTS.md`: lock pinning, fork choice, moved workspaces, lock tests, cloud TCP entries
- `station/src/mesh/AGENTS.md`: mesh base, ways and relays, station name and icon
- `station/src/rig/AGENTS.md`: task-only stations, ownership, signed grants, mode switch, devices
- `station/src/share/AGENTS.md`: shared agent memory, team skills, presets, starred models, profiles following the whitelist
- `station/src/ops/AGENTS.md`: storage manifest, logs, background yielding, bounded walks, self-memory, stdin backpressure
- `station/src/move/AGENTS.md`, `station/src/replica/AGENTS.md`: migration, chat handovers, backups, retirement (off)
- `station/mb/src/station_main/AGENTS.md`, `station/docker/AGENTS.md`: MoonBit station, Docker
- `station/src/screens/AGENTS.md`: clipboard privacy marks, pointer lock, gamepads

## Its shape

- A release holds the TypeScript station on its own Node (`main.js`, `pnpm run build:node`, `NODE_VERSION` from `cloud/src/install.ts`), the MoonBit reader/builder (`stillfail-reader`), launcher, runner, Helper (`scripts/station-bundle.sh`).
- The whole station in MoonBit (`station/mb/src/station_main`) is frozen and detached from the shipped `stillfail-reader` binary (kept only in `stillfail-reader-harness` for frozen tests). `station/native/launcher/src/main.rs` `station_of` starts Node directly when `config.json` sets `"engine": "moonbit"` and `main.js` is present, and `stillfail-reader` carries a lightweight `station_shim` (`station/mb/src/reader/station_shim.mbt`) that `execv`s Node in place for older launchers during live upgrades. `station/test/mb-station-contracts.test.ts` checks only that `station_main` stays wired in itself.
- A default release runs only `stillfail-reader` beside Node. A `station/src/` change needs no change in `station_main` and no `Station-parity:` trailer. No station test holds `station_main` to the living TypeScript or the catalog any more: the side-by-side twin test is gone, and `station/test/mb-station-e2e.test.ts` and `station/test/mb-station-contracts.test.ts` hold it only to itself, as `station/test/mb-cross-engine-handover.test.ts` holds the launcher's handover Node ↔ MoonBit ↔ Node (how a station set to `"engine": "moonbit"` comes back to Node). So a `station/src/` or catalog change keeps only the `reader` ↔ Node contract (`station/test/mb-reader-contracts.test.ts`, run for every `station/src/` or `station/mb/` change and in every station test run) and the existing tests, including the `station/test/mb-live-*.test.ts` regressions not yet moved. Every station test runs in every slice run.
- Processes:
  - Launcher (`station/native/launcher`, Rust) owns the pid, data-dir lock, ports; it starts the next station, then stops the old.
  - Runner (`station/native/runner`) hosts each agent so turns survive restarts (`station/src/agents/runner.ts`, `station/src/agents/mb-agents.ts` `HostedProcess.adopt`); unowned runners end (`ownedRunners`, `station/src/sessions/hub.ts` `takeUp`, `endOrphan`).
  - The MoonBit front (`station/mb/src/front/mesh.mbt`) keeps iroh's endpoint over Node handovers (`station/native/launcher/src/front.rs`, `station/src/mesh/front.ts`); without one (Windows, some checkouts) Node binds iroh via `station/native/mesh` (also image codecs).
  - `station/native/launcher/src/lifecycle.rs` restarts a Node silent on `--launcher-heartbeat` or a dead front, and retries a given-up front later. It runs the updater when Node cannot (`--launcher-installer`, `run.rs` `run_installer`; Windows: a scheduled task). `stillfail status` reads Node's `<data>/run/health.json` (`station/src/ops/health.ts`).
  - The front routes device requests (`station/src/mesh/served.ts`) to MoonBit `reader --serve` (Node gives member identity, core floor, idempotency `claim`, handles `changes`/`said`), streams compressed `GET /events` via `relay`. Background `POST /batch` reads stay on Node behind interactive ones (`station/src/read/pool.ts`).
  - Native parts are prebuilt (`scripts/native.ts`): any edit, a comment too, rebuilds them everywhere, so change them only for function.
- Helper UI (`station/native/helper`) uses still.fail's design (`web/ui/src/palette.ts`, corners, capsule buttons, `s.` mark), not system controls.
- `station/src/main.ts` is the composition root: each part an Effect 4 `Layer` (`station/src/services.ts`), no self-registration or globals; scoped fibers, `Schedule` backoff, streams for pushes, plain functions.
- Mesh wire and door (`station/src/mesh/AGENTS.md`) stay independent of still.fail admission and routes (`scripts/mesh-base.ts`).
- The main thread waits on nothing: no synchronous `node:fs`, `child_process`, or `zlib` in `station/src/` unless marked `sync:` with a reason (startup or atomic step), except `*worker.ts`, off-main-thread `station/src/read/`, `station/src/cli.ts`, `station/src/updates/command.ts` (`scripts/check.sh`; `station/test/main-thread-waits.test.ts` counts only fall; `station/test/src-sync-calls.test.ts`, config writes via `updateSoon`, its list only shrinks).
- Effect `Clock` (`TestClock` in tests). `Date.now`, `new Date()`, `setTimeout`, `setInterval` only in `station/src/ops/fibers.ts` (`wall`: external mtimes, expiries, deadlines); `scripts/check.sh` rejects them elsewhere.

## Its data

- State is one SQLite file, `stillfail.db` (`station/src/store/store.ts`, `station/src/store/schema.ts`), one writer on the main thread. Reads, card pages, checkpoints, backfills, replica export/restore run in MoonBit readers and builders (`station/mb/`, `station/src/read/pool.ts`, `station/src/read/mb-reader.ts`, `station/src/replica/`): no JS workers, no TypeScript fallback. Schema repairs (`Readers.repairEdits`) run on the writer, retrying on busy without blocking. Parity references: `station/test/reference/`, `station/test/workers/`.
- Two processes open `stillfail.db` during a handover: each connection sets a busy timeout, each writing transaction starts `BEGIN IMMEDIATE` (`scripts/check.sh`).
- Station reads carry no UI words (the core's: `client/core-ts/src/chat-row.ts` `worded`, `entries.ts` `authorNameOf`, local pages, `station.files.*` refusals, `inScript`); only station notices and Comma messages do (`station/src/read/pool.ts` `SAID`).
- Every read uses an index and a limit; a new read gets a bounded test (`station/test/*-bounded.test.ts`). New indexes come from background backfills sharing one permit (`station/src/read/*-builder.ts`, `station/src/store/backfill.ts`); bound reads another way until then.
- Threads are append-only logs (edits append, Slack deletes ignored, readers merge); migrations go forward only; every change is pushed on `GET /events` (`station/src/api/events.ts`).
- No per-person or per-chat permission inside a workspace: every member and agent reads every chat (private too); agents share one OS user and database. Only workspaces are isolated. Never propose or build per-chat visibility: it is by design unless the owner changes it.

## Core invariants

- Subagents never speak in a chat; agent plain text is never forwarded; turns end with a state; bug-report replies never reach agents by themselves (`station/src/agents/AGENTS.md`, `station/src/sessions/AGENTS.md`).
- Workspace `MEMORY.md` and team skills sync to all stations by `--builder memory` 3-way merges (MoonBit by default, or Pion via `STILLFAIL_READER_MEMORY=pion`, `config.json` `readers.memory`, or `STILLFAIL_READER_ENGINE=pion`); reader/builder engine selection (`station/src/read/reader-select.ts`, `station/src/read/mb-reader.ts` `resolveReaderSelection`) follows `STILLFAIL_READER_<MODE> > config.readers[mode] > STILLFAIL_READER_ENGINE > mb`, hot-reloads from the live `ReaderConfig` snapshot on each new spawn without disrupting in-flight work, and gates Pion behind `pionImplemented` plus a non-blocking `--version` capability probe; each person's devices carry presets and starred models (`station/src/share/AGENTS.md`).
- Relays: kept on stations, added by agents without approval after a probe; disabled ones apply to stations too (`station/src/mesh/AGENTS.md`).
- Rigs run tasks only under owner-signed grants; a whole station becomes a rig by its adder or a workspace owner/admin, who then owns it, and only that owner makes it whole again (`station/src/rig/AGENTS.md`).
- Pinned locks are released only by `disable` or the local CLI, follow fork choice, enforce moved-workspace build floors (`station/src/cloud/AGENTS.md`).
- Heavy work goes to l4es `sandboxes` via `station_task`; no station or agent runs in one (`station/src/agents/AGENTS.md`).

## Screens

- One view drives a screen; any number watch (`station/src/screens/hub.ts` `drive`). Taking control (控制 / 接管, `taken`) makes every other driver (the person's other devices too) watch, told who took it; reconnects and resizes never take it.
- Agent input waits while a person drives (`station/src/tools/computer.ts`); both sides are told.

## Terminals

- Member terminals (`station/src/terminals/`) run under `native/runner --pty` (`term-…`, metadata in `<data>/run/terminals/`), adopted across restarts apart from agent runners (`isTerminalRunner`).
- Members not read-only type (exclusive with 接管); read-only ones watch; each workspace sees its own. A new viewer gets the libghostty-vt screen (`native/runner` `screen`), then live output.
- Terminals are `beta` (`station/src/features.ts`): new ones only on test-channel stations (overview `features`); old ones stay viewable and stoppable; none on rigs yet.

## Devices (设备)

- Devices: USB, network, or serial devices on a station (`station/src/devices/`, `connect.ts`), or a member's phone lent by its app (`station/src/adb/`). One list (`device_list`), one request flow (`device_use`). A chat gets a `127.0.0.1` port for its processes alone (`station/src/adb/door.ts`), tunneled over the mesh (`station/src/mesh/peer-http.ts`).
- A whole station's devices need no grant (all workspace chats share it); ones needing owner approval attach to a rig (`station/src/rig/AGENTS.md`).

## Tests

- Typecheck `pnpm exec tsgo --noEmit`; one file: `node ../scripts/native.ts run mesh runner archive-rs reader reader-harness launcher -- node --import ./test/setup-env.mjs --test test/<file>.test.ts` (all: `pnpm test`). A package's harness (`--builder harness-*`, its `harness*.mbt`) lives in the tests' `stillfail-reader-harness` (`station/mb/src/reader_harness`, `station/test/mb-harness.ts`), never the shipped reader. Fake agents on `TestClock`; real processes, signals, sockets in `station/side/`.
- CI runs `station/test/` on Linux, sliced (`scripts/check.sh`, `station-tests`). Tests pass on Linux and macOS or skip naming what is missing. File-backed vault tests use `station/test/vault-no-reader.ts` unless testing the reader process.
- The lock's and vault's rules come through `shared/rules-runtime.ts`: `pion` (`pion/rules`) by default in Node when `pion-rules/` or `pion/rules/js/` is present (`rules/js/rules.js` in Workers or without the Pion build); `STILLFAIL_RULES_MODE=moonbit` rolls back immediately, and `STILLFAIL_RULES_MODE=shadow` (with `STILLFAIL_RULES_SHADOW_STRICT=1` to throw on a difference) diffs both ports. Tests that call the rules import that module, not `rules/js/rules.js`, except `rules-fork-check.ts` when `pion/rules/test/parity.test.mjs` intercepts it via `__PION_RULES_DUAL__`.
- Wait on off-main-thread work with `settle()` (`station/test/hub-fakes.ts`), not turn counts. Guard events that may never come with `given()` to fail at once.
