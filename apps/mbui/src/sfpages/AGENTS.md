# still.fail app pages, chat nodes, block reuse, and Farview (for agents)

## Page lists and keyed chat nodes

- Virtualized list blocks represent single rows, not whole multi-row cards. Split long cards (such as 更新日志 days) into one block per row using `@sf.card_piece_node` so entering the viewport does not build dozens of rows in one frame.
- The node-based chat page reads data by key: subscribe to the chat head (`chat_head`, `chat_view_now`, with no messages) and keyed messages (`ChatMessages` via `Sub::keyed`, rows via `chat_body_keyed`) so updating or editing one message in place (chat messages are posted whole, never streamed word by word) reads no other rows and triggers no `view_of_chat` reads on bars, composer, or tickers (`chat_body_keyed_wbtest.mbt`). Read `chat_whole` only on press. Keep optimistic sends and outbox rows keyed (`chat_body_keyed` `taken`, `chat_sent_here`), scanning from newest back for server handoff. Use `chat_body_rows` only when a source lacks keyed messages.

## Chat block reuse (`chat_body_shape`)

- Off-screen message blocks recycle into matching shapes (`chat_body_shape`, `View::scrolls_window` `reused`). Always read `key()` reactively inside a block rather than capturing it at creation (for quote places, selections, flashes, menu bands, or long-message slices), verified by `chat_body_reuse_wbtest.mbt` and `apps/mbui/src/sfapp_realsize/chat_nodes_open_budget_test.mbt`.
- Store per-block UI state (code wrap/copy flags, horizontal scroll offsets for tables, code, and formulas) in mbui's key-scoped reuse store (`View::reused_bool`, `View::on_reused`, `libs/ui/src/view/reused_state.mbt`), never rebuilding parts per key.
- Include creation-only structure (message paths, agent cards, chat thread) in the block make key. Detlint `reused-untracked-key` counts untracked key reads inside `make_reused` and only falls.

## Chat page and composer

- The node-based chat page, its composer (`composer_node`), and the new-chat page (`new_chat_node`) are the only chat page on every screen (`chat_page_made`). Do not host the old composer inside a node-based page.
- Share all non-rendering composer logic between both views (`composer_state.mbt`, `apps/mbui/src/sfbase/compose_given.mbt`, `composer_send.mbt`) without duplicating it.
- Express width-responsive layout changes as property bindings (`By` on gap, margin, size), never structural `pick`/`show` branches on `width()` (detlint `width-structure` only falls).

## Farview client (`apps/mbui/src/sfpages/farview_tab.mbt`)

- Draw chat Farview tabs using `fvclient` from the private `AFK-surf/farview-legacy` repository. Never copy its source into this repository.
- Pin the commit in `apps/mbui/farview.pin`, reference it in `apps/mbui/moon.work`, and fetch it into `deps/farview` via `apps/mbui/scripts/farview.sh` and `apps/mbui/scripts/env.sh` (CI uses read-only `FARVIEW_DEPLOY_KEY`). Update the client by updating `farview.pin`.
- In environments without access to `AFK-surf/farview-legacy` (such as forks), test locally with an uncommitted stand-in, note it in the PR, and open the PR ready for review (never draft) so upstream CI runs the full build.
