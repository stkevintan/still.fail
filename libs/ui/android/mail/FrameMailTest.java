package dev.mbui;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * MBView's two threads' hand-over (FrameMail) step by step, the two threads' turns said by the test, the native frame
 * waiting (android_host.c, frame_mail.h) as a pending flag: what the GL thread takes, in what order the GL context's
 * tasks run, when what lets go of a frame's pictures runs, and what of the frames made for a GL context gone is drawn.
 * Nothing reads a clock or starts a thread. Run: scripts/framemail_test.sh.
 */
public final class FrameMailTest {
    private static int failed;

    private static void check(boolean ok, String what) {
        if (ok) return;
        failed++;
        StackTraceElement at = new Throwable().getStackTrace()[1];
        System.err.println("FrameMailTest.java:" + at.getLineNumber() + ": failed: " + what);
    }

    /** The native side and the rest, as a log of what was asked of them. */
    static final class Native implements FrameMail.Frames<String> {
        boolean made, pending;
        int published, takenShown, takenUnshown, droppedPending, frames;
        final List<String> glyphsDropped = new ArrayList<>();
        final List<String> merges = new ArrayList<>();
        final List<String> log;

        Native(List<String> log) {
            this.log = log;
        }

        /** The app's thread made a frame that presents (mb_host_present). */
        void present() {
            made = true;
        }

        @Override public boolean publish() {
            if (!made) return false;
            made = false;
            pending = true;
            published++;
            return true;
        }

        @Override public boolean take(boolean shown) {
            if (!pending) return false;
            pending = false;
            if (shown) takenShown++;
            else takenUnshown++;
            return true;
        }

        @Override public void dropPending() {
            pending = false;
            droppedPending++;
        }

        @Override public int built() {
            return frames++;
        }

        @Override public void merged(int from, int to) {
            merges.add(from + ">" + to);
        }

        @Override public String frameName() {
            return null;
        }

        @Override public void dropped(List<String> glyphs) {
            glyphsDropped.addAll(glyphs);
        }

        @Override public void failed(RuntimeException e) {
            log.add("failed " + e.getMessage());
        }
    }

    private static List<String> glyphs(String... g) {
        return new ArrayList<>(Arrays.asList(g));
    }

    /** A frame the app made and handed over. */
    private static boolean frame(FrameMail<String> m, Native n, long shows, String... g) {
        n.present();
        return m.handOver(shows, glyphs(g), false);
    }

    /** The GL thread draws (MBView.drawOnGl): tasks before the frame, the frame, what it retires, the tasks after. */
    private static FrameMail.Taken<String> draw(FrameMail<String> m, List<String> log) {
        FrameMail.Taken<String> t = m.take();
        if (t.took) m.runTasks(t.seq);
        log.add(t.took ? "draw" : "redraw");
        m.runAll(t.retire);
        m.runTasks(m.pendingSeqNow());
        return t;
    }

    /** Two frames handed over before the GL thread takes one: one drawn, the newest, with both's glyphs in order. */
    static void newestDrawn() {
        List<String> log = new ArrayList<>();
        Native n = new Native(log);
        FrameMail<String> m = new FrameMail<>(n);
        m.contextTold(m.contextMade());
        check(frame(m, n, 10, "a", "b"), "the first handed over");
        check(frame(m, n, 20, "c"), "the second handed over");
        check(n.merges.equals(List.of("0>1")), "the first's latency frame merged into the second's: " + n.merges);
        FrameMail.Taken<String> t = m.take();
        check(t.took && n.takenShown == 1, "one taken");
        check(t.glyphs.equals(List.of("a", "b", "c")), "both's glyphs, in order: " + t.glyphs);
        check(t.shows == 20 && t.lat == 1, "shown when the second is, its latency frame");
        check(!m.take().took, "none left");
        check(m.takeDropped() == 1, "the first, never drawn, counted dropped");
        check(m.takeDropped() == 0, "read once: none since");
        // (one that presents nothing: no frame, its glyphs left for the next, counted as made)
        long made = m.made();
        List<String> placed = glyphs("d");
        check(!m.handOver(30, placed, false), "nothing presented, nothing handed over");
        check(placed.equals(List.of("d")) && m.made() == made + 1, "its glyphs kept for the next, a frame made");
    }

    /** The GL context's tasks in their order among the frames. */
    static void tasksAmongFrames() {
        List<String> log = new ArrayList<>();
        Native n = new Native(log);
        FrameMail<String> m = new FrameMail<>(n);
        m.contextTold(m.contextMade());
        m.task(() -> log.add("t1"));
        frame(m, n, 0, "a");
        m.task(() -> log.add("t2"));
        m.runTasks(m.pendingSeqNow());
        check(log.equals(List.of("t1")), "before the frame pending, at once; not after it: " + log);
        draw(m, log);
        check(log.equals(List.of("t1", "draw", "t2")), "the one after it once it is drawn: " + log);
        m.task(() -> {
            throw new RuntimeException("t3");
        });
        m.task(() -> log.add("t4"));
        m.runTasks(m.pendingSeqNow());
        check(log.equals(List.of("t1", "draw", "t2", "failed t3", "t4")), "a task's failure said, the next run: " + log);
    }

    /**
     * What lets go of a frame's pictures (a picture freed, a native view dropped, a stream closed) runs only once a frame
     * made after it is on the screen: not while the frame kept is drawn again, nor as the GL thread's queue runs, nor
     * as a frame is taken only to read back.
     */
    static void retiredOnceShown() {
        List<String> log = new ArrayList<>();
        Native n = new Native(log);
        FrameMail<String> m = new FrameMail<>(n);
        m.contextTold(m.contextMade());
        frame(m, n, 0);
        draw(m, log);
        // frame 1 on the screen; frame 2 being made frees what 1 draws
        m.retire(() -> log.add("free 42"));
        m.task(() -> log.add("t"));
        m.runTasks(m.pendingSeqNow());
        draw(m, log);
        check(m.redrawAsked(5, false), "a native view's picture changed");
        draw(m, log);
        check(log.equals(List.of("draw", "t", "redraw", "redraw")), "not while frame 1 is drawn again: " + log);
        // (and not with a frame that presents nothing)
        m.handOver(6, glyphs(), false);
        draw(m, log);
        check(!log.contains("free 42"), "not with a frame that presents nothing: " + log);
        frame(m, n, 7);
        draw(m, log);
        check(log.subList(log.size() - 2, log.size()).equals(List.of("draw", "free 42")),
                "once frame 2 is drawn, after it: " + log);

        // frame 3, made after a let go, taken to read back: not on the screen till drawn; then let go, whether it is
        // drawn again (the read back's frame owed) or the next is taken
        log.clear();
        m.retire(() -> log.add("free 43"));
        frame(m, n, 8);
        FrameMail.Taken<String> s = m.takeForSync();
        check(s.took && n.takenUnshown == 1 && m.redrawOwed(), "taken to read back, owed a drawing");
        m.runTasks(m.pendingSeqNow());
        check(log.isEmpty(), "not as it is read back: " + log);
        FrameMail.Taken<String> t = draw(m, log);
        check(!t.took && t.redraw && t.shows == 8, "drawn as the frame owed, when it was to be shown");
        check(log.equals(List.of("redraw", "free 43")), "let go once it is drawn: " + log);
        log.clear();
        m.retire(() -> log.add("free 44"));
        frame(m, n, 9);
        m.takeForSync();
        m.retire(() -> log.add("free 45"));
        frame(m, n, 10);
        draw(m, log);
        check(log.equals(List.of("draw", "free 44", "free 45")), "or the next taken: " + log);
    }

    /**
     * A GL context made anew: the frame waiting, made with glyphs in the atlas gone, let go undrawn, and so is each the
     * app's thread hands over till it is told; none of them counts as made for the new one; the first after is drawn.
     */
    static void contextAnew() {
        List<String> log = new ArrayList<>();
        Native n = new Native(log);
        FrameMail<String> m = new FrameMail<>(n);
        m.contextTold(m.contextMade());
        frame(m, n, 0, "a");
        long made = m.made();
        check(m.redrawAsked(1, false), "a redraw owed");
        long gen = m.contextMade();
        check(!m.pending() && n.droppedPending == 1, "the frame waiting let go");
        check(!m.redrawOwed(), "the frame kept owed nothing");
        check(n.glyphsDropped.equals(List.of("a")), "its glyphs let go: " + n.glyphsDropped);
        // (the app's thread, not told yet, hands over a frame it laid out for the old atlas)
        check(!frame(m, n, 2, "b"), "a frame made before it was told not handed over");
        check(!m.pending() && n.droppedPending == 2 && n.glyphsDropped.equals(List.of("a", "b")), "let go, its glyphs too");
        check(!m.redrawAsked(3, false), "the frame kept not drawn again for it");
        check(m.made() == made + 1, "none counted made for the new context");
        check(!m.take().took, "nothing for the GL thread");
        m.contextTold(gen);
        check(frame(m, n, 4, "c"), "the first made after it was told handed over");
        check(m.made() == made + 2, "counted");
        FrameMail.Taken<String> t = m.take();
        check(t.took && t.glyphs.equals(List.of("c")) && t.shows == 4, "and drawn");
    }

    /**
     * The frames never drawn, each's place taken by a newer one while it waited, counted as they are: not one taken to
     * read back, nor one that presents nothing, nor a redraw of the frame kept; read and put back at once.
     */
    static void droppedCounted() {
        List<String> log = new ArrayList<>();
        Native n = new Native(log);
        FrameMail<String> m = new FrameMail<>(n);
        m.contextTold(m.contextMade());
        frame(m, n, 0);
        draw(m, log);
        check(m.takeDropped() == 0, "one handed over, drawn: none dropped");
        // three handed over while the GL thread draws none of them: the first two's places taken
        frame(m, n, 1);
        frame(m, n, 2);
        frame(m, n, 3);
        check(m.takeDropped() == 2, "two never drawn");
        draw(m, log);
        check(m.takeDropped() == 0, "the newest drawn: none more");
        // (nor one presenting nothing, a redraw of the frame kept, one taken to read back and drawn as owed)
        m.handOver(4, glyphs(), false);
        check(m.redrawAsked(5, false), "a redraw");
        frame(m, n, 6);
        m.takeForSync();
        frame(m, n, 7);
        draw(m, log);
        check(m.takeDropped() == 0, "none of those dropped");
    }

    /**
     * Per-frame paced flag ownership: newer handOver overwrites older pendingPaced (no OR), redrawAsked carries its own
     * redrawPaced, takeForSync transfers pendingPaced to redrawPaced, took overwrites redrawPaced, and contextMade clears both.
     */
    static void pacedOwnership() {
        List<String> log = new ArrayList<>();
        Native n = new Native(log);
        FrameMail<String> m = new FrameMail<>(n);
        m.contextTold(m.contextMade());

        // A=true overwritten by B=false -> draw B sees paced=false.
        n.present();
        check(m.handOver(10, glyphs("a"), true), "A handed over paced=true");
        n.present();
        check(m.handOver(20, glyphs("b"), false), "B handed over paced=false");
        FrameMail.Taken<String> t1 = m.take();
        check(t1.took && !t1.paced, "A=true overwritten by B=false -> paced=false");

        // A=false overwritten by B=true -> draw B sees paced=true.
        n.present();
        check(m.handOver(30, glyphs("c"), false), "A handed over paced=false");
        n.present();
        check(m.handOver(40, glyphs("d"), true), "B handed over paced=true");
        FrameMail.Taken<String> t2 = m.take();
        check(t2.took && t2.paced, "A=false overwritten by B=true -> paced=true");

        // redrawAsked(true) and redrawAsked(false).
        check(m.redrawAsked(50, true), "redrawAsked true");
        FrameMail.Taken<String> t3 = m.take();
        check(!t3.took && t3.redraw && t3.paced, "redraw takes redrawPaced=true");
        check(m.redrawAsked(60, false), "redrawAsked false");
        FrameMail.Taken<String> t4 = m.take();
        check(!t4.took && t4.redraw && !t4.paced, "redraw takes redrawPaced=false");
        // Plain expose (!took && !redraw) has paced=false.
        FrameMail.Taken<String> tIdle = m.take();
        check(!tIdle.took && !tIdle.redraw && !tIdle.paced, "idle take has paced=false");

        // takeForSync transfers pendingPaced -> redrawPaced.
        n.present();
        check(m.handOver(70, glyphs("e"), true), "handed over paced=true for sync");
        FrameMail.Taken<String> sync = m.takeForSync();
        check(sync.took, "takeForSync took pending");
        FrameMail.Taken<String> t5 = m.take();
        check(!t5.took && t5.redraw && t5.paced, "owed redraw after takeForSync inherits paced=true");

        // took overwrites redrawPaced (redrawPaced=true, then handOver(..., false) -> take sees paced=false).
        check(m.redrawAsked(80, true), "redrawAsked true before newer frame");
        n.present();
        check(m.handOver(90, glyphs("f"), false), "newer non-paced frame");
        FrameMail.Taken<String> t6 = m.take();
        check(t6.took && !t6.paced, "took overwrites redrawPaced");
        FrameMail.Taken<String> t7 = m.take();
        check(!t7.took && !t7.redraw && !t7.paced, "redrawPaced cleared after took");

        // contextMade drops the pending paced=true frame and redraw; subsequent take() neither takes nor redraws, with paced=false.
        n.present();
        check(m.handOver(100, glyphs("g"), true), "pending paced=true before contextMade");
        check(m.redrawAsked(110, true), "redraw paced=true before contextMade");
        long gen = m.contextMade();
        m.contextTold(gen);
        FrameMail.Taken<String> t8 = m.take();
        check(!t8.took && !t8.redraw && !t8.paced, "contextMade dropped pending paced frame and redraw (paced=false)");
    }

    public static void main(String[] args) {
        newestDrawn();
        droppedCounted();
        tasksAmongFrames();
        retiredOnceShown();
        contextAnew();
        pacedOwnership();
        if (failed > 0) {
            System.err.println("FrameMailTest: " + failed + " failed");
            System.exit(1);
        }
        System.out.println("FrameMailTest: ok");
    }
}
