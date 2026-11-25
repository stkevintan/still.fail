package dev.mbui;

import java.util.ArrayDeque;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.function.ToIntFunction;

/**
 * Pure Java state machine for background glyph rasterization ahead of paint ({@link MBText}):
 * first phases are prioritized in {@link #askedFirst}, extra phases spread breadth-first in {@link #askedRest},
 * completed bitmaps sit in {@link #drawnAhead} (FIFO eviction past {@link #aheadMost}), and scale/face changes
 * hand off cleanly to pending work once in-flight workers finish. Zero Android dependencies so it runs under
 * {@code javac -Xlint:all -Werror} in {@code scripts/glyphsahead_test.sh}.
 */
final class GlyphsAhead<S extends GlyphsAhead.Slot<D>, D> {
    static final int SUB_COUNT = 4;
    static final int SUB_ALL = 0x0F;
    static final int AHEAD_MOST = 1024;

    interface Releaser<D> {
        void release(D d);
    }

    /** Per-glyph slot embedded directly in {@link MBText.Entry} (zero extra allocation). */
    static class Slot<D> {
        // Guarded by GlyphsAhead.lock:
        int want, drawing, have, first, skip;
        boolean inFirst, inRest, listed;
        final Object[] drawn = new Object[SUB_COUNT];
        float askScale;
        int askFaces;
        int askSlotGen;
        // Deferred handoff when a stale entry still has in-flight workers (guarded by lock):
        int pendingWant, pendingFirst;
        float pendingScale;
        int pendingFaces;
        int pendingSlotGen;
        // App-thread-only history (worker finish() must NEVER read or write these fields):
        int subsQueued;
        float queuedScale;
        int queuedFaces;
        int queuedGen;
        int queuedSlotGen;
    }

    /** Single phase claimed by a worker thread under {@link #lock}. */
    static final class Claim<S> {
        final S slot;
        final int bit;
        final float scale;
        final int faces;
        final int slotGen;

        Claim(S slot, int bit, float scale, int faces, int slotGen) {
            this.slot = slot;
            this.bit = bit;
            this.scale = scale;
            this.faces = faces;
            this.slotGen = slotGen;
        }
    }

    /** A glyph key's quarter-pixel phase (bits 26..27), 0 for none. */
    static int glyphSub(int fullKey) {
        int sub = fullKey >= 0 ? (fullKey >>> 26) & 7 : 0;
        return sub < SUB_COUNT ? sub : 0;
    }

    final Object lock = new Object();
    final ArrayDeque<S> askedFirst = new ArrayDeque<>();
    final ArrayDeque<S> askedRest = new ArrayDeque<>();
    final LinkedHashSet<S> drawnAhead = new LinkedHashSet<>();
    final int aheadMost;
    int aheadCount;

    private final Releaser<D> releaser;
    private final ToIntFunction<S> slotGenOf;

    GlyphsAhead(Releaser<D> releaser) {
        this(releaser, AHEAD_MOST, s -> 0);
    }

    GlyphsAhead(Releaser<D> releaser, int aheadMost) {
        this(releaser, aheadMost, s -> 0);
    }

    GlyphsAhead(Releaser<D> releaser, int aheadMost, ToIntFunction<S> slotGenOf) {
        this.releaser = releaser;
        this.aheadMost = aheadMost;
        this.slotGenOf = slotGenOf;
    }

    @SuppressWarnings("unchecked")
    private D drawnAt(S e, int sub) {
        return (D) e.drawn[sub];
    }

    /** Whether {@code e} currently holds a slot in {@link #aheadCount} (under lock). */
    boolean asked(S e) {
        return (e.want | e.drawing | e.have) != 0;
    }

    /** Queues or updates a batch of glyph keys for background rasterization (app thread). */
    boolean ahead(List<S> entries, int[] ks, int n, float sc, int faces, int generation) {
        boolean any = false;
        synchronized (lock) {
            for (int i = 0; i < n; i++) {
                int k = ks[i] >= 0 ? ks[i] & 0x03FFFFFF : -1;
                if (k < 0 || k >= entries.size()) continue;
                S e = entries.get(k);
                int bit = 1 << glyphSub(ks[i]);
                int sg = slotGenOf.applyAsInt(e);
                if (e.queuedScale != sc || e.queuedFaces != faces || e.queuedGen != generation || e.queuedSlotGen != sg) {
                    e.subsQueued = 0;
                    e.queuedScale = sc;
                    e.queuedFaces = faces;
                    e.queuedGen = generation;
                    e.queuedSlotGen = sg;
                }
                boolean moved = e.subsQueued != 0 && (e.subsQueued & bit) == 0;
                int want = moved ? (SUB_ALL & ~e.subsQueued) : bit;
                if (enqueueLocked(e, want, bit, sc, faces, sg)) any = true;
            }
            if (any) lock.notifyAll();
        }
        return any;
    }

    /** Queues extra phases of a single glyph after first phases (app thread). */
    boolean aheadOne(S e, int want, float sc, int faces) {
        boolean any;
        synchronized (lock) {
            any = enqueueLocked(e, want, 0, sc, faces, slotGenOf.applyAsInt(e));
            if (any) lock.notify();
        }
        return any;
    }

    private boolean enqueueLocked(S e, int want, int firstBit, float sc, int faces, int sg) {
        if (asked(e)) {
            if (e.askScale == sc && e.askFaces == faces && e.askSlotGen == sg) {
                // Case 1: active at the same scale/faces/slotGen. Clear any stale deferred handoff (A->B->A).
                e.pendingWant = 0;
                e.pendingFirst = 0;
                e.pendingSlotGen = 0;
                int unskip = want & e.drawing & e.skip;
                if (unskip != 0) e.skip &= ~unskip;
                boolean woke = false;
                int add = want & ~(e.want | e.drawing | e.have);
                if (add != 0) {
                    e.want |= add;
                    int addFirst = add & firstBit;
                    if (addFirst != 0) {
                        e.first |= addFirst;
                        if (!e.inFirst) {
                            e.inFirst = true;
                            askedFirst.add(e);
                        }
                    }
                    if ((add & ~addFirst) != 0 && !e.inRest) {
                        e.inRest = true;
                        askedRest.add(e);
                    }
                    woke = true;
                }
                if (firstBit != 0 && (e.want & firstBit) != 0 && (e.first & firstBit) == 0) {
                    e.first |= firstBit;
                    if (!e.inFirst) {
                        e.inFirst = true;
                        askedFirst.add(e);
                    }
                    woke = true;
                }
                e.subsQueued |= want;
                return woke;
            }
            // Case 2: stale scale/faces/slotGen. Drop stale buffered bitmaps and queued work.
            dropDrawn(e);
            removeListed(e);
            e.want = 0;
            e.first = 0;
            if (e.drawing != 0) {
                e.skip |= e.drawing;
                if (want != 0) {
                    if (e.pendingWant != 0 && e.pendingScale == sc && e.pendingFaces == faces && e.pendingSlotGen == sg) {
                        e.pendingWant |= want;
                        e.pendingFirst |= (want & firstBit);
                    } else {
                        e.pendingScale = sc;
                        e.pendingFaces = faces;
                        e.pendingSlotGen = sg;
                        e.pendingWant = want;
                        e.pendingFirst = want & firstBit;
                    }
                    e.subsQueued |= want;
                } else {
                    e.pendingWant = 0;
                    e.pendingFirst = 0;
                    e.pendingSlotGen = 0;
                }
                return false;
            }
            e.pendingWant = 0;
            e.pendingFirst = 0;
            e.pendingSlotGen = 0;
            aheadCount--;
            // Fall through to Case 3 (now inactive).
        }
        // Case 3: idle or freshly released stale slot.
        if (want == 0) return false;
        if (!roomAhead()) return false;
        ask(e, want, want & firstBit, sc, faces, sg);
        return true;
    }

    private void ask(S e, int want, int first, float sc, int faces, int sg) {
        e.want = want;
        e.first = first;
        e.askScale = sc;
        e.askFaces = faces;
        e.askSlotGen = sg;
        e.subsQueued |= want;
        if (first != 0 && !e.inFirst) {
            e.inFirst = true;
            askedFirst.add(e);
        }
        if ((want & ~first) != 0 && !e.inRest) {
            e.inRest = true;
            askedRest.add(e);
        }
        aheadCount++;
    }

    private boolean roomAhead() {
        while (aheadCount >= aheadMost) {
            if (!dropOldestDrawn()) return false;
        }
        return true;
    }

    private void dropDrawn(S e) {
        for (int s = 0; s < SUB_COUNT; s++) {
            D d = drawnAt(e, s);
            if (d != null) releaser.release(d);
            e.drawn[s] = null;
        }
        e.have = 0;
    }

    private void removeListed(S e) {
        if (e.listed) {
            drawnAhead.remove(e);
            e.listed = false;
        }
    }

    private boolean dropOldestDrawn() {
        Iterator<S> it = drawnAhead.iterator();
        if (!it.hasNext()) return false;
        S e = it.next();
        it.remove();
        e.listed = false;
        e.subsQueued &= ~(e.have | e.want);
        dropDrawn(e);
        e.want = 0;
        e.first = 0;
        if (!asked(e)) aheadCount--;
        return true;
    }

    /** Takes a pre-rasterized phase if ready, or cancels/skips queued/in-flight work (app thread). */
    D takeDrawn(S e, int sub, float sc, int faces) {
        return takeDrawn(e, sub, sc, faces, slotGenOf.applyAsInt(e));
    }

    /** Takes a pre-rasterized phase if ready at the given {@code slotGen}, or cancels/skips queued/in-flight work. */
    D takeDrawn(S e, int sub, float sc, int faces, int slotGen) {
        int bit = 1 << sub;
        synchronized (lock) {
            if (e.pendingWant != 0 && e.pendingScale == sc && e.pendingFaces == faces && e.pendingSlotGen == slotGen) {
                e.pendingWant &= ~bit;
                e.pendingFirst &= ~bit;
            }
            if (!asked(e)) return null;
            if (e.askScale != sc || e.askFaces != faces || e.askSlotGen != slotGen) {
                dropDrawn(e);
                removeListed(e);
                e.want = 0;
                e.first = 0;
                if (e.drawing != 0) e.skip |= e.drawing;
                else aheadCount--;
                return null;
            }
            if ((e.want & bit) != 0) {
                e.want &= ~bit;
                e.first &= ~bit;
                if (!asked(e)) aheadCount--;
                return null;
            }
            if ((e.drawing & bit) != 0) {
                e.skip |= bit;
                return null;
            }
            if ((e.have & bit) == 0) return null;
            D d = drawnAt(e, sub);
            e.drawn[sub] = null;
            e.have &= ~bit;
            if (e.have == 0) removeListed(e);
            if (!asked(e)) aheadCount--;
            return d;
        }
    }

    /** Non-blocking single-step claim for a worker or test (caller holds {@link #lock}). */
    Claim<S> claimNext() {
        while (true) {
            S e = askedFirst.poll();
            int bit;
            if (e != null) {
                e.inFirst = false;
                int firsts = e.want & e.first;
                bit = Integer.lowestOneBit(firsts);
                if ((firsts & ~bit) != 0) {
                    e.inFirst = true;
                    askedFirst.addFirst(e);
                }
            } else {
                e = askedRest.poll();
                if (e == null) return null;
                e.inRest = false;
                int rest = e.want & ~e.first;
                bit = Integer.lowestOneBit(rest);
                if ((rest & ~bit) != 0) {
                    e.inRest = true;
                    askedRest.addLast(e);
                }
            }
            if (bit != 0) {
                e.want &= ~bit;
                e.first &= ~bit;
                e.drawing |= bit;
                e.skip &= ~bit;
                return new Claim<>(e, bit, e.askScale, e.askFaces, e.askSlotGen);
            }
        }
    }

    /**
     * Completes a worker claim (worker thread). Never reads or writes app-thread history fields.
     * Returns {@code true} when a deferred pending request was handed off and queued.
     */
    boolean finish(Claim<S> c, D result) {
        S e = c.slot;
        int bit = c.bit;
        int s = Integer.numberOfTrailingZeros(bit);
        synchronized (lock) {
            e.drawing &= ~bit;
            boolean skipped = (e.skip & bit) != 0;
            e.skip &= ~bit;
            boolean stale = e.askScale != c.scale || e.askFaces != c.faces || e.askSlotGen != c.slotGen;
            if (result != null) {
                if (skipped || stale) {
                    releaser.release(result);
                } else {
                    D prev = drawnAt(e, s);
                    if (prev != null) releaser.release(prev);
                    e.drawn[s] = result;
                    e.have |= bit;
                    if (!e.listed) {
                        e.listed = true;
                        drawnAhead.add(e);
                    }
                }
            }
            if (e.drawing == 0 && e.pendingWant != 0) {
                e.askScale = e.pendingScale;
                e.askFaces = e.pendingFaces;
                e.askSlotGen = e.pendingSlotGen;
                e.want = e.pendingWant;
                e.first = e.pendingFirst;
                e.pendingWant = 0;
                e.pendingFirst = 0;
                e.pendingSlotGen = 0;
                if (e.first != 0 && !e.inFirst) {
                    e.inFirst = true;
                    askedFirst.add(e);
                }
                if ((e.want & ~e.first) != 0 && !e.inRest) {
                    e.inRest = true;
                    askedRest.add(e);
                }
                lock.notifyAll();
                return true;
            }
            if (!asked(e)) aheadCount--;
            return false;
        }
    }

    /**
     * Forgets all queued and drawn-ahead state for {@code entries} (scale/face change or key sweep).
     * Decrements {@link #aheadCount} only for entries transitioning active -> inactive so detached
     * in-flight entries from an earlier sweep keep their count until their workers finish.
     */
    void forget(List<S> entries) {
        synchronized (lock) {
            for (S e : askedFirst) e.inFirst = false;
            askedFirst.clear();
            for (S e : askedRest) e.inRest = false;
            askedRest.clear();
            for (S e : drawnAhead) e.listed = false;
            drawnAhead.clear();
            for (int i = 0, n = entries.size(); i < n; i++) {
                S e = entries.get(i);
                boolean wasAsked = asked(e);
                if (e.drawing != 0) e.skip |= e.drawing;
                dropDrawn(e);
                e.want = 0;
                e.first = 0;
                e.pendingWant = 0;
                e.pendingFirst = 0;
                e.pendingSlotGen = 0;
                if (wasAsked && !asked(e)) aheadCount--;
            }
        }
    }
}
