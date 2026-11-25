package dev.mbui;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/**
 * What MBView's two threads hand each other, under its lock (this object): the frame waiting (the newest the app's
 * thread made and the GL thread has not drawn), the GL thread's queue, and what is let go once the screen no longer
 * shows what used it. Its state alone, no Android: android/mail/FrameMailTest.java runs it on a plain JVM
 * (scripts/framemail_test.sh).
 *
 * <ul>
 *   <li>A frame handed over (handOver) while the one before still waits takes its place (the native frames: android_host.c,
 *   frame_mail.h), its glyphs after the other's, the other's latency run's events its own; the one whose place it took,
 *   never on the screen, counted (takeDropped).
 *   <li>What the app asks of the GL context (task) is numbered among the frames: done before the frame handed over after
 *   it is drawn, after the one handed over before it.
 *   <li>What lets go of what a frame draws (retire: a picture's texture, a native view's, a stream's) is done only once
 *   a frame made after it was asked is drawn on the screen: the frame kept until then (drawn again as a native view's
 *   picture changes, or as the surface asks) still draws it. A frame taken for a read back (takeForSync) is not on the
 *   screen until the next drawn.
 *   <li>A GL context made anew (contextMade) has none of the glyphs a frame made before it put in the atlases: the
 *   frame waiting is let go, and those the app's thread hands over till it was told (contextTold, after it let go of
 *   what it kept of the old atlas) too; none of them counts as a frame made for the new context (awaitFresh).
 * </ul>
 */
final class FrameMail<G> {
    /** What it asks of the rest: the native frame waiting, the latency run, the glyphs. */
    interface Frames<G> {
        /** The frame made handed over (Native.publish): whether there was one. */
        boolean publish();

        /** The frame pending taken (Native.take): to be drawn, or only read back. */
        boolean take(boolean shown);

        /** The frame pending let go undrawn (Native.dropPending). */
        void dropPending();

        /** The frame handed over counted in a latency run (Latency.frameBuilt): its number, -1 none. */
        int built();

        /** Frame {@code from} of a latency run never drawn, {@code to} drawn in its place (Latency.merged). */
        void merged(int from, int to);

        /** The picture asked of the frame handed over (MBText.takeFrameName): null none. */
        String frameName();

        /** Glyphs of a frame let go undrawn: their pictures let go. */
        void dropped(List<G> glyphs);

        /** What a task threw, said (GL thread). */
        void failed(RuntimeException e);
    }

    /** What the GL thread took to draw (take) or to read back (takeForSync). */
    static final class Taken<G> {
        /** A frame taken (else the one kept drawn again). */
        boolean took;
        /** The frame kept was owed a drawing (a native view's picture changed, or it was taken for a read back). */
        boolean redraw;
        /** Its number among the tasks: those before it done first. */
        long seq = -1;
        /** When it is to be shown (FramePacer's), 0 none said. */
        long shows;
        /** The glyphs to put in the atlases before it is drawn. */
        ArrayList<G> glyphs;
        /** The picture asked of it (MBText.refFrame), null none. */
        String ref;
        /** Its frame of a latency run, -1 none. */
        int lat = -1;
        /** Whether this frame was handed over under an active low-rate paced vote. */
        boolean paced;
        /** Done once it is drawn: what the frames it took the place of on the screen no longer use. */
        final ArrayList<Runnable> retire = new ArrayList<>();
    }

    private static final class Task {
        final long seq;
        final Runnable r;

        Task(long seq, Runnable r) {
            this.seq = seq;
            this.r = r;
        }
    }

    private final Frames<G> f;

    FrameMail(Frames<G> f) {
        this.f = f;
    }

    // the number of each task and frame handed over; the frame pending's (-1: none), its glyphs, when it is shown, the
    // picture asked of it, its frame of a latency run
    private long seq;
    private final ArrayDeque<Task> tasks = new ArrayDeque<>();
    private long pendingSeq = -1;
    private ArrayList<G> pendingGlyphs = new ArrayList<>();
    private long pendingShows;
    private String pendingRef;
    private int pendingLat = -1;
    private boolean pendingPaced;
    // the frame kept owed a drawing, when it is shown then, the picture asked of it, its frame of a latency run
    private boolean redrawOwed;
    private long redrawShows;
    private String redrawRef;
    private int redrawLat = -1;
    private boolean redrawPaced;
    // what is let go once a frame made after it is shown: asked since the last frame handed over; with the frames
    // handed over and not drawn; owed the next drawn (the frame that no longer uses it taken for a read back)
    private ArrayList<Runnable> retiring = new ArrayList<>();
    private ArrayList<Runnable> pendingRetire = new ArrayList<>();
    private ArrayList<Runnable> owedRetire = new ArrayList<>();
    // the GL context's count (GL thread), and the one the app's thread was told of
    private long contextGen, appGen;
    /** How many frames the app's thread made for the context now (handed over or not: one that presents nothing too). */
    private long made;
    /** How many frames handed over took the place of one still waiting, never drawn, since takeDropped last read. */
    private int dropped;

    // ---- the app's thread ----

    /** {@code r} on the GL thread's queue, after the frames handed over before it, before those handed over after. */
    synchronized void task(Runnable r) {
        tasks.add(new Task(++seq, r));
    }

    /** {@code r} done on the GL thread once a frame handed over after it is drawn on the screen (retire, above). */
    synchronized void retire(Runnable r) {
        retiring.add(r);
    }

    /**
     * The frame the app made handed over (as it ends), to be shown at {@code shows}, with the glyphs it put in the
     * atlases ({@code placed}: taken, the list cleared) and its {@code paced} ownership: whether it presented one, to
     * be drawn. {@code pendingPaced} is overwritten per frame (like {@code pendingShows}, never ORed) so an undrawn
     * paced frame replaced by a newer interactive frame never masks real GPU backpressure; {@link MBView} passes
     * {@code pacedBefore || pacedNow} to cover the single-frame asynchronous transition entering or leaving 20 Hz.
     */
    synchronized boolean handOver(long shows, List<G> placed, boolean paced) {
        if (appGen != contextGen) {
            // (made before the app's thread was told of the GL context now: its glyphs are in an atlas gone)
            if (f.publish()) f.dropPending();
            f.dropped(new ArrayList<>(placed));
            placed.clear();
            return false;
        }
        made++;
        // (a new surface's GL thread waiting for the app's frame: awaitFresh, whether or not this one presented)
        notifyAll();
        if (!f.publish()) return false;
        int lat = f.built();
        // (the frame waiting, never drawn: its place taken by this one)
        if (pendingSeq >= 0) dropped++;
        if (pendingLat >= 0) {
            if (lat >= 0) f.merged(pendingLat, lat);
            else lat = pendingLat;
        }
        pendingSeq = ++seq;
        pendingShows = shows;
        pendingLat = lat;
        pendingPaced = paced;
        pendingGlyphs.addAll(placed);
        placed.clear();
        String ref = f.frameName();
        if (ref != null) pendingRef = ref;
        pendingRetire.addAll(retiring);
        retiring.clear();
        return true;
    }

    /** Only a native view's picture changed: the frame kept drawn again, at {@code shows}; whether it is to be. */
    synchronized boolean redrawAsked(long shows, boolean paced) {
        // (the frame kept is of the GL context before: the app's own for this one comes)
        if (appGen != contextGen) return false;
        int lat = f.built();
        redrawOwed = true;
        redrawShows = shows;
        redrawPaced = paced;
        if (redrawLat >= 0) f.merged(redrawLat, lat);
        redrawLat = lat;
        made++;
        notifyAll();
        return true;
    }

    /** The app's thread told of GL context {@code gen} (contextMade's), what it kept of the one before let go. */
    synchronized void contextTold(long gen) {
        appGen = gen;
        notifyAll();
    }

    // ---- the GL thread ----

    /**
     * A GL context made anew, its atlases empty (GL thread): the frame waiting let go undrawn, the frame kept owed
     * nothing; the context's count, to tell the app's thread (contextTold) once it let go of what it kept of the old.
     */
    synchronized long contextMade() {
        if (pendingSeq >= 0) {
            f.dropPending();
            f.dropped(pendingGlyphs);
            pendingGlyphs = new ArrayList<>();
            pendingSeq = -1;
            pendingRef = null;
            // (its latency run's events the next frame's: pendingLat kept; what it was to let go, the next's)
        }
        pendingPaced = false;
        redrawOwed = false;
        redrawPaced = false;
        return ++contextGen;
    }

    /**
     * Waits up to {@code ms} for a frame of the app's for the context now, unless one is already there to draw (a new
     * surface's first, one at a new size: drawn rather than the frame kept).
     */
    synchronized void awaitFresh(int ms) {
        if (ms <= 0 || pendingSeq >= 0 || redrawOwed) return;
        long until = System.nanoTime() + ms * 1_000_000L, from = made;
        for (long left = ms; pendingSeq < 0 && made == from && left > 0; left = (until - System.nanoTime()) / 1_000_000L) {
            try {
                wait(left);
            } catch (InterruptedException e) {
                break;
            }
        }
    }

    /** The frame to draw (GL thread): the one pending taken, else the frame kept, and what is let go once it is drawn. */
    synchronized Taken<G> take() {
        Taken<G> t = new Taken<>();
        t.took = pendingSeq >= 0 && f.take(true);
        if (t.took) {
            t.seq = pendingSeq;
            pendingSeq = -1;
            t.glyphs = pendingGlyphs;
            pendingGlyphs = new ArrayList<>();
            t.shows = pendingShows;
            t.ref = pendingRef != null ? pendingRef : redrawRef;
            pendingRef = null;
            t.lat = pendingLat;
            pendingLat = -1;
            t.paced = pendingPaced;
            pendingPaced = false;
            redrawPaced = false;
        }
        t.redraw = redrawOwed;
        redrawOwed = false;
        if (!t.took && t.redraw) {
            t.shows = redrawShows;
            t.ref = redrawRef;
            t.lat = redrawLat;
            t.paced = redrawPaced;
            redrawPaced = false;
        } else {
            if (!t.took) t.paced = false;
            redrawPaced = false;
            if (redrawLat >= 0) {
                f.merged(redrawLat, t.lat);
            }
        }
        redrawRef = null;
        redrawLat = -1;
        // (the frame taken shown: what the ones before it used is no longer on the screen once it is drawn; the frame
        // kept, drawn again, still draws what was asked to go with a frame not drawn yet)
        t.retire.addAll(owedRetire);
        owedRetire.clear();
        if (t.took) {
            t.retire.addAll(pendingRetire);
            pendingRetire.clear();
        }
        return t;
    }

    /**
     * The frame pending taken to read back (GL thread, the app's thread waiting: glSync), drawn on the screen as the next
     * frame (owed a drawing), what it lets go owed that one.
     */
    synchronized Taken<G> takeForSync() {
        Taken<G> t = new Taken<>();
        t.took = pendingSeq >= 0 && f.take(false);
        if (!t.took) return t;
        t.seq = pendingSeq;
        pendingSeq = -1;
        t.glyphs = pendingGlyphs;
        pendingGlyphs = new ArrayList<>();
        t.lat = pendingLat;
        pendingLat = -1;
        redrawOwed = true;
        redrawShows = pendingShows;
        redrawPaced = pendingPaced;
        pendingPaced = false;
        if (pendingRef != null) redrawRef = pendingRef;
        pendingRef = null;
        owedRetire.addAll(pendingRetire);
        pendingRetire.clear();
        return t;
    }

    /**
     * How many frames handed over were never drawn, each's place taken by a newer one as it waited (the GL thread slower
     * than the app's thread makes them), since this was last read: read and put back to none at once (MBView, as the GL
     * thread draws).
     */
    synchronized int takeDropped() {
        int n = dropped;
        dropped = 0;
        return n;
    }

    /** The number of the frame pending, or past every task where there is none: the tasks before it may run now. */
    synchronized long pendingSeqNow() {
        return pendingSeq >= 0 ? pendingSeq : Long.MAX_VALUE;
    }

    /** The tasks numbered before {@code upto} done, in their order (GL thread); each one's failure said, not thrown. */
    void runTasks(long upto) {
        while (true) {
            Task t;
            synchronized (this) {
                t = tasks.peek();
                if (t == null || t.seq >= upto) return;
                tasks.poll();
            }
            run(t.r);
        }
    }

    /** {@code rs} done in their order (GL thread); each one's failure said, not thrown. */
    void runAll(List<Runnable> rs) {
        for (Runnable r : rs) run(r);
    }

    private void run(Runnable r) {
        try {
            r.run();
        } catch (RuntimeException e) {
            f.failed(e);
        }
    }

    // ---- read by its test ----

    synchronized long made() {
        return made;
    }

    synchronized boolean pending() {
        return pendingSeq >= 0;
    }

    synchronized boolean redrawOwed() {
        return redrawOwed;
    }
}
