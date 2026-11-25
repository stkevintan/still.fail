package dev.mbui;

import java.util.ArrayList;
import java.util.List;

/**
 * Deterministic unit tests for {@link GlyphsAhead} (no Android dependencies, no threads, no sleeps).
 * Run via {@code scripts/glyphsahead_test.sh}.
 */
public final class GlyphsAheadTest {
    private static int failed;

    private static void check(boolean ok, String what) {
        if (ok) return;
        failed++;
        StackTraceElement at = new Throwable().getStackTrace()[1];
        System.err.println("GlyphsAheadTest.java:" + at.getLineNumber() + ": failed: " + what);
    }

    static final class FakeDrawn {
        final String tag;
        boolean released;

        FakeDrawn(String tag) {
            this.tag = tag;
        }

        void release() {
            released = true;
        }
    }

    static final class TestSlot extends GlyphsAhead.Slot<FakeDrawn> {
        final int id;

        TestSlot(int id) {
            this.id = id;
        }
    }

    private static int key(int idx, int sub) {
        return idx | (sub << 26);
    }

    private static GlyphsAhead.Claim<TestSlot> claim(GlyphsAhead<TestSlot, FakeDrawn> ga) {
        synchronized (ga.lock) {
            return ga.claimNext();
        }
    }

    /** 1. Eviction / consumption re-enqueue: subsQueued already set does not suppress re-warming. */
    static void evictionReenqueue() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        TestSlot e = entries.get(0);

        // First warm phase 0 and consume it.
        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "initial enqueue");
        GlyphsAhead.Claim<TestSlot> c1 = claim(ga);
        check(c1 != null && c1.bit == 1, "claimed phase 0");
        FakeDrawn d1 = new FakeDrawn("p0-first");
        ga.finish(c1, d1);
        check(ga.takeDrawn(e, 0, 2f, 1) == d1, "took first phase 0");
        check(ga.aheadCount == 0 && (e.subsQueued & 1) != 0, "idle with subsQueued bit 0 still set");

        // Re-request phase 0 after eviction/consumption: must re-enqueue and produce result.
        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "re-enqueue phase 0 despite subsQueued");
        check(ga.aheadCount == 1, "aheadCount=1 after re-enqueue");
        GlyphsAhead.Claim<TestSlot> c2 = claim(ga);
        check(c2 != null && c2.bit == 1, "re-claimed phase 0");
        FakeDrawn d2 = new FakeDrawn("p0-second");
        ga.finish(c2, d2);
        check(ga.takeDrawn(e, 0, 2f, 1) == d2, "took second phase 0");
        check(ga.aheadCount == 0, "aheadCount=0 after consuming re-enqueued phase 0");
    }

    /** 2. Second distinct phase triggers moved expansion of remaining phases into askedRest. */
    static void movedExpandsRemainingPhases() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        TestSlot e = entries.get(0);

        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "phase 0 queued");
        GlyphsAhead.Claim<TestSlot> c0 = claim(ga);
        ga.finish(c0, new FakeDrawn("p0"));
        check(claim(ga) == null, "only phase 0 queued initially");

        // Ask phase 1 -> moved=true -> wants phases 1, 2, 3 (phase 1 first, 2 and 3 in rest).
        check(ga.ahead(entries, new int[] {key(0, 1)}, 1, 2f, 1, 0), "phase 1 triggers moved expansion");
        GlyphsAhead.Claim<TestSlot> c1 = claim(ga);
        check(c1 != null && c1.bit == (1 << 1), "phase 1 claimed first");
        ga.finish(c1, new FakeDrawn("p1"));
        GlyphsAhead.Claim<TestSlot> c2 = claim(ga);
        GlyphsAhead.Claim<TestSlot> c3 = claim(ga);
        check(c2 != null && c2.bit == (1 << 2) && c3 != null && c3.bit == (1 << 3), "phases 2 & 3 claimed next");
        ga.finish(c2, new FakeDrawn("p2"));
        ga.finish(c3, new FakeDrawn("p3"));
        check(claim(ga) == null, "all 4 phases done");
        for (int s = 0; s < 4; s++) {
            check(ga.takeDrawn(e, s, 2f, 1) != null, "phase " + s + " available");
        }
        check(ga.aheadCount == 0, "aheadCount=0 after taking all 4");
    }

    /** 3. Skip race Order 1 (re-request before finish -> unskip & reuse) and Order 2 (after finish -> add & redraw). */
    static void skipRaceBothOrders() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        TestSlot e = entries.get(0);

        // Order 1: in-flight -> foreground takeDrawn marks skip -> re-request BEFORE finish clears skip -> result kept.
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0);
        GlyphsAhead.Claim<TestSlot> c1 = claim(ga);
        check(ga.takeDrawn(e, 0, 2f, 1) == null && (e.skip & 1) != 0, "takeDrawn marks in-flight phase skipped");
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0);
        check((e.skip & 1) == 0, "re-request before finish clears skip");
        FakeDrawn d1 = new FakeDrawn("reused");
        ga.finish(c1, d1);
        check(!d1.released && ga.takeDrawn(e, 0, 2f, 1) == d1, "Order 1: unskipped result reused");
        check(ga.aheadCount == 0, "Order 1: aheadCount=0");

        // Order 2: in-flight -> foreground takeDrawn marks skip -> finish releases -> re-request AFTER finish redraws.
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0);
        GlyphsAhead.Claim<TestSlot> c2 = claim(ga);
        check(ga.takeDrawn(e, 0, 2f, 1) == null && (e.skip & 1) != 0, "Order 2: skip marked");
        FakeDrawn d2 = new FakeDrawn("discarded");
        ga.finish(c2, d2);
        check(d2.released && ga.aheadCount == 0, "Order 2: skipped result released and count=0");
        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "Order 2: re-request after finish queues redraw");
        GlyphsAhead.Claim<TestSlot> c3 = claim(ga);
        check(c3 != null && c3.bit == 1, "Order 2: re-claimed");
        FakeDrawn d3 = new FakeDrawn("redrawn");
        ga.finish(c3, d3);
        check(!d3.released && ga.takeDrawn(e, 0, 2f, 1) == d3, "Order 2: redrawn result taken");
        check(ga.aheadCount == 0, "Order 2: aheadCount=0");
    }

    /** 4. After generation reset, same-scale in-flight entry backfills subsQueued so a subsequent new phase expands. */
    static void resetBackfillsSubsQueuedForInFlight() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        TestSlot e = entries.get(0);

        // Gen 0: phase 0 in flight.
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0);
        GlyphsAhead.Claim<TestSlot> c0 = claim(ga);
        check(c0 != null && c0.bit == 1, "gen 0 phase 0 in flight");

        // Gen 1 (reset() bumped generation, same scale/faces): re-request phase 0 while still in flight.
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 1);
        check((e.subsQueued & 1) != 0, "subsQueued backfilled with phase 0 on gen 1");

        // Still gen 1: request phase 1 -> must see subsQueued != 0 -> moved=true -> expand phases 1, 2, 3!
        check(ga.ahead(entries, new int[] {key(0, 1)}, 1, 2f, 1, 1), "phase 1 queued in gen 1");
        check(e.want == ((1 << 1) | (1 << 2) | (1 << 3)), "phases 1..3 expanded: want=" + e.want);

        ga.finish(c0, new FakeDrawn("p0"));
        GlyphsAhead.Claim<TestSlot> c1 = claim(ga);
        GlyphsAhead.Claim<TestSlot> c2 = claim(ga);
        GlyphsAhead.Claim<TestSlot> c3 = claim(ga);
        check(c1 != null && c2 != null && c3 != null && claim(ga) == null, "phases 1..3 all claimed");
        ga.finish(c1, new FakeDrawn("p1"));
        ga.finish(c2, new FakeDrawn("p2"));
        ga.finish(c3, new FakeDrawn("p3"));
        for (int s = 0; s < 4; s++) check(ga.takeDrawn(e, s, 2f, 1) != null, "phase " + s + " taken");
        check(ga.aheadCount == 0, "aheadCount=0");
    }

    /** 5. Full stale deferred handoff suite: merge+cancel, A->B->A, A->B->C, all-cancelled, OOM null finish. */
    static void staleDeferredHandoffSuite() {
        // 5a: A in-flight + B0 + B1 (expands B0..B3) + foreground cancels B0, B2, B3 -> A finish dispatches only B1.
        {
            GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
            List<TestSlot> entries = new ArrayList<>();
            entries.add(new TestSlot(0));
            TestSlot e = entries.get(0);

            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 0);
            GlyphsAhead.Claim<TestSlot> cA = claim(ga);
            check(ga.aheadCount == 1, "5a: count=1 while A in-flight");

            // Scale changes to 2f: request B0, then B1 (same batch/scale merges pendingWant -> B0..B3).
            ga.ahead(entries, new int[] {key(0, 0), key(0, 1)}, 2, 2f, 1, 1);
            check(ga.aheadCount == 1, "5a: count still 1 with pending B");
            check((e.pendingWant & 0x0F) == 0x0F, "5a: B0+B1 triggered moved expansion into pendingWant");
            // Foreground explicitly consumes B0, B2, and B3, leaving only B1 pending.
            check(ga.takeDrawn(e, 0, 2f, 1) == null, "5a: takeDrawn B0 cancels pending B0");
            check(ga.takeDrawn(e, 2, 2f, 1) == null, "5a: takeDrawn B2 cancels pending B2");
            check(ga.takeDrawn(e, 3, 2f, 1) == null, "5a: takeDrawn B3 cancels pending B3");
            check(e.pendingWant == (1 << 1) && e.pendingFirst == (1 << 1), "5a: only B1 left after B0/B2/B3 cancelled");

            FakeDrawn dA = new FakeDrawn("A");
            boolean handed = ga.finish(cA, dA);
            check(handed && dA.released && ga.aheadCount == 1, "5a: A released, handed off B1, count stays 1");
            GlyphsAhead.Claim<TestSlot> cB1 = claim(ga);
            check(cB1 != null && cB1.bit == (1 << 1) && cB1.scale == 2f && claim(ga) == null, "5a: only B1 claimed");
            FakeDrawn dB1 = new FakeDrawn("B1");
            check(!ga.finish(cB1, dB1) && !dB1.released && ga.aheadCount == 1, "5a: B1 stored, count=1");
            check(ga.takeDrawn(e, 1, 2f, 1) == dB1 && ga.aheadCount == 0, "5a: B1 consumed, count=0");
        }

        // 5a-raw: A in-flight + B0 + B1 (expands B0..B3) + foreground cancels ONLY B0 -> A finish hands off:
        //         B0 is never re-dispatched, B1 is sole first (claimed first), B2 & B3 stay in rest (claimed next).
        {
            GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
            List<TestSlot> entries = new ArrayList<>();
            entries.add(new TestSlot(0));
            TestSlot e = entries.get(0);

            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 0);
            GlyphsAhead.Claim<TestSlot> cA = claim(ga);
            ga.ahead(entries, new int[] {key(0, 0), key(0, 1)}, 2, 2f, 1, 1);
            check(ga.takeDrawn(e, 0, 2f, 1) == null, "5a-raw: foreground consumes B0 only");
            check(e.pendingWant == ((1 << 1) | (1 << 2) | (1 << 3)) && e.pendingFirst == (1 << 1),
                    "5a-raw: B1 is sole pendingFirst, B2/B3 remain in pendingWant");

            FakeDrawn dA = new FakeDrawn("A-raw");
            check(ga.finish(cA, dA) && dA.released && ga.aheadCount == 1, "5a-raw: handoff preserves count=1");
            check(e.first == (1 << 1) && e.want == ((1 << 1) | (1 << 2) | (1 << 3))
                    && e.inFirst && e.inRest, "5a-raw: B1 in askedFirst, B2/B3 in askedRest");

            GlyphsAhead.Claim<TestSlot> cB1 = claim(ga);
            check(cB1 != null && cB1.bit == (1 << 1) && cB1.scale == 2f, "5a-raw: B1 claimed first");
            GlyphsAhead.Claim<TestSlot> cB2 = claim(ga);
            GlyphsAhead.Claim<TestSlot> cB3 = claim(ga);
            check(cB2 != null && cB2.bit == (1 << 2) && cB3 != null && cB3.bit == (1 << 3) && claim(ga) == null,
                    "5a-raw: B2 and B3 claimed from rest, B0 never dispatched");
            FakeDrawn dB1 = new FakeDrawn("B1-raw");
            FakeDrawn dB2 = new FakeDrawn("B2-raw");
            FakeDrawn dB3 = new FakeDrawn("B3-raw");
            ga.finish(cB1, dB1);
            ga.finish(cB2, dB2);
            ga.finish(cB3, dB3);
            check(ga.takeDrawn(e, 0, 2f, 1) == null, "5a-raw: B0 not present");
            check(ga.takeDrawn(e, 1, 2f, 1) == dB1 && ga.takeDrawn(e, 2, 2f, 1) == dB2
                    && ga.takeDrawn(e, 3, 2f, 1) == dB3 && ga.aheadCount == 0,
                    "5a-raw: B1..B3 consumed and aheadCount=0");
        }

        // 5b: A -> B -> A switch back clears pending B so A finish does NOT overwrite A with B.
        {
            GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
            List<TestSlot> entries = new ArrayList<>();
            entries.add(new TestSlot(0));
            TestSlot e = entries.get(0);

            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 0);
            GlyphsAhead.Claim<TestSlot> cA = claim(ga);
            ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 1); // pending B
            check(e.pendingWant == 1 && e.pendingScale == 2f, "5b: pending B recorded");
            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 2); // switch back to A
            check(e.pendingWant == 0 && (e.skip & 1) == 0, "5b: switch back to A cleared pending B and unskipped A");
            FakeDrawn dA = new FakeDrawn("A-back");
            check(!ga.finish(cA, dA) && !dA.released, "5b: A completed without handoff");
            check(ga.takeDrawn(e, 0, 1f, 1) == dA && ga.aheadCount == 0, "5b: A reused and count=0");
        }

        // 5c: A -> B -> C overwrites pending B with C.
        {
            GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
            List<TestSlot> entries = new ArrayList<>();
            entries.add(new TestSlot(0));
            TestSlot e = entries.get(0);

            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 0);
            GlyphsAhead.Claim<TestSlot> cA = claim(ga);
            ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 1);
            ga.ahead(entries, new int[] {key(0, 2)}, 1, 3f, 2, 2);
            check(e.pendingScale == 3f && e.pendingFaces == 2 && e.pendingWant == (1 << 2), "5c: pending overwritten by C");
            FakeDrawn dA = new FakeDrawn("A");
            check(ga.finish(cA, dA) && dA.released, "5c: A hands off to C");
            GlyphsAhead.Claim<TestSlot> cC = claim(ga);
            check(cC != null && cC.bit == (1 << 2) && cC.scale == 3f && cC.faces == 2, "5c: C claimed");
            FakeDrawn dC = new FakeDrawn("C");
            ga.finish(cC, dC);
            check(ga.takeDrawn(e, 2, 3f, 2) == dC && ga.aheadCount == 0, "5c: C consumed, count=0");
        }

        // 5d: Pending completely cancelled by foreground before A finishes -> A finish decrements aheadCount to 0.
        {
            GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
            List<TestSlot> entries = new ArrayList<>();
            entries.add(new TestSlot(0));
            TestSlot e = entries.get(0);

            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 0);
            GlyphsAhead.Claim<TestSlot> cA = claim(ga);
            ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 1);
            check(ga.takeDrawn(e, 0, 2f, 1) == null && e.pendingWant == 0, "5d: pending fully cancelled");
            FakeDrawn dA = new FakeDrawn("A");
            check(!ga.finish(cA, dA) && dA.released && ga.aheadCount == 0, "5d: count decremented to 0");
        }

        // 5e: A finish(result=null) (OOM) still hands off pending B normally.
        {
            GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
            List<TestSlot> entries = new ArrayList<>();
            entries.add(new TestSlot(0));
            TestSlot e = entries.get(0);

            ga.ahead(entries, new int[] {key(0, 0)}, 1, 1f, 1, 0);
            GlyphsAhead.Claim<TestSlot> cA = claim(ga);
            ga.ahead(entries, new int[] {key(0, 1)}, 1, 2f, 1, 1);
            check(ga.finish(cA, null) && ga.aheadCount == 1, "5e: OOM null finish still hands off B");
            GlyphsAhead.Claim<TestSlot> cB = claim(ga);
            check(cB != null && cB.bit == (1 << 1) && cB.scale == 2f, "5e: B claimed after null finish");
            FakeDrawn dB = new FakeDrawn("B");
            ga.finish(cB, dB);
            check(ga.takeDrawn(e, 1, 2f, 1) == dB && ga.aheadCount == 0, "5e: B consumed, count=0");
        }
    }

    /** 6. Consecutive keysSweep with detached in-flight entry preserves exact aheadCount (never drifts negative). */
    static void consecutiveSweepsPreserveCount() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        entries.add(new TestSlot(1));

        ga.ahead(entries, new int[] {key(0, 0), key(1, 0)}, 2, 2f, 1, 0);
        GlyphsAhead.Claim<TestSlot> c0 = claim(ga); // entry 0 in flight; entry 1 still queued
        check(ga.aheadCount == 2, "count=2 before sweep 1");

        // Sweep 1: entry 0 stays counted (drawing), entry 1 drops -> aheadCount=1.
        ga.forget(entries);
        entries.clear();
        check(ga.aheadCount == 1, "count=1 after sweep 1");

        // Sweep 2 while detached entry 0 is STILL drawing: must keep count=1 for detached entry 0!
        entries.add(new TestSlot(2));
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 2, 1);
        check(ga.aheadCount == 2, "count=2 with detached entry 0 + new entry 2");
        ga.forget(entries);
        entries.clear();
        check(ga.aheadCount == 1, "count=1 after sweep 2 (detached entry 0 preserved)");

        // Detached entry 0 worker finally finishes -> released and aheadCount drops cleanly to 0.
        FakeDrawn d0 = new FakeDrawn("detached");
        ga.finish(c0, d0);
        check(d0.released && ga.aheadCount == 0, "detached finish releases and brings count to exact 0");
    }

    /** 7. Two workers concurrently drawing two phases of the same entry share 1 slot until both finish & are taken. */
    static void twoWorkersSameEntryConcurrent() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        TestSlot e = entries.get(0);

        ga.ahead(entries, new int[] {key(0, 0), key(0, 1)}, 2, 2f, 1, 0);
        check(ga.aheadCount == 1, "single slot for multi-phase entry");
        GlyphsAhead.Claim<TestSlot> w1 = claim(ga);
        GlyphsAhead.Claim<TestSlot> w2 = claim(ga);
        check(w1 != null && w2 != null && w1.bit != w2.bit, "two workers claimed distinct phases");
        // Drain any remaining phases via takeDrawn so only w1 & w2 keep the entry active.
        ga.takeDrawn(e, 2, 2f, 1);
        ga.takeDrawn(e, 3, 2f, 1);
        check(ga.aheadCount == 1, "still 1 while both workers drawing");

        FakeDrawn d1 = new FakeDrawn("w1");
        FakeDrawn d2 = new FakeDrawn("w2");
        ga.finish(w1, d1);
        check(ga.aheadCount == 1, "still 1 after first worker finishes");
        check(ga.takeDrawn(e, Integer.numberOfTrailingZeros(w1.bit), 2f, 1) == d1, "took w1 result");
        check(ga.aheadCount == 1, "still 1 while second worker drawing");
        ga.finish(w2, d2);
        check(ga.aheadCount == 1, "still 1 until w2 result taken");
        check(ga.takeDrawn(e, Integer.numberOfTrailingZeros(w2.bit), 2f, 1) == d2, "took w2 result");
        check(ga.aheadCount == 0, "count=0 once both finished and taken");
    }

    /** 8. Full capacity: later already-asked items still unskip/promote, and later stale (drawing==0) frees own slot. */
    static void fullCapacityDoesNotSkipAskedOrStale() {
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 2);
        List<TestSlot> entries = new ArrayList<>();
        for (int i = 0; i < 4; i++) entries.add(new TestSlot(i));

        // Fill capacity=2 with entry 0 (in-flight + rest phase 2) and entry 1 (stale at scale 1f, drawing==0).
        ga.ahead(entries, new int[] {key(0, 0), key(0, 1)}, 2, 2f, 1, 0);
        GlyphsAhead.Claim<TestSlot> c0 = claim(ga); // phase 0 of entry 0 in flight; phase 1/2/3 still in want
        check(ga.takeDrawn(entries.get(0), 0, 2f, 1) == null, "mark phase 0 of entry 0 skipped");
        // Entry 1 at scale 1f, queued (drawing==0).
        ga.ahead(entries, new int[] {key(1, 0)}, 1, 1f, 1, 0);
        check(ga.aheadCount == 2, "at full capacity 2 (nothing in drawnAhead to evict)");

        // Batch at scale 2f: [entry 2 (new, cannot fit), entry 0 phase 0 (unskip), entry 0 phase 2 (promote to first),
        //                     entry 1 phase 0 (stale drawing==0 -> frees own slot and enqueues at scale 2f)].
        boolean any = ga.ahead(entries, new int[] {key(2, 0), key(0, 0), key(0, 2), key(1, 0)}, 4, 2f, 1, 1);
        check(any, "batch woke workers");
        check(!ga.asked(entries.get(2)), "entry 2 skipped due to full capacity");
        check((entries.get(0).skip & 1) == 0, "entry 0 phase 0 unskipped despite full capacity");
        check((entries.get(0).first & (1 << 2)) != 0, "entry 0 phase 2 promoted to first despite full capacity");
        check(ga.asked(entries.get(1)) && entries.get(1).askScale == 2f && ga.aheadCount == 2,
                "stale entry 1 freed its own slot and re-enqueued at scale 2f");

        // Clean up
        FakeDrawn d0 = new FakeDrawn("e0p0");
        ga.finish(c0, d0);
        check(!d0.released && ga.takeDrawn(entries.get(0), 0, 2f, 1) == d0, "unskipped e0p0 preserved");
    }

    /** 9. Per-slot slotGen change (same scale, same faces) invalidates drawn results and triggers deferred handoff. */
    static void slotGenInvalidationAndDeferredHandoff() {
        final int[] slotGen = {1};
        GlyphsAhead<TestSlot, FakeDrawn> ga = new GlyphsAhead<>(FakeDrawn::release, 16, s -> slotGen[0]);
        List<TestSlot> entries = new ArrayList<>();
        entries.add(new TestSlot(0));
        TestSlot e = entries.get(0);

        // (a) Drawn result at slotGen=1 is stale when taken at slotGen=2 (same scale, same faces): released, count=0.
        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "slotGen=1 enqueued");
        GlyphsAhead.Claim<TestSlot> c1 = claim(ga);
        check(c1 != null && c1.slotGen == 1, "claimed with slotGen=1");
        FakeDrawn d1 = new FakeDrawn("sg1");
        ga.finish(c1, d1);
        slotGen[0] = 2;
        check(ga.takeDrawn(e, 0, 2f, 1, 2) == null, "takeDrawn at slotGen=2 rejects slotGen=1 result");
        check(d1.released && ga.aheadCount == 0, "stale slotGen=1 result released and aheadCount=0");

        // (b) In-flight worker at slotGen=2 -> slotGen bumps to 3 -> deferred handoff releases old, dispatches slotGen=3.
        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "slotGen=2 enqueued");
        GlyphsAhead.Claim<TestSlot> c2 = claim(ga);
        check(c2 != null && c2.slotGen == 2 && ga.aheadCount == 1, "claimed with slotGen=2");
        slotGen[0] = 3;
        ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0);
        check(e.pendingSlotGen == 3 && e.pendingWant == 1 && ga.aheadCount == 1, "deferred handoff queued for slotGen=3");
        FakeDrawn d2 = new FakeDrawn("sg2-stale");
        check(ga.finish(c2, d2) && d2.released && ga.aheadCount == 1, "old slotGen=2 released and handed off");
        GlyphsAhead.Claim<TestSlot> c3 = claim(ga);
        check(c3 != null && c3.slotGen == 3 && c3.bit == 1, "re-claimed with slotGen=3");
        FakeDrawn d3 = new FakeDrawn("sg3-fresh");
        check(!ga.finish(c3, d3) && !d3.released, "slotGen=3 stored");
        check(ga.takeDrawn(e, 0, 2f, 1, 3) == d3 && ga.aheadCount == 0, "slotGen=3 consumed and aheadCount=0");

        // (c) Warm all 4 phases at slotGen=3, consume all -> bump to slotGen=4 (same scale/faces/gen):
        //     phase 0 resets subsQueued (does NOT expand 1..3), then phase 1 triggers moved expansion of 1..3.
        check(ga.ahead(entries, new int[] {key(0, 1)}, 1, 2f, 1, 0), "slotGen=3 phase 1 triggers expansion 1..3");
        for (int s = 1; s < 4; s++) {
            GlyphsAhead.Claim<TestSlot> c = claim(ga);
            check(c != null && c.slotGen == 3, "slotGen=3 phase " + s + " claimed");
            ga.finish(c, new FakeDrawn("sg3-p" + s));
            check(ga.takeDrawn(e, Integer.numberOfTrailingZeros(c.bit), 2f, 1, 3) != null, "slotGen=3 phase taken");
        }
        check(e.subsQueued == GlyphsAhead.SUB_ALL && ga.aheadCount == 0, "all 4 phases warmed & consumed at slotGen=3");

        slotGen[0] = 4;
        check(ga.ahead(entries, new int[] {key(0, 0)}, 1, 2f, 1, 0), "slotGen=4 phase 0 enqueued");
        check(e.queuedSlotGen == 4 && e.subsQueued == 1 && e.want == 1,
                "slotGen=4 phase 0 resets subsQueued and does not expand 1..3");
        GlyphsAhead.Claim<TestSlot> c40 = claim(ga);
        check(c40 != null && c40.slotGen == 4 && c40.bit == 1, "slotGen=4 phase 0 claimed");
        ga.finish(c40, new FakeDrawn("sg4-p0"));

        check(ga.ahead(entries, new int[] {key(0, 1)}, 1, 2f, 1, 0), "slotGen=4 phase 1 enqueued");
        check(e.want == ((1 << 1) | (1 << 2) | (1 << 3)), "slotGen=4 phase 1 triggers moved expansion of 1..3");
        for (int s = 1; s < 4; s++) {
            GlyphsAhead.Claim<TestSlot> c = claim(ga);
            check(c != null && c.slotGen == 4, "slotGen=4 phase " + s + " claimed");
            ga.finish(c, new FakeDrawn("sg4-p" + s));
        }
        for (int s = 0; s < 4; s++) {
            check(ga.takeDrawn(e, s, 2f, 1, 4) != null, "slotGen=4 phase " + s + " taken");
        }
        check(ga.aheadCount == 0, "slotGen=4 all 4 phases consumed, aheadCount=0");
    }

    public static void main(String[] args) {
        evictionReenqueue();
        movedExpandsRemainingPhases();
        skipRaceBothOrders();
        resetBackfillsSubsQueuedForInFlight();
        staleDeferredHandoffSuite();
        consecutiveSweepsPreserveCount();
        twoWorkersSameEntryConcurrent();
        fullCapacityDoesNotSkipAskedOrStale();
        slotGenInvalidationAndDeferredHandoff();
        if (failed > 0) {
            System.err.println("GlyphsAheadTest: " + failed + " failed");
            System.exit(1);
        }
        System.out.println("GlyphsAheadTest: ok");
    }
}
