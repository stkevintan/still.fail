# Client core database reads, kept derivations, and cold-open work (for agents)

## The chat table is read by what a view shows

- Never read a station's `chat` table whole. Declare every read in `client/core-ts/src/db/chat-reads.ts` (statement, bound: `one`, `first`, or `count`, invalidation keys read and written) and run it through `Data.chatFound` or `Data.chatCounted`, pulling records from cache by key.
- `client/core-ts/scripts/whole-lists.ts` rejects whole-list reads (`WHOLE` lists remaining exceptions and how they retire).
- Bounds hold for SQLite query work, not just returned rows. `client/core-ts/test/chat-plans.test.ts` checks every declaration's plan without `ANALYZE`: `one` uses an index key lookup, `first` walks index order so `LIMIT` stops it, `count` uses covering indexes only. `OVER_PLAN` only falls. Create needed indexes on every open (`client/core-ts/src/db/schema.ts` `ensureChatColumns`).
- Re-run a read only when invalidated (`#chatRows` revision cache). Declare which row properties a station read depends on (`by`) so unrelated updates (like agent state changes) do not wake list windows. Rows reach lists by key (`$chat-row`, `$chat-record`). `client/core-ts/test/chat-told.test.ts` enforces invalidation accuracy (`TOLD_SAME` only falls).
- Keep the chat list as an index window (`client/core-ts/src/views/views.ts` `#window`) with local overlays read separately by key (`client/core-ts/src/views/local.ts` `overlaid`). Keep link status outside row computation (`#chatsMade` reads no link) and keep per-station counts separate (`client/core-ts/test/hot-paths.test.ts`) so link catch-up rebuilds no rows, windows, or counts.
- Derive indexed columns on write: SQLite JSON columns (`client/core-ts/src/db/schema.ts` `CHAT_COLUMNS`, matched against JS in `client/core-ts/test/list-rows.test.ts`) and core `Derive` columns (`state`, `watched`). Backfill rows written by older cores (`made` neither `CHAT_MADE` nor `CHAT_MADE_ALT`, which this core's upsert alternates so `chat_made_set` tells its writes from an older core's in-place update) on open. Every host opens SQLite with `locking_mode EXCLUSIVE`, so older rows are migrated before reads.

## What is made of a record is kept beside it

- Store per-record derived views through one mechanism (`client/core-ts/src/db/kept.ts` `KEPT`): declare the source table, trigger mode (`read` computes lazily on first read then updates on write, and `written` computes on every write), and `making` version. Views register makers via `Data.makes`.
- Triggers invalidate kept rows whenever any writer updates the source record. A cache hit reads no source record.
- Register every declaration in `client/core-ts/test/kept.test.ts` `HOW`. Makers must read only their record and key (verified by `list-rows.test.ts`, `profile-rows.test.ts`). Bump `making` whenever derivation output changes.
- Keep reader-specific overlays out of kept rows: pending local edits (`client/core-ts/src/views/local.ts`), unsent messages (`#unsentRow`), cross-chat opens, and cross-station account merges/refills.

## Cold-open database work (`client/core-ts/test/cold-open.test.ts`)

- Opening a settings page first (with Home shown) must not read or decorate full station overviews: read only needed `station_part` columns (`schema.ts` `PART_COLUMNS`) with statement counts constant at 5x chat logs.
- Read `cache.usage` from trigger-maintained `log_bytes` (`schema.ts` `ensureLogBytes`) and kept files from `part_bytes` (`client/core-ts/src/drive-kept.ts` `ensurePartBytes`), never summing raw rows. Let read-only calls yield to the page's first values (`store.ts` `turn`). Mutating calls never wait (rule 5).
- Opening a chat first performs zero writes before its first values: buffer view notes, Markdown trees, and opened-log markers in `Data` and flush in one transaction afterward (`data.ts` `flushMd` at `store.ts` `turn` and on close). Preload reply trees in one query (`MdStore.preload`) with constant statements at 5x chats. Replies read ahead (`md-ahead.ts`) must not be re-read on open.

## Writes that may wait (`client/core-ts/src/db/account.ts` `soon`)

- A write that need not be committed by itself (a station's event cursor, a transcript nothing reads) still runs in SQLite at once, in the burst's transaction, and only its commit waits. Never hold such a value in memory beside the database to write it later: every read, delete, account change and rollback would have to know of the copy, and the cursor must be in the transaction of what its events changed (`client/core-ts/test/data.test.ts`).
- A write that is lost (no transaction could begin, a statement failed, the burst was rolled back) commits nothing of its burst alone, and the database writes no station cursor after it (`putCursor`): the next core resumes from the last cursor written and is told those events again. The writes of the device (`PRECIOUS`) are written again on their own.
