# Station shared agent memory, skills, presets, and stars (for agents)

## Shared agent memory and team skills

- A workspace shares one `MEMORY.md` and one set of team skills across all its stations. Machine-specific facts state which station they apply to.
- `station/src/share/memory.ts` keeps recent versions and brings stations level with 3-way merges (like `git merge-file`, keeping both sides on conflict). Do not use a CRDT library because CRDT history grows unboundedly and requires coordinated compaction.
- `--builder memory` (`station/mb/src/memory` by default, or `pion/station/packages/memory` via `STILLFAIL_READER_MEMORY` > `config.json` `readers.memory` > `STILLFAIL_READER_ENGINE` in `pion` mode, hot-reloading from `ReaderConfig` on each new spawn; shadow strictly forbidden because of filesystem writes; `station/src/share/memory-mb.ts`, shut down when idle) handles file reading, hashing, blob storage, and merging off the main thread. It also handles standalone shared skills (`station/src/share/index.ts`, saving edits on stale copies beside them). No TypeScript fallback exists: parity tests hold it byte-for-byte to `station/test/reference/memory-merge.ts` (`station/test/mb-memory-merge.test.ts`, `station/test/reader-contract-memory.test.ts`, `station/test/memory-pion-switch.test.ts`) and `station/test/reference/share-skills.ts` (`station/test/mb-share-skills.test.ts`).
- Merge edge cases:
  - Without a common ancestor, deduplicate `MEMORY.md` lines (and lines of files both stations kept editing) and keep unrelated same-named skills apart as `<name>-<station>`.
  - When a common ancestor is missing from history, keep every line from both versions. Never drop data on merge.
  - `station/test/memory-sync-random.test.ts` (`MEMORY_RANDOM_SEEDS`) verifies convergence over random worlds, and `station/test/memory-sync-upgrade.test.ts` checks `#mend` repair of 0.1.9133-0.1.9168 artifacts.
- Keep memory concise: every session reads `MEMORY.md` and project skills whole. Past `MEMORY_MOST`, `SKILL_MOST`, or `LINE_MOST` (`station/src/agents/instructions.ts` `overgrown`), tell sessions which files to condense. Agents clean up merge duplicates.
- Detect edits only with narrow directory watches (`memoryFollowed`, `station/src/ops/follow.ts`). Never use `fs.watch(..., { recursive: true })` over agent-writable trees: on Linux it walks the tree on the main thread and consumes inotify watches across clones and `node_modules`.

## Presets and starred models

- Each person's presets and starred models stay identical across all their devices and workspace stations, carried by their devices (`GET /presets/kept`, `PUT /presets/kept`, `GET /stars`, `PUT /stars`) using shared merge rules (`client/core-ts/src/preset-records.ts`: `rev` counts changes, deletions are records).
- Stations never sync presets or stars with each other, send nothing about them to cloud, and never rewrite bytes a device brought. Legacy endpoints (`POST`, `PUT`, `DELETE /presets`) edit only local `home` records for older apps.
- Cap kept deletions per owner using `goneKept` (`client/core-ts/src/preset-records.ts`, grouping ownerless deletions together). `Presets.carry` ignores PUTs whose deletions would drop immediately so deletions do not loop. Include ownerless deletions in every `GET /presets/kept` so the creator's device claims them.
- Agents see all presets on the station (`chat_create`). People see their own by default and others on demand (`GET /presets/others`). That is a UI filter, not a permission boundary.
- A person's drafts of the board's 待派发 are carried the same way (`station/src/sessions/board-drafts.ts`, the rule `client/core-ts/src/board-drafts.ts`; `GET` and `PUT /board/drafts`), their files kept only by the station each draft is to run on and given to that person's devices alone (`GET /board/files`).

## Profiles following the workspace's whitelist

- A shared profile with `allowAuto` reaches its host and every station that says it takes automatically assigned chats (`acceptAutoChats`, not task-only). Stations push that as it changes (`share.autoChats`, sent on config and cloud changes); a host asks one it has not heard from this run with `describe`, never on a timer. A station never heard from is left out (no credentials go out on a guess); one that does not answer keeps what it said last and is refused for now, never with `NOT_FOR_IT`, so its copy is not dropped.
- What goes out (`share.changed`, `share.get`, the overview's `allow`) is always the station list it makes now, so older stations and apps read a plain list; `allow` in config then holds only stations a move lent it to besides (`lendTo`).
