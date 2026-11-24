#!/bin/sh
# The station's test files of one slice, I/N (scripts/check.sh's station-tests, CI's check-station), dealt by what
# each costs a runner's cores: the long files at their seconds below, the longest first, then every other file at two
# (a slice of some 108 of them took 200 core-seconds on Studio), each onto the slice with the least so far (the lowest
# among equals). Dealt one long file to a slice by place, rules-fork (125 core-seconds, its model's draws on four
# workers) took 2 in its slice beside its share of the rest, check-station (2) 148-218 s where the others were 73-171,
# eight runs of 2026-11-14. Seconds are user and system time alone on Studio with four workers (LOCK_FORK_WORKERS=4,
# as CI's runners have), 2026-11-14. On CI those two model runners cost more than that beside a slice's other files:
# dealt at 125 and 46, check-station (0) with rules-fork was 145-187 s and (1) with lock-roster4 127-152, the others
# 79-137 (fork-pr-6238 43593595033, ci/film-macos-oldest 43593584773, feat/mbui-viz 43593193529), so they count 230
# and 90, what those runs make of them. A file named here and gone is skipped; one grown long is added.
# Measured again file by file (each alone, four side by side, Studio, 2026-11-14): every file of 5 s or more at
# its seconds, rules-fork and lock-roster4 kept at what CI makes of their models' workers. Dealt with the old list's
# nine long files and 2 for the rest, slice 3 held 322 measured seconds where the others held 215-288, and was
# check-station (3) 184-204 s on every push for hours (comma-stats 27 s, replica-retire 20, mb-reader-timeline 18,
# mb-replica 16, autoarchive-last-bounded 14, accounts-routes 12, counted 2 each); dealt by these, 241-259 and
# rules-fork's slice 297. A file grown long is added, one named here and gone skipped.
# Measured again (every file, six side by side, Studio, 2026-11-16), after the lock models kept the signatures they had
# checked (lock-world-sim.ts) and the Comma statistics' tests stopped waiting 5 s a try on a database they hold
# (stats.ts `BUSY_MS`): each file at the larger of its core-seconds and its seconds, as its slot is held that long;
# rules-fork and lock-roster4 at what CI made of them before (230 and 90) times what their own time came to (129 core-s
# of 177, 27 of 63); cold-routes at its core-seconds (its 31 s are a Mac's qlmanage over a video that is none).
# Check-station (0) with rules-fork had been 119-187 s and (1) 127-190 where the others were 93-169 (2026-11-16).
# Measured again (2026-11-23, Linux x64, the 848 files each alone in its own process, four side by side as CI's
# runners have, LOCK_FORK_WORKERS=4): every file of 5 s or more at its seconds, the rest at 2 (those averaged 2.1). The
# list had stopped at 2026-11-16's 85 files while the files grew to 848: the MoonBit stations' live, e2e and fault
# files came at 2, and check-station (0) and (3) neared their 5 minutes (p90 271 and 254 s, the others 212-222, main's
# 34 runs of 2026-11-22). The list is dealt longest first whatever its order (the awk below sorts it), so a file added
# at its end is dealt in its place; dealt by these, the six slices hold within a few seconds of each other.
# Run in station/.
s=${1:-0/1}
i=${s%/*} n=${s#*/}
# (rules-fork at 480, mb-fault-replica-retire 310, memory-sync-random 200, mb-fault-runtimes-and-lend 150, lock-roster4
# 55, lock-fork-choice 55, lock-moved-model 50 and hub 45: the 2026-11-23 seconds above were a 16-core pvg-office-2's,
# where the four workers of each lock model had cores of their own, while a CI runner's 4 vCPUs share them with the
# slice's other files. Dealt at those seconds with rules-fork and replica-retire left at their old floors (168, 210: 18%
# and 23% of slices of 901), check-station (2) averaged 254 s over seven runs (45102424156, 45116462484, 45117959512,
# 45120290937, 45121410965, 45121909055, 45122235646), 298 on main's 45116462484 and cut at its 5 minutes at 310 and 311
# (45121909055, 45122235646), and (0) 220 (up to 275), where (3) with lock-roster4 and lock-moved-model averaged 165 and
# (4) with lock-fork-choice and hub 173: those runs' means at some 5.2 a second gave rules-fork 450 and replica-retire
# 350, and dealt so (#8253's 45123508084) their slices took 144 and 129 s where memory-sync-random's took 207 and
# mb-fault-runtimes-and-lend's 235 (264 s the job), so those four are set from that run. Before that: rules-fork at no
# less than what CI made of its model's workers; mb-fault-replica-retire two MoonBit stations over iroh three times, a
# 48 MiB hand-over cut by a kill, 180-208 s on CI's Linux runners (#7780's 44757732573: 208). At #8253's 310 and 260,
# check-station (0) was the slowest of seven runs (45178513923, 45207891181, 45214346959, 45216385339, 45218313109,
# 45218801300, 45220418673), its tests 239-286 s and more: 293 and 294 s the job (45218313109, 45214346959), cut at its
# 5 minutes at 308 (45218801300); (1) took 259 s of tests on a slower runner (289 the job), where (5) kept to 142-156
# (176-187 the job). At 480 and 310 slice 0 sheds some 133 units and slice 1 15, slices 2-5 taking 35-38 each.)
# Once the rules went through Pion by default (#8379), rules-fork alone outgrew a slice: check-station (0) cut at its
# 5 minutes at 313 and 311 s (45245278147, 45246805471), the file 218-220 s of them. Its person logs' drawn worlds are
# dealt by seed to rules-fork-person-a, -b and -c (rules-fork-runner.ts), rules-fork keeping the workspace lock's and
# the scripted worlds. Dealt as three files (rules-fork at 260 with a third of the person logs', -a and -b at 180),
# #8397's 45254939914 cut rules-fork's slice at 5 minutes (286 s of tests) and took 184 and 243 s of tests for -a's
# and -b's where the other slices took 150-185: so each third counts 340 and rules-fork 180, each of the four on a
# slice of its own.
long="test/rules-fork.test.ts:180 test/rules-fork-person-a.test.ts:340 test/rules-fork-person-b.test.ts:340"
long="$long test/rules-fork-person-c.test.ts:340"
long="$long test/mb-fault-replica-retire.test.ts:310 test/memory-sync-random.test.ts:200"
long="$long test/mb-fault-runtimes-and-lend.test.ts:150 test/mb-reader-usage-page.test.ts:94"
long="$long test/move-accounts.test.ts:91 test/replica-retire.test.ts:91 test/mb-fault-adb-device-connects.test.ts:81"
long="$long test/mb-fault-move-and-connects.test.ts:79 test/mb-fault-agents-and-pack.test.ts:73"
long="$long test/replica-heap-bounded.test.ts:62 test/chat-handover-back.test.ts:59 test/chat-handover.test.ts:55"
long="$long test/lock-fork-choice.test.ts:55 test/lock-roster4.test.ts:55 test/mb-reader-timeline.test.ts:51"
long="$long test/chat-handover-steps.test.ts:50 test/lock-moved-model.test.ts:50"
long="$long test/mb-live-jobs-ops-parity.test.ts:49 test/chat-handover-moves.test.ts:48 test/hub.test.ts:45"
long="$long test/mb-live-p5-1.test.ts:41 test/move-plan-bounded.test.ts:40 test/mb-replica.test.ts:39"
long="$long test/mb-legacy.test.ts:38 test/mb-live-adb-rig-drivers-parity.test.ts:37 test/hub-tools.test.ts:36"
long="$long test/store.test.ts:36 test/mb-cross-engine-handover.test.ts:35 test/mb-live-comma-replica-parity.test.ts:33"
long="$long test/mb-live-p5-2.test.ts:33 test/comma-surface-scope.test.ts:32 test/mb-dirsync.test.ts:32"
long="$long test/lock-roster.test.ts:31 test/chat-handover-told.test.ts:28 test/mb-live-p5-3.test.ts:27"
long="$long test/legacy-decision-session-store.test.ts:26 test/agy.test.ts:25"
long="$long test/mb-live-mesh-remote-parity.test.ts:24 test/replica-stations.test.ts:23 test/hub-routes.test.ts:22"
long="$long test/lock-world-2.test.ts:22 test/mb-fault-storage-and-peer.test.ts:22 test/mb-station-e2e.test.ts:22"
long="$long test/comma-router-once.test.ts:21 test/mb-upkeep-state-and-foreign-worktrees.test.ts:21"
long="$long test/workspace-connects.test.ts:21 test/mb-fault-vault-concurrency.test.ts:20"
long="$long test/mb-usage-counter.test.ts:20 test/reclaim-storage.test.ts:20 test/mb-fault-lifecycle.test.ts:19"
long="$long test/mb-live-sessions-parity.test.ts:19 test/subagent-hook.test.ts:19 test/updates.test.ts:19"
long="$long test/lock-world-1.test.ts:18 test/usage-15m.test.ts:18 test/dirsync.test.ts:17"
long="$long test/handover-bounded.test.ts:17 test/lock-world-3.test.ts:17"
long="$long test/mb-live-share-group-ops-parity.test.ts:17 test/mb-live-station.test.ts:17 test/codex.test.ts:16"
long="$long test/legacy-said-write-bounded.test.ts:16 test/mb-fault-connects-mesh.test.ts:16 test/move-sizes.test.ts:16"
long="$long test/accounts-routes.test.ts:15 test/json-startup.test.ts:15 test/mb-live-accounts-handover.test.ts:15"
long="$long test/remote.test.ts:15 test/usage-counter.test.ts:15 test/chat-handover-usage.test.ts:14"
long="$long test/cold-hub.test.ts:14 test/mb-live-vault-proxy-parity.test.ts:14 test/thumbs.test.ts:14"
long="$long test/autoarchive-last-bounded.test.ts:13 test/legacy-people-since-store.test.ts:13"
long="$long test/mb-fault-lock-and-mesh.test.ts:13 test/mb-packed.test.ts:13 test/mb-replica-carry.test.ts:13"
long="$long test/sending-pack.test.ts:13 test/state-question-reader.test.ts:13"
long="$long test/chat-list-home-interleaved.test.ts:12 test/legacy-decision-session-dropped.test.ts:12"
long="$long test/mb-fault-browser-share-rig.test.ts:12 test/reclaim-rebuildable-orphans.test.ts:12"
long="$long test/relay.test.ts:12 test/cold-compat.test.ts:11 test/context.test.ts:11 test/hub-e2e.test.ts:11"
long="$long test/jobs.test.ts:11 test/mb-fault-net-and-backpressure.test.ts:11"
long="$long test/mb-live-connects-admin-parity.test.ts:11 test/mb-live-drive-screens-browser-parity.test.ts:11"
long="$long test/mb-live-hooks-parity.test.ts:11 test/mb-recent-chat.test.ts:11"
long="$long test/messages-page-legacy-letters.test.ts:11 test/rules-lock.test.ts:11 test/transcripts.test.ts:11"
long="$long test/chat-handover-flush.test.ts:10 test/chat-list-scope-visibility.test.ts:10 test/hermes.test.ts:10"
long="$long test/mb-live-p5-4.test.ts:10 test/mb-session-backfill.test.ts:10 test/pending-delivery-reader.test.ts:10"
long="$long test/repo-branch-cleanup.test.ts:10 test/runtime-io-main-thread.test.ts:10 test/slack-stop.test.ts:10"
long="$long test/storage-classes.test.ts:10 test/autoarchive-unread-bounded.test.ts:9 test/card-outbox-scan.test.ts:9"
long="$long test/comma-stats.test.ts:9 test/jobs-logs.test.ts:9 test/legacy-said-store.test.ts:9 test/logins.test.ts:9"
long="$long test/mb-footprint.test.ts:9 test/mb-live-devices-rigs-cards.test.ts:9"
long="$long test/mb-live-vault-devices-parity.test.ts:9 test/mb-repo-branch-cleanup.test.ts:9 test/mb-search.test.ts:9"
long="$long test/mb-upstream-corpora.test.ts:9 test/screens.test.ts:9 test/search-scope-lifecycle.test.ts:9"
long="$long test/signed.test.ts:9 test/state-default-card-reader.test.ts:9 test/usage-compact-source.test.ts:9"
long="$long test/card-answers-window.test.ts:8 test/chat-configure.test.ts:8 test/chat-list-index-reader.test.ts:8"
long="$long test/comma-adaptive-page.test.ts:8 test/delete-marks-bounded.test.ts:8 test/feishu.test.ts:8"
long="$long test/group-connect.test.ts:8 test/legacy-closed-index-store.test.ts:8 test/mb-reader-shared-chats.test.ts:8"
long="$long test/mb-reclaim-storage.test.ts:8 test/memory-runners-bounded.test.ts:8 test/reader-line.test.ts:8"
long="$long test/slack-routes.test.ts:8 test/upkeep-state-and-foreign-worktrees.test.ts:8 test/upload-waits.test.ts:8"
long="$long test/agent-start-errors.test.ts:7 test/cc-index-builder.test.ts:7 test/cold-archive-batches.test.ts:7"
long="$long test/comma-task-page.test.ts:7 test/job-chat-latest-prepared-bounded.test.ts:7"
long="$long test/legacy-edits-widget-gate.test.ts:7 test/long-chat.test.ts:7 test/mb-runtime-libs-conformance.test.ts:7"
long="$long test/mb-session-up-jobs.test.ts:7 test/platform-edit-legacy-bounded.test.ts:7 test/read-tail.test.ts:7"
long="$long test/session-chat-index.test.ts:7 test/updates-routes.test.ts:7 test/usage-fill.test.ts:7"
long="$long test/warm-evict.test.ts:7 test/widget-source-index.test.ts:7 test/adb.test.ts:6 test/admit.test.ts:6"
long="$long test/cc-thread-index.test.ts:6 test/chat-list-index-entry-rowid.test.ts:6 test/chat-list-index.test.ts:6"
long="$long test/cold-routes.test.ts:6 test/conversation-review-fixes.test.ts:6 test/hub-max-concurrent-turns.test.ts:6"
long="$long test/latest-thread-index.test.ts:6 test/main-thread-waits.test.ts:6 test/mb-live-p5-5.test.ts:6"
long="$long test/mb-outflow-chats.test.ts:6 test/mb-reclaim-rebuildable-orphans.test.ts:6 test/mesh-handover.test.ts:6"
long="$long test/restate-card-concurrent-write.test.ts:6 test/run-held.test.ts:6 test/session-counts.test.ts:6"
long="$long test/accounts-cursor.test.ts:5 test/archive-mark-index.test.ts:5 test/autoarchive-jobs-bounded.test.ts:5"
long="$long test/card-outbox-worker.test.ts:5 test/card-post-index.test.ts:5 test/card-posts-builder.test.ts:5"
long="$long test/cc.test.ts:5 test/farview.test.ts:5 test/hub-parts.test.ts:5 test/mb-memory-merge.test.ts:5"
long="$long test/mb-reader-open-jobs.test.ts:5 test/mb-search-history.test.ts:5 test/multi-workspace-agents.test.ts:5"
long="$long test/pending-existence.test.ts:5 test/repo-rules-hook.test.ts:5 test/usage-chat-backfill.test.ts:5"
long="$long test/usage-compact-write.test.ts:5 test/usage-retire.test.ts:5 test/usage-timing-bounded.test.ts:5"
ls test/*.test.ts | awk -v i="$i" -v n="$n" -v long="$long" '
  function put(f, c,   g, b) { b = 0; for (g = 1; g < n; g++) if (load[g] < load[b]) b = g; load[b] += c; if (b == i) print f }
  BEGIN { k = split(long, l, " ") }
  { have[$0] = 1; all[NR] = $0 }
  END {
    for (j = 1; j <= k; j++) { split(l[j], q, ":"); want[q[1]] = 1; if (q[1] in have) { m++; lf[m] = q[1]; lc[m] = q[2] + 0 } }
    # (the longest first, by name among equals, whatever order the list says them in: one added at its end is still
    # dealt in its place)
    for (a = 2; a <= m; a++) {
      f = lf[a]; c = lc[a]
      for (b = a - 1; b >= 1 && (lc[b] < c || (lc[b] == c && lf[b] > f)); b--) { lf[b + 1] = lf[b]; lc[b + 1] = lc[b] }
      lf[b + 1] = f; lc[b + 1] = c
    }
    for (j = 1; j <= m; j++) put(lf[j], lc[j])
    for (r = 1; r <= NR; r++) if (!(all[r] in want)) put(all[r], 2)
  }'
