# Working on the client core (for agents)

The client core holds all client logic, running in Hermes for the app (`apps/mbui/engine`, `apps/mbui/src/host/apple_core.mm`) and in a tab worker on the web (`client/core-ts/src/hosts/web.ts`). UIs send named calls, subscribe to topics, and render pushed values. UIs never contact stations or cloud directly.

Subsystem rules live in narrower `AGENTS.md` files loaded when touching those directories:

- `client/core-ts/src/db/AGENTS.md`: indexed `chat` reads, query plans, invalidation, kept derivations beside records, cold-open DB budgets
- `client/core-ts/src/station/AGENTS.md`: topic-work/view-work budgets, keyed row sync memo, moved chats, base isolation
- `client/core-ts/src/views/AGENTS.md`: locks, fork choice, moved workspaces, seamless handover, presets and starred models

## Core design rules

1. **Everything async is Effect**: Run calls, subscriptions, links, sockets, and sync as scoped fibers (`client/core-ts/src/runtime.ts`). Cancel by interrupting. Use Effect `Clock` (`TestClock` in tests), never `setTimeout`. Platform differences live behind `Host` (`client/core-ts/src/host.ts`, declared in `src/host-of.ts`, implemented in `src/hosts/`), with every operation an Effect.
2. **Pushed, never polled**: Consume station `/events` and cloud `/v1/events`. Sample only live on-screen metrics (link speed, wait counters) while visible.
3. **Cache first**: Each signed-in account owns one SQLite database (`client/core-ts/src/data.ts`, `client/core-ts/src/db/`) with one writer and forward-only migrations. Read topics from SQLite queries, never from the network.
4. **One sync owns all traffic** (`client/core-ts/src/sync/scheduler.ts`, `src/station/sync.ts`, `src/sync/cloud.ts`): Sync keeps data current regardless of what is shown. Visible UI and `client.focus` raise priority only. Subscriptions never start network requests. Exceptions read only while shown: station usage, archived chats, a chat/thread/session missing from station lists (fetched on open so it shows or reports missing), on a cellular network, transcripts of chats not currently shown (fetched on open or when leaving cellular to save battery), and while a database is past its room with nothing left to let go, transcripts nothing reads (`data.ts` `transcriptOverBudget`: fetched on open or when there is room again, rather than written and let go at once).
5. **Actions never wait for the network**: Apply locally at once (outbox, pending chat, persisted rename/pin/archive overlays), track with `doing`, and roll back with an error on failure. Match local items to station items by exact `clientKey`, never by guessing.
6. **Changes are by key**: Views recompute topic values whole when inputs change. The store preserves equal objects (`client/core-ts/src/collections.ts` `share`, tracking topic `kept` entries for keyed `SPECS`), emits keyed `diffKeyed` ops (insert, patch, drop, move), and reshapes only changed objects (`client/core-ts/src/output.ts`). Unchanged objects cost one reference comparison. `client/core-ts/test/view-work.test.ts` bounds remaining walks.
7. **Workspaces are isolated** from each other.

- **Shared file reads**: File readers share both kept bytes and in-flight ranges of the same version. New consumers must use the core's station file reads. Test new consumers alongside a save with the wire held mid-part, counting requested intervals in both orders and after either reader leaves (`client/core-ts/test/downloads.test.ts`).

## What a topic sends is bounded

- The app parses every core message on its frame thread, so payloads are strictly capped: at most 32 KB for a whole topic value and 4 KB for a change delta (`client/core-ts/test/topic-bytes.test.ts` on `test/real-size.ts`).
- List items carry only what their rows show. Detail pages subscribe to per-item topics. Never add a detail-page field to a shared list topic.
- Fetch press-only data on press from local SQLite and open the panel whole once answered (for example `chatRow` menu, `pick` model panel).
- When the app drops a topic (`keep`) and re-subscribes (`have`), send `same` or a delta against what it kept (`store.ts` `#first`), held to the delta bar (`OVER_AGAIN`).
- Every topic query has a measured change cause in `client/core-ts/test/real-size-asked.ts` `CAUSES` (or an explained entry in `STILL`, which only falls) and exports device ops for the app sweep (`client/core-ts/test/real-size-app.test.ts`, `apps/mbui/src/sfrealsize/c_*.mbt`).
- Outgoing values conform strictly to declared topic shapes (`client/core-ts/src/conform.ts`, `views.ts` `asShaped`, `conform.ts` `reshaped`), stripping fields only the core reads (`store.value`, such as `src/choose.ts` reading `views.agent`). Give topics with different fields separate shapes (`ListedProfile`, `StationProfile` beside `Profile`).
- Populate every list and map in the real-size fixture (`EMPTY`, `OVER`, `OVER_AGAIN`, and `STILL` only fall, and `NOT_MEASURED` requires a named cap or fixed shape).
- Never inline picture bytes in a topic value: pass a token and fetch bytes beside a call (`client/core-ts/src/peek-pictures.ts`, `station.file`).

## What is shared is never written

- Reference identity drives rule 6. Any value read from SQLite (`Data.shared()`), held in the store, sent out (`src/output.ts`), or cached is immutable once created.
- Mutate only freshly allocated objects: shallow-copy along the modified path and reuse unchanged subtrees. Tests and web dev builds deep-freeze shared values (`client/core-ts/src/util.ts` `sharedValue`). `client/core-ts/scripts/writes.ts` rejects parameter mutations in view builders.

## Database, sync, locks, and base invariants

- **Read work follows sent work**: Answering queries and applying sync causes must read at most 2x what they send/write (or 8 KB) and stay constant as workspace data scales 3x. Never read `chat` whole, keep per-record derivations beside their records, and keep settings/chat cold opens fast (`client/core-ts/src/db/AGENTS.md`, `client/core-ts/src/station/AGENTS.md`).
- **Moved chats**: Route old station references through `Data.chatNow` without rewriting UI state (`client/core-ts/src/station/AGENTS.md`).
- **Locks and presets**: Follow fork choice, never prompt for sealed secrets in the background, never count cloud acceptance, and never block lock handover on offline/outdated member devices (`client/core-ts/src/views/AGENTS.md`).
- **Base isolation**: `src/mesh.ts` and the client runtime base import nothing from still.fail business logic or catalog (`client/core-ts/scripts/base.ts`, `client/core-ts/src/station/AGENTS.md`).

## Contracts made from here

- `client/core-ts/src/ops.ts` `PARAMS` generates UI operation bindings via `client/core-ts/scripts/operations.ts`. `client/core-ts/src/shapes/schema.ts` (composed from domain modules in `client/core-ts/src/shapes/`) generates client types and app `said` paths via `client/core-ts/scripts/shapes.ts`. Edit the source and run the script. Never edit generated outputs.
- The core runs on Hermes 0.81: avoid newer methods like `toSorted` and avoid `Intl` outside `src/hosts/` (sort names via host `collate`). Bundle with `client/core-ts/scripts/hermes-bundle.ts`. A change that only runs in Node is not done.
- Tests: `pnpm test`, or one file with `node ../../scripts/native.ts run mesh reader-harness -- node --import ./test/setup-env.mjs --test test/<file>.test.ts` (`client/core-ts/test/setup-env.mjs` makes a file stopped at CI's time report which test hung). Networks run simulated on `TestClock` (`client/core-ts/test/sim-iroh.ts`, seeds in `test/sim-seeds.ts`, `SIM_SEED=` selects one).
