package dev.mbui;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.PriorityQueue;

/**
 * MBView's pacing (FramePacer) on a clock of the test's own: the display's vsyncs on a grid, the main thread's queue
 * and Choreographer's callbacks, the drawing thread's frames (their work), the GPU behind it and the surface's buffers
 * as SurfaceFlinger takes them at the vsyncs (a buffer shown no sooner than the time eglPresentationTimeANDROID said).
 * What the app asks for is said by each run: a motion (every frame asks for the next until it ends), keys struck. The
 * same run gives the same frames on every machine: nothing reads the machine's clock or its threads.
 *
 * What is asserted is what a person sees: while the app asks for a frame at each vsync, each refresh shows a new one
 * (a refresh with none is a stutter), and the surface says the display's highest rate while something moves and while
 * the field is typed into. Run: scripts/framepacer_test.sh.
 */
public final class FramePacerTest {
    // ---- the simulated phone ----

    /** What the app does in a frame built for {@code now} (ms): its work on the drawing thread and the GPU's (ms), and
     * whether it asks for another. */
    interface App {
        double work(int frame, double now);

        double gpu(int frame, double now);

        boolean more(int frame, double now);

        /** The rate what moves on by the clock alone needs, said by the frame (MBView.framesPaced; 0 none): its next
         * woken for, at the vsync before the one that many frames a second on (MBView.wakeAt). */
        default float paced(int frame, double now) {
            return 0;
        }
    }

    static final class Event implements Comparable<Event> {
        final long at;
        final long seq;
        final Runnable run;

        Event(long at, long seq, Runnable run) {
            this.at = at;
            this.seq = seq;
            this.run = run;
        }

        @Override
        public int compareTo(Event o) {
            return at != o.at ? Long.compare(at, o.at) : Long.compare(seq, o.seq);
        }
    }

    static final class Phone implements FramePacer.Platform {
        final double hz;
        final long period;
        /** how many buffers SurfaceFlinger's queue holds for the surface, the one shown among them (triple buffering) */
        final int buffers;
        /** whether eglSwapBuffers waits for the frame before's GPU work (a driver that throttles so) */
        final boolean swapWaitsGpu;
        /** how long after requestRender the drawing thread begins the frame (ns) */
        final long wake;
        final FramePacer pacer;
        App app;
        boolean typing;
        /** whether GL adaptive glass is currently settling */
        boolean glSettling;
        /** whether a native view's picture recently redrew */
        boolean pictureActive;
        /** optional LTPO display model: framePeriod switches to 1/rate when rate > 0 */
        boolean ltpo;
        /** decouples producer from swap blocking so mailbox overwrites (swapDrops) are observable */
        boolean mailboxDrops;
        /** if > 0, next N Platform.setRate calls fail (return false) */
        int failNextSetRate;
        /** optional test hook: ignore setRate calls and pin SurfaceFlinger at the given rate (> 0) for negative controls */
        float pinRate;
        /** optional callback invoked right after pacer.ended() in drawFrame with (externalDemand, rate) */
        java.util.function.BiConsumer<Boolean, Float> onFrameEnded;

        long now;
        long lastVsyncAt;
        long seq;
        final PriorityQueue<Event> events = new PriorityQueue<>();
        boolean onMain;
        /** Choreographer's callbacks for the next vsync (posted on the main thread) */
        List<Runnable> nextVsync = new ArrayList<>();
        /** Optional CALLBACK_INSETS_ANIMATION hook run in the same doFrame after nextVsync callbacks. */
        Runnable onInsets;
        int vsyncPosts;
        /** the drawing thread: busy until, its queued events (queueEvent), a frame requested */
        long drawingFree;
        long blockedSince = -1;
        long swapWaitMaxNs;
        int swapDrops;
        final ArrayDeque<Runnable> drawingQueue = new ArrayDeque<>();
        boolean renderRequested;
        boolean drawingScheduled;
        long gpuFree;
        long gpuLastEnd;
        /** buffers queued and not yet shown: each its ready time and the time it may be shown from */
        final ArrayDeque<long[]> queued = new ArrayDeque<>();
        int frames;
        /** the vsyncs (their index) each showed a new frame at; the app's frames' work (ms), by frame */
        final List<Long> shownAt = new ArrayList<>();
        final List<double[]> drawn = new ArrayList<>();
        /** the rate said, as it changed: (time ns, rate) */
        final List<double[]> rates = new ArrayList<>();
        float rate;

        Phone(double hz, int buffers, boolean swapWaitsGpu, long wake) {
            this.hz = hz;
            this.period = Math.round(1e9 / hz);
            this.buffers = buffers;
            this.swapWaitsGpu = swapWaitsGpu;
            this.wake = wake;
            this.pacer = new FramePacer(this);
            pacer.framePeriod = period;
            pacer.topRate = (float) hz;
            // the display's vsyncs, from the first after 0
            at(period, this::vsync);
        }

        void at(long t, Runnable r) {
            events.add(new Event(t, seq++, r));
        }

        void main(long t, Runnable r) {
            at(t, () -> {
                onMain = true;
                r.run();
                onMain = false;
            });
        }

        void runUntil(long end) {
            while (!events.isEmpty() && events.peek().at <= end) {
                Event e = events.poll();
                now = e.at;
                e.run.run();
            }
            now = end;
        }

        long currentPeriod() {
            return ltpo && rate > 0 ? Math.round(1e9 / rate) : period;
        }

        /** A vsync: what SurfaceFlinger shows at it, then Choreographer's callbacks on the main thread. */
        void vsync() {
            long v = now;
            lastVsyncAt = v;
            long idx = v / period;
            long sfStep = ltpo ? 1 : (rate > 0 ? Math.max(1, Math.round(hz / rate)) : 1);
            // SurfaceFlinger pulls a buffer at the voted refresh cadence
            if ((idx % sfStep == 0) && !queued.isEmpty()) {
                long[] b = queued.peek();
                if (b[0] <= v && b[1] <= v) {
                    queued.poll();
                    shownAt.add(idx);
                    bufferFreed();
                }
            }
            List<Runnable> cbs = nextVsync;
            nextVsync = new ArrayList<>();
            onMain = true;
            for (Runnable r : cbs) r.run();
            if (onInsets != null) onInsets.run();
            onMain = false;
            at(v + currentPeriod(), this::vsync);
        }

        long vsyncTime() {
            return lastVsyncAt != 0 ? lastVsyncAt : (now / period) * period;
        }

        void scheduleWake(double baseMs, double delayMs, boolean pacedOnly) {
            double atMs = baseMs + delayMs;
            FramePacer.WakeReq req = pacer.scheduleWake(atMs, pacedOnly);
            if (req == null) return;
            double leadMs = atMs - now / 1e6 - 2 * (pacer.framePeriod / 1e6);
            long fireAt = now + Math.round(Math.max(0.0, leadMs) * 1e6);
            main(fireAt, () -> wakeAt(req));
        }

        void wakeAt(FramePacer.WakeReq req) {
            if (!pacer.isWakeCurrent(req)) return;
            Runnable cb = new Runnable() {
                @Override
                public void run() {
                    if (pacer.fireWake(req, lastVsyncAt, lastVsyncAt + 2 * currentPeriod()) == 1) {
                        nextVsync.add(this);
                    }
                }
            };
            nextVsync.add(cb);
        }

        // ---- FramePacer.Platform ----

        @Override public long nanoTime() { return now; }

        @Override public boolean onMain() { return onMain; }

        @Override public void postMain(Runnable r) { main(now, r); }

        @Override public void postVsync() {
            vsyncPosts++;
            // Android 13's: told with its preferred timeline, shown two vsyncs on (the app's frame deadline)
            nextVsync.add(() -> pacer.vsyncCame(vsyncTime(), vsyncTime() + 2 * currentPeriod()));
        }

        @Override public void atNextVsyncOnDrawing(Runnable r) {
            main(now, () -> nextVsync.add(() -> {
                drawingQueue.add(r);
                kickDrawing();
            }));
        }

        int renderRequests;

        @Override public void requestRender() {
            renderRequests++;
            renderRequested = true;
            kickDrawing();
        }

        @Override public boolean setRate(float r) {
            if (failNextSetRate > 0) {
                failNextSetRate--;
                return false;
            }
            if (pinRate > 0) {
                rate = pinRate;
                rates.add(new double[] {now, pinRate});
                return true;
            }
            rate = r;
            if (ltpo) pacer.framePeriod = r > 0 ? Math.round(1e9 / r) : period;
            rates.add(new double[] {now, r});
            return true;
        }

        @Override public boolean typing() { return typing; }

        @Override public boolean glSettling() { return glSettling; }

        @Override public boolean pictureActive() { return pictureActive; }

        void postDrawing(Runnable r) {
            drawingQueue.add(r);
            kickDrawing();
        }

        // ---- the drawing thread ----

        void kickDrawing() {
            if (drawingScheduled || drawingFree == BLOCKED) return;
            if (drawingQueue.isEmpty() && !renderRequested) return;
            drawingScheduled = true;
            at(Math.max(now + wake, drawingFree), this::drawingStep);
        }

        void drawingStep() {
            drawingScheduled = false;
            if (drawingFree > now) {
                kickDrawing();
                return;
            }
            // GLSurfaceView's guarded run: queued events first, then a frame where one is requested
            while (!drawingQueue.isEmpty()) drawingQueue.poll().run();
            if (renderRequested) {
                renderRequested = false;
                drawFrame();
            }
            kickDrawing();
        }

        static final long BLOCKED = Long.MAX_VALUE / 4;

        /** MBView.onDrawFrame's app frame (not a picture alone, not a shot): its work, then eglSwapBuffers. */
        void drawFrame() {
            FramePacer.Taken tk = pacer.takeRender();
            if (!tk.app && !tk.pictured) return;
            long[] vat = tk.vsyncAt;
            if (tk.pictured && !tk.app) {
                pacer.redrawn();
                return;
            }
            long began = now;
            FramePacer.Begun b = pacer.begin(vat, began, tk.external);
            pacer.clearWake();
            int f = frames++;
            double work = app.work(f, b.now);
            boolean more = app.more(f, b.now);
            float paced = app.paced(f, b.now);
            long cpuEnd = began + Math.round(work * 1e6);
            // (the thread busy with it till its work is done: what comes meanwhile, a vsync, comes as it works)
            drawingFree = cpuEnd;
            at(cpuEnd, () -> {
                if (paced > 0) {
                    long every = Math.max(1, Math.round(hz / paced));
                    scheduleWake(b.now, (every - 0.5) * 1000.0 / hz, true);
                }
                pacer.ended(more, false, b.following, paced, b.externalDemand);
                if (onFrameEnded != null) onFrameEnded.accept(b.externalDemand, rate);
                // the GPU draws it after the frame before's; swapped, the buffer is queued
                long gpuStart = Math.max(cpuEnd, gpuFree);
                long gpuEnd = gpuStart + Math.round(app.gpu(f, b.now) * 1e6);
                gpuFree = gpuEnd;
                long swapDone = swapWaitsGpu ? Math.max(cpuEnd, gpuLastEnd) : cpuEnd;
                gpuLastEnd = gpuEnd;
                long showFrom = b.shows != 0 ? b.shows - currentPeriod() / 2 : 0;
                if (queued.size() >= buffers) {
                    queued.poll();
                    swapDrops++;
                }
                queued.add(new long[] {gpuEnd, showFrom});
                drawn.add(new double[] {b.now, work});
                // (a buffer to draw the next into: the queue holds `buffers`, one of them shown)
                if (!mailboxDrops && queued.size() >= buffers - 1) {
                    drawingFree = BLOCKED;
                    blockedSince = cpuEnd;
                } else {
                    drawingFree = swapDone;
                }
                kickDrawing();
            });
        }

        /** A buffer shown frees one: the drawing thread waiting on it goes on. */
        void bufferFreed() {
            if (drawingFree == BLOCKED && queued.size() < buffers - 1) {
                if (blockedSince >= 0) {
                    swapWaitMaxNs = Math.max(swapWaitMaxNs, now - blockedSince);
                    blockedSince = -1;
                }
                drawingFree = now;
                kickDrawing();
            }
        }
    }

    // ---- runs ----

    /** The refreshes from {@code from} until {@code to} (ns) that showed no new frame (their vsyncs' index). */
    static List<Long> missed(Phone ph, long from, long to) {
        List<Long> out = new ArrayList<>();
        long first = from / ph.period + 1, last = to / ph.period;
        int i = 0;
        for (long k = first; k <= last; k++) {
            while (i < ph.shownAt.size() && ph.shownAt.get(i) < k) i++;
            if (i >= ph.shownAt.size() || ph.shownAt.get(i) != k) out.add(k);
        }
        return out;
    }

    /** A motion from {@code start} for {@code ms}: each frame `work` and `gpu` (ms), asking for the next while it goes. */
    static Phone motion(Phone ph, double startMs, double ms, App app) {
        ph.app = app;
        long start = Math.round(startMs * 1e6);
        ph.main(start, ph.pacer::wantFrame);
        ph.runUntil(start + Math.round((ms + 200) * 1e6));
        return ph;
    }

    static App steady(double work, double gpu, double untilMs) {
        return new App() {
            @Override public double work(int f, double now) { return work; }

            @Override public double gpu(int f, double now) { return gpu; }

            @Override public boolean more(int f, double now) { return now < untilMs; }
        };
    }

    static int failures;

    static void check(String what, boolean ok, String said) {
        System.out.println((ok ? "ok   " : "FAIL ") + what + (said.isEmpty() ? "" : ": " + said));
        if (!ok) failures++;
    }

    /**
     * The known list: what is wrong now and known, run and said every run (KNOWN). Its count `now` is to be the one it
     * was `owed` at when it was found: worse fails, and so does better (mended: bring `owed` down to it, at 0 take it
     * off the list and assert it). The list only gets shorter.
     */
    static void owed(String what, int now, int owed, String said) {
        String verdict = now > owed ? "FAIL (worse) " : now < owed ? "FAIL (better: owed " + owed + " → " + now + ") " : "KNOWN ";
        System.out.println(verdict + what + ": " + now + (said.isEmpty() ? "" : ", " + said));
        if (now != owed) failures++;
    }

    /** A motion of `work` and `gpu` a frame at 120 Hz for a second: the refreshes it left with no new frame. */
    static void motionCase(String what, double work, double gpu, boolean swapWaitsGpu) {
        Phone ph = new Phone(120, 3, swapWaitsGpu, 200_000);
        double start = 100, ms = 1000;
        motion(ph, start, ms, steady(work, gpu, start + ms));
        // (from its third refresh: the first frame is asked for as the motion starts, shown two vsyncs on)
        List<Long> miss = missed(ph, Math.round((start + 4 * 8.34) * 1e6), Math.round((start + ms) * 1e6));
        check(what, miss.isEmpty(), miss.size() + " of " + Math.round(ms / 8.333) + " refreshes with no new frame"
                + (miss.isEmpty() ? "" : ", first at vsync " + miss.get(0)) + "; frames drawn " + ph.drawn.size());
    }

    /** Frames' work as a phone's PERF said it (devperf2: t, work, present ms a line): each run of frames drawn one
     * after another (under 60 ms apart) replayed as a motion, its frames' work theirs, the GPU's `gpu` each. */
    static void replay(String file, double gpu) throws IOException {
        List<double[]> rows = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new FileReader(file))) {
            for (String line; (line = r.readLine()) != null; ) {
                String[] p = line.trim().split("\\s+");
                if (p.length >= 3) rows.add(new double[] {Double.parseDouble(p[0]), Double.parseDouble(p[1]), Double.parseDouble(p[2])});
            }
        }
        // runs of frames each under 60 ms after the one before
        int totalRefreshes = 0, totalMissed = 0, cheapMissed = 0, phoneMissed = 0, phoneCheap = 0;
        int i = 0;
        while (i < rows.size()) {
            int j = i + 1;
            while (j < rows.size() && rows.get(j)[0] - rows.get(j - 1)[0] < 60) j++;
            if (j - i >= 10) {
                for (int k = i + 1; k < j; k++) {
                    double d = rows.get(k)[0] - rows.get(k - 1)[0];
                    if (d > 12) {
                        phoneMissed++;
                        if (rows.get(k - 1)[1] + rows.get(k - 1)[2] < 4) phoneCheap++;
                    }
                }
                double[] work = new double[j - i];
                for (int k = i; k < j; k++) work[k - i] = rows.get(k)[1] + rows.get(k)[2];
                double ms = rows.get(j - 1)[0] - rows.get(i)[0];
                Phone ph = new Phone(120, 3, true, 200_000);
                double start = 100;
                motion(ph, start, ms, new App() {
                    @Override public double work(int f, double now) { return work[Math.min(f, work.length - 1)]; }

                    @Override public double gpu(int f, double now) { return gpu; }

                    @Override public boolean more(int f, double now) { return now < start + ms; }
                });
                List<Long> miss = missed(ph, Math.round((start + 4 * 8.34) * 1e6), Math.round((start + ms) * 1e6));
                totalRefreshes += (int) Math.round(ms / 8.333);
                totalMissed += miss.size();
                // of those, the frame drawn before it took under 4 ms
                for (long k : miss) {
                    double before = 0;
                    for (double[] dr : ph.drawn) if (dr[0] * 1e6 < k * ph.period) before = dr[1];
                    if (before < 4) cheapMissed++;
                }
            }
            i = j;
        }
        owed("devperf2's frames replayed, GPU " + gpu + " ms a frame: refreshes with no new frame after a frame under 4 ms",
                cheapMissed, gpu <= 1 ? 1 : 5, totalMissed + " of " + totalRefreshes + " with none at all (the phone: "
                        + phoneMissed + ", " + phoneCheap + " after one under 4 ms)");
    }

    /** Keys struck into the field every `every` ms (no motion of the app's): the rate said for each key's frame. */
    static void typingCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.typing = true;
        ph.app = steady(1.0, 1.0, -1);
        ph.main(Math.round(50e6), ph.pacer::typingChanged);
        for (int k = 0; k < 10; k++) ph.main(Math.round((100 + 120 * k) * 1e6), ph.pacer::wantFrame);
        ph.runUntil(Math.round(1400e6));
        check("typing: the display's highest rate said while the field is typed into", ph.rate == 120f,
                "rate " + ph.rate + ", said " + ph.rates.size() + " times");
    }

    /** After a motion: the rate kept for a second (the next flick does not climb back to it), then let go. */
    static void rateAfterMotion() {
        Phone ph = new Phone(120, 3, true, 200_000);
        motion(ph, 100, 300, steady(1.0, 1.0, 400));
        float during = ph.rate;
        ph.runUntil(Math.round((400 + 900) * 1e6));
        float soon = ph.rate;
        ph.runUntil(Math.round((400 + 1300) * 1e6));
        check("a motion's rate: the highest while it moves, kept a second after it", during == 120f && soon == 120f,
                "moving " + during + ", 0.9 s after " + soon);
        check("a motion's rate let go 1.3 s after it", ph.rate == 0f, "1.3 s after " + ph.rate);
    }

    /** A spinner whose frames say they need 30 a second (frame_pace.mbt): that rate said, and as many frames drawn. */
    static void pacedCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1; }

            @Override public double gpu(int f, double now) { return 1; }

            @Override public boolean more(int f, double now) { return false; }

            @Override public float paced(int f, double now) { return now < 1100 ? 30 : 0; }
        };
        ph.main(Math.round(100e6), ph.pacer::wantFrame);
        ph.runUntil(Math.round(1050e6));
        float during = ph.rate;
        int frames = ph.drawn.size();
        check("a motion paced at 30 Hz: that rate said of the display, about 30 frames a second drawn",
                during == 30f && frames >= 28 && frames <= 30, "rate " + during + ", " + frames + " frames in 0.95 s");
    }

    /** A keyboard step (frameNow) right after a picture-only frame still lays out the app rather than redrawing. */
    static void frameNowAfterPictureCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = steady(1.0, 1.0, -1);
        final boolean[] wantedAfterFrameNow = {false};
        ph.main(Math.round(50e6), () -> {
            ph.pacer.pictureFrame();
            ph.pacer.frameNow();
            wantedAfterFrameNow[0] = ph.pacer.appWanted.get();
        });
        ph.runUntil(Math.round(120e6));
        check("frameNow after pictureFrame sets appWanted and draws an app frame",
                wantedAfterFrameNow[0] && ph.drawn.size() == 1,
                "appWanted=" + wantedAfterFrameNow[0] + ", frames drawn=" + ph.drawn.size());
    }

    /** Keyboard animation pre-warmed with sayRate(true) runs at topRate from before frame 1 and drops after it ends. */
    static void imeWarmupRateCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = steady(1.0, 1.0, -1);
        final float[] rateBeforeFirstFrame = {0f};
        // Pre-warm on drawing thread (MBView.imeMovingStarted) before the first WindowInsetsAnimation.onProgress step
        ph.at(Math.round(50e6), () -> {
            ph.drawingQueue.add(() -> ph.pacer.sayRate(true));
            ph.kickDrawing();
        });
        ph.main(Math.round(60e6), () -> rateBeforeFirstFrame[0] = ph.rate);
        long firstStep = Math.round(60e6);
        for (int k = 0; k < 10; k++) {
            ph.main(firstStep + k * ph.period, ph.pacer::frameNow);
        }
        long afterSteps = firstStep + 10 * ph.period;
        ph.runUntil(afterSteps);
        float rateDuring = ph.rate;
        int framesDuring = ph.drawn.size();
        // Animation ends and keyboard is not shown (typingChanged lets the rate go after a second)
        ph.at(afterSteps + ph.period, () -> {
            ph.typing = false;
            ph.drawingQueue.add(ph.pacer::typingChanged);
            ph.kickDrawing();
        });
        ph.runUntil(afterSteps + Math.round(1300e6));
        check("IME warmup: topRate before frame 1, held across frameNow sequence, released after end",
                rateBeforeFirstFrame[0] == 120f && rateDuring == 120f && framesDuring == 10 && ph.rate == 0f,
                "before=" + rateBeforeFirstFrame[0] + ", during=" + rateDuring
                        + ", frames=" + framesDuring + ", after=" + ph.rate);
    }

    /** IME inset animation + ongoing app animation coalesces CALLBACK_ANIMATION and CALLBACK_INSETS_ANIMATION into 1 frame/vsync. */
    static void imeMovingWithAnimationCoalescesCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long firstV = 12;
        long imeSteps = 25;
        long postSteps = 10;
        long endV = firstV + imeSteps + postSteps;
        ph.app = steady(3.0, 3.0, (endV * ph.period) / 1e6 - 0.1);
        ph.main(firstV * ph.period - ph.period / 2, () -> {
            ph.pacer.setImeMoving(true);
            ph.pacer.wantFrame();
        });
        ph.onInsets = () -> {
            long k = ph.now / ph.period;
            if (k >= firstV && k < firstV + imeSteps) {
                ph.pacer.frameNow();
                if (k == firstV + imeSteps - 1) ph.pacer.setImeMoving(false);
            }
        };
        ph.runUntil((endV + 6) * ph.period);
        int imeFrames = 0;
        double imeStartMs = (firstV * ph.period) / 1e6 - 0.1;
        double imeEndMs = ((firstV + imeSteps - 1) * ph.period) / 1e6 + 0.1;
        for (double[] d : ph.drawn) {
            if (d[0] >= imeStartMs && d[0] <= imeEndMs) imeFrames++;
        }
        List<Long> miss = missed(ph, (firstV + 2) * ph.period - 1, (endV + 1) * ph.period);
        check("IME moving with animation coalesces to 1 frame/vsync with 0 missed refreshes",
                miss.isEmpty() && imeFrames == imeSteps,
                "imeFrames=" + imeFrames + "/" + imeSteps + ", missed=" + miss.size()
                        + (miss.isEmpty() ? "" : " (first=" + miss.get(0) + ")") + ", totalDrawn=" + ph.drawn.size());
    }

    /** When imeMoving is true but some vsyncs emit no onProgress, flushDeferredVsync falls back with 0 missed refreshes. */
    static void imeMovingWithoutProgressFallsBackCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long firstV = 12;
        long steps = 25;
        long endV = firstV + steps;
        ph.app = steady(3.0, 3.0, (endV * ph.period) / 1e6 - 0.1);
        ph.main(firstV * ph.period - ph.period / 2, () -> {
            ph.pacer.setImeMoving(true);
            ph.pacer.wantFrame();
        });
        ph.onInsets = () -> {
            long k = ph.now / ph.period;
            if (k >= firstV && k < endV && (k % 2 == 0)) {
                ph.pacer.frameNow();
            }
            if (k == endV - 1) ph.pacer.setImeMoving(false);
        };
        ph.runUntil((endV + 6) * ph.period);
        List<Long> miss = missed(ph, (firstV + 2) * ph.period - 1, (endV + 1) * ph.period);
        check("IME moving without onProgress on some vsyncs falls back with 0 missed refreshes",
                miss.isEmpty() && ph.drawn.size() == steps + 1,
                "drawn=" + ph.drawn.size() + "/" + (steps + 1) + ", missed=" + miss.size()
                        + (miss.isEmpty() ? "" : " (first=" + miss.get(0) + ")"));
    }

    /** frameNow when a postVsync is already pending does not clear wanted and does not duplicate next vsync callback. */
    static void frameNowDoesNotDuplicatePendingVsyncCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long nextV = 12;
        // Return more=true on frame 0 (drawn by frameNow), false on frame 1 (drawn by vsync #12)
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }

            @Override public double gpu(int f, double now) { return 1.0; }

            @Override public boolean more(int f, double now) { return f == 0; }
        };
        final int[] postsBeforeNextVsync = {0};
        final int[] callbacksAtNextVsync = {0};
        ph.main(11 * ph.period + 1_000_000, ph.pacer::wantFrame);
        ph.main(11 * ph.period + 2_000_000, ph.pacer::frameNow);
        ph.at(nextV * ph.period - 1, () -> {
            postsBeforeNextVsync[0] = ph.vsyncPosts;
            callbacksAtNextVsync[0] = ph.nextVsync.size();
        });
        ph.runUntil((nextV + 4) * ph.period);
        check("frameNow with pending postVsync does not duplicate next vsync callback",
                postsBeforeNextVsync[0] == 1 && callbacksAtNextVsync[0] == 1 && ph.drawn.size() == 2,
                "postsBefore=" + postsBeforeNextVsync[0] + ", cbsAtNextVsync=" + callbacksAtNextVsync[0]
                        + ", drawn=" + ph.drawn.size());
    }

    /** Pure keyboard slide (more=false) keeps preferred timeline armed through a >8.33ms step and transition into more=true. */
    static void imeMovingPureSlideKeepsTimelineCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long firstV = 12;
        long totalSteps = 20;
        long endV = firstV + totalSteps;
        ph.app = new App() {
            @Override public double work(int f, double now) { return f == 4 ? 5.0 : 2.0; }

            @Override public double gpu(int f, double now) { return f == 4 ? 4.5 : 2.0; }

            @Override public boolean more(int f, double now) { return f >= 10 && f < totalSteps - 1; }
        };
        ph.main(firstV * ph.period - ph.period / 2, () -> ph.pacer.setImeMoving(true));
        ph.onInsets = () -> {
            long k = ph.now / ph.period;
            if (k >= firstV && k < endV) {
                ph.pacer.frameNow();
                if (k == endV - 1) ph.pacer.setImeMoving(false);
            }
        };
        ph.runUntil((endV + 6) * ph.period);
        List<Long> miss = missed(ph, (firstV + 2) * ph.period - 1, (endV + 1) * ph.period);
        check("IME pure slide keeps timeline across >8.33ms frame and transition to more=true with 0 missed refreshes",
                miss.isEmpty() && ph.drawn.size() == totalSteps,
                "drawn=" + ph.drawn.size() + "/" + totalSteps + ", missed=" + miss.size()
                        + (miss.isEmpty() ? "" : " (first=" + miss.get(0) + ")"));
    }

    /** 0. Idle external frames (words coming in every 500 ms, more=false, paced=0) must say no rate (Opus B1). */
    static void idleExternalFramesSayNoRateCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = steady(1.0, 1.0, -1);
        for (int k = 0; k < 10; k++) {
            ph.main(Math.round((100 + 500L * k) * 1e6), ph.pacer::wantFrame);
        }
        ph.runUntil(Math.round(5200e6));
        check("idle external frames (words coming in every 500 ms) say no rate",
                ph.rates.isEmpty() && ph.rate == 0f && ph.drawn.size() == 10,
                "rates=" + ph.rates.size() + ", rate=" + ph.rate + ", drawn=" + ph.drawn.size());
    }

    /** 1. Pure 20 Hz paced on a fixed 120 Hz screen: stays stably at 20 Hz with no 20<->120 ping-pong. */
    static void paced20FixedScreenCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return now < 1200 ? 20f : 0f; }
        };
        ph.main(Math.round(100e6), ph.pacer::wantPacedFrame);
        ph.runUntil(Math.round(1150e6));
        int rateChangesAfterFirst = 0;
        for (int i = 1; i < ph.rates.size(); i++) {
            if (ph.rates.get(i)[1] != ph.rates.get(i - 1)[1]) rateChangesAfterFirst++;
        }
        check("fixed 120 Hz screen pure 20 Hz paced holds 20 Hz with no ping-pong",
                ph.rate == 20f && rateChangesAfterFirst == 0 && ph.drawn.size() >= 19 && ph.drawn.size() <= 23,
                "rate=" + ph.rate + ", rateChanges=" + rateChangesAfterFirst + ", frames=" + ph.drawn.size());
    }

    /** 2. Pure 20 Hz paced on an LTPO screen whose vsync cadence switches to 50 ms: stays at 20 Hz (~20 fps, not 10 fps). */
    static void paced20LtpoScreenCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.ltpo = true;
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return now < 1200 ? 20f : 0f; }
        };
        ph.main(Math.round(100e6), ph.pacer::wantPacedFrame);
        ph.runUntil(Math.round(1150e6));
        int rateChangesAfterFirst = 0;
        for (int i = 1; i < ph.rates.size(); i++) {
            if (ph.rates.get(i)[1] != ph.rates.get(i - 1)[1]) rateChangesAfterFirst++;
        }
        check("LTPO screen (50ms vsync) pure 20 Hz paced holds 20 Hz and delivers ~20 fps (no 10 fps halving)",
                ph.rate == 20f && ph.pacer.framePeriod == 50_000_000L && rateChangesAfterFirst == 0
                        && ph.drawn.size() >= 19 && ph.drawn.size() <= 22,
                "rate=" + ph.rate + ", framePeriod=" + ph.pacer.framePeriod + ", rateChanges=" + rateChangesAfterFirst
                        + ", frames=" + ph.drawn.size());
    }

    /** 3. External 120 Hz wantFrame burst during 20 Hz paced lifts on frame 1 (both blocking & mailbox models + negative controls). */
    static void pacedExternalBurstLiftsCase() {
        // (a) Blocking model (mailboxDrops=false): swapWaitMaxNs <= period (control pinned at 20 Hz exceeds period).
        Phone phBlock = new Phone(120, 3, true, 200_000);
        phBlock.mailboxDrops = false;
        final boolean[] seenFirstExternal = {false};
        final float[] firstExternalRate = {0f};
        phBlock.onFrameEnded = (ext, r) -> {
            if (ext && !seenFirstExternal[0]) {
                seenFirstExternal[0] = true;
                firstExternalRate[0] = r;
            }
        };
        phBlock.app = new App() {
            @Override public double work(int f, double now) { return 1.5; }
            @Override public double gpu(int f, double now) { return 1.5; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return 20f; }
        };
        phBlock.main(Math.round(100e6), phBlock.pacer::wantPacedFrame);
        phBlock.runUntil(Math.round(350e6));
        float beforeBlock = phBlock.rate;
        phBlock.swapWaitMaxNs = 0;
        long burstStart = Math.round(360e6);
        for (int k = 0; k < 15; k++) phBlock.main(burstStart + k * phBlock.period, phBlock.pacer::wantFrame);
        phBlock.runUntil(burstStart + 15 * phBlock.period + phBlock.period / 2);

        // Negative control (blocking, pinned at 20 Hz): proves swapWaitMaxNs > period without lift.
        Phone ctrlBlock = new Phone(120, 3, true, 200_000);
        ctrlBlock.mailboxDrops = false;
        ctrlBlock.pinRate = 20f;
        ctrlBlock.app = phBlock.app;
        ctrlBlock.main(Math.round(100e6), ctrlBlock.pacer::wantPacedFrame);
        ctrlBlock.runUntil(Math.round(350e6));
        ctrlBlock.swapWaitMaxNs = 0;
        for (int k = 0; k < 15; k++) ctrlBlock.main(burstStart + k * ctrlBlock.period, ctrlBlock.pacer::wantFrame);
        ctrlBlock.runUntil(burstStart + 15 * ctrlBlock.period + ctrlBlock.period / 2);

        // (b) Mailbox overwrite model (mailboxDrops=true): swapDrops == 0 (control pinned at 20 Hz drops > 0).
        Phone phMail = new Phone(120, 3, true, 200_000);
        phMail.mailboxDrops = true;
        phMail.app = phBlock.app;
        phMail.main(Math.round(100e6), phMail.pacer::wantPacedFrame);
        phMail.runUntil(Math.round(350e6));
        phMail.swapDrops = 0;
        for (int k = 0; k < 15; k++) phMail.main(burstStart + k * phMail.period, phMail.pacer::wantFrame);
        phMail.runUntil(burstStart + 15 * phMail.period + phMail.period / 2);

        Phone ctrlMail = new Phone(120, 3, true, 200_000);
        ctrlMail.mailboxDrops = true;
        ctrlMail.pinRate = 20f;
        ctrlMail.app = phBlock.app;
        ctrlMail.main(Math.round(100e6), ctrlMail.pacer::wantPacedFrame);
        ctrlMail.runUntil(Math.round(350e6));
        ctrlMail.swapDrops = 0;
        for (int k = 0; k < 15; k++) ctrlMail.main(burstStart + k * ctrlMail.period, ctrlMail.pacer::wantFrame);
        ctrlMail.runUntil(burstStart + 15 * ctrlMail.period + ctrlMail.period / 2);

        check("external wantFrame burst lifts on frame 1 (blocking wait<=period, mailbox drops=0, controls fail)",
                beforeBlock == 20f && seenFirstExternal[0] && firstExternalRate[0] == 120f && phBlock.rate == 120f
                        && phBlock.swapWaitMaxNs <= phBlock.period && ctrlBlock.swapWaitMaxNs > ctrlBlock.period
                        && phMail.swapDrops == 0 && ctrlMail.swapDrops > 0,
                "firstExtRate=" + firstExternalRate[0] + ", blockWaitMs=" + (phBlock.swapWaitMaxNs / 1e6)
                        + " (ctrl=" + (ctrlBlock.swapWaitMaxNs / 1e6) + "), mailDrops=" + phMail.swapDrops
                        + " (ctrl=" + ctrlMail.swapDrops + ")");
    }

    /** 4. glSettling() lifts 20 Hz immediately before next paced frame, holds >1.5s without app frames, restores after. */
    static void pacedNonPacedActiveLiftsCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return now < 650 ? 20f : 0f; }
        };
        ph.main(Math.round(100e6), ph.pacer::wantPacedFrame);
        ph.runUntil(Math.round(305e6));
        boolean pacedBefore = ph.rate == 20f && ph.pacer.isPacedActive();
        // Start GL settle at 310ms; assert immediate lift at 315ms BEFORE next ~350ms paced frame!
        ph.at(Math.round(310e6), () -> {
            ph.glSettling = true;
            ph.postDrawing(ph.pacer::recheckRate);
        });
        ph.runUntil(Math.round(315e6));
        boolean liftedImmediately = ph.rate == 120f && !ph.pacer.isPacedActive();
        ph.runUntil(Math.round(580e6));
        boolean stayedHighDuringSettle = ph.rate == 120f && !ph.pacer.isPacedActive();
        for (double[] r : ph.rates) {
            if (r[0] >= 315e6 && r[0] <= 580e6 && r[1] == 20f) stayedHighDuringSettle = false;
        }
        // End GL settle at 585ms: next paced frame (~600ms) restores 20 Hz
        ph.at(Math.round(585e6), () -> ph.glSettling = false);
        ph.runUntil(Math.round(630e6));
        boolean resumedPaced = ph.rate == 20f && ph.pacer.isPacedActive();
        // Sustained glSettling (>1.5s with NO app frames at all): stillFor must NOT drop rate early
        ph.at(Math.round(640e6), () -> {
            ph.glSettling = true;
            ph.postDrawing(ph.pacer::recheckRate);
        });
        ph.runUntil(Math.round(2200e6));
        boolean heldOver1500ms = ph.rate == 120f;
        ph.at(Math.round(2210e6), () -> ph.glSettling = false);
        ph.runUntil(Math.round(3600e6));
        boolean releasedAfterEnd = ph.rate == 0f;
        check("glSettling lifts immediately, holds >1.5s without app frames, restores 20 Hz, releases after end",
                pacedBefore && liftedImmediately && stayedHighDuringSettle && resumedPaced
                        && heldOver1500ms && releasedAfterEnd,
                "before=" + pacedBefore + ", immediate=" + liftedImmediately + ", highDuring=" + stayedHighDuringSettle
                        + ", resumed=" + resumedPaced + ", held1.5s=" + heldOver1500ms + ", released=" + releasedAfterEnd);
    }

    /** 4b. Opus B1 regression: normal swipe rate releases to 0 after 1s even while a native WebView/video has pictureActive=true. */
    static void motionRateReleasesWithNativeViewAnimatingCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = steady(1.0, 1.0, 400);
        ph.main(Math.round(100e6), ph.pacer::wantFrame);
        ph.at(Math.round(300e6), () -> ph.pictureActive = true);
        ph.runUntil(Math.round(3000e6));
        check("normal motion rate releases to 0 after 1 s even while pictureActive stays true",
                ph.rate == 0f, "rate at 3000ms=" + ph.rate);
    }

    /** 5. Stopping 20 Hz paced drops directly to 0 (fixed 120 Hz & LTPO) and retries if setRate(0) fails once. */
    static void pacedStopExitsLowRateCase() {
        for (boolean ltpo : new boolean[] {false, true}) {
            Phone ph = new Phone(120, 3, true, 200_000);
            ph.ltpo = ltpo;
            ph.app = new App() {
                @Override public double work(int f, double now) { return 1.0; }
                @Override public double gpu(int f, double now) { return 1.0; }
                @Override public boolean more(int f, double now) { return false; }
                @Override public float paced(int f, double now) { return now < 400 ? 20f : 0f; }
            };
            ph.main(Math.round(100e6), ph.pacer::wantPacedFrame);
            ph.runUntil(Math.round(350e6));
            float during = ph.rate;
            // Fail the final setRate(0) once on the stopping frame (no further app frames): retryRelease must recover!
            ph.failNextSetRate = 1;
            ph.runUntil(Math.round(430e6));
            int framesAtStop = ph.drawn.size();
            ph.runUntil(Math.round(600e6));
            float rightAfterStop = ph.rate;
            boolean noExtraAppFrames = ph.drawn.size() == framesAtStop;
            boolean ever120 = false;
            for (double[] r : ph.rates) if (r[1] == 120f) ever120 = true;
            check("stopping 20 Hz paced (" + (ltpo ? "LTPO" : "fixed 120 Hz") + ") retries failed setRate(0) and drops to 0 without 120 Hz",
                    during == 20f && rightAfterStop == 0f && noExtraAppFrames && !ever120,
                    "during=" + during + ", afterStop=" + rightAfterStop + ", noExtra=" + noExtraAppFrames + ", ever120=" + ever120);
        }
    }

    /** 6. surfaceReset() invalidates old stillFor (both with new motion and with moved unchanged). */
    static void surfaceResetInvalidatesStillForCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) {
                return now < 250 || (now >= 500 && now < 700);
            }
        };
        // Motion 1 ends at 250 ms -> old stillFor would expire around ~1250 ms
        ph.main(Math.round(100e6), ph.pacer::wantFrame);
        ph.runUntil(Math.round(350e6));
        int ratesBeforeReset = ph.rates.size();
        // Destroy old surface and create a new one at 400 ms; start Motion 2 (500..700 ms)
        ph.at(Math.round(400e6), () -> ph.postDrawing(() -> {
            ph.pacer.surfaceReset();
            ph.pacer.sayRate(true);
        }));
        ph.runUntil(Math.round(420e6));
        boolean reVoted120 = ph.rates.size() > ratesBeforeReset && ph.rates.get(ph.rates.size() - 1)[1] == 120f;
        ph.main(Math.round(500e6), ph.pacer::wantFrame);
        // At 1450 ms (past old Surface's ~1250 ms expiry, before new Surface's ~1700 ms expiry), rate must stay 120
        ph.runUntil(Math.round(1450e6));
        boolean survivedOldStillFor = ph.rate == 120f;
        // At 1900 ms (past new Surface's ~1700 ms expiry), new stillFor must release to 0
        ph.runUntil(Math.round(1900e6));
        boolean releasedByNewStillFor = ph.rate == 0f;

        // Isolated gen != surfaceGen test: after surfaceReset(), only re-vote sayRate(true) with NO new motion (moved unchanged)
        Phone ph2 = new Phone(120, 3, true, 200_000);
        ph2.app = steady(1.0, 1.0, 250);
        ph2.main(Math.round(100e6), ph2.pacer::wantFrame);
        ph2.runUntil(Math.round(350e6));
        ph2.at(Math.round(400e6), () -> ph2.postDrawing(() -> {
            ph2.pacer.surfaceReset();
            ph2.pacer.sayRate(true);
        }));
        ph2.runUntil(Math.round(1600e6));
        boolean genGuardHeldWithoutNewMotion = ph2.rate == 120f;

        check("surfaceReset invalidates old stillFor (with and without new motion) while new stillFor releases normally",
                reVoted120 && survivedOldStillFor && releasedByNewStillFor && genGuardHeldWithoutNewMotion,
                "reVoted120=" + reVoted120 + ", at1450=" + survivedOldStillFor + ", at1900=" + ph.rate
                        + ", genGuardNoMotion=" + genGuardHeldWithoutNewMotion);
    }

    /** 7. setRate failure does not clear isPacedActive early, and stillFor retries a failed setRate(0) on next vsync. */
    static void setRateFailureRetryCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return now < 250 ? 20f : 0f; }
        };
        ph.main(Math.round(100e6), ph.pacer::wantPacedFrame);
        ph.runUntil(Math.round(220e6));
        // Fail the first setRate(120) during recheckRate: pacedActive must stay true so next call retries
        ph.at(Math.round(230e6), () -> {
            ph.failNextSetRate = 1;
            ph.glSettling = true;
            ph.postDrawing(ph.pacer::recheckRate);
        });
        ph.runUntil(Math.round(235e6));
        boolean stayedPacedAfterFail = ph.pacer.isPacedActive() && ph.rate == 20f;
        // Retry succeeds
        ph.at(Math.round(240e6), () -> ph.postDrawing(ph.pacer::recheckRate));
        ph.runUntil(Math.round(245e6));
        boolean liftedOnRetry = !ph.pacer.isPacedActive() && ph.rate == 120f;
        // End glSettling at 260ms, and fail the final setRate(0) once right before expiry (~1260ms)
        ph.at(Math.round(260e6), () -> ph.glSettling = false);
        ph.at(Math.round(1200e6), () -> ph.failNextSetRate = 1);
        ph.runUntil(Math.round(1500e6));
        boolean retriedZeroSuccess = ph.rate == 0f;
        check("setRate failure preserves isPacedActive for retry, and stillFor retries failed setRate(0)",
                stayedPacedAfterFail && liftedOnRetry && retriedZeroSuccess,
                "stayedPaced=" + stayedPacedAfterFail + ", liftedOnRetry=" + liftedOnRetry
                        + ", retriedZero=" + retriedZeroSuccess);
    }

    /** 8. WakeReq atomic merge upgrades in place in both orders (delivering on time at T with externalDemand) and rejects stale tokens. */
    static void wakeReqAtomicMergeCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = steady(1.0, 1.0, -1);
        final boolean[] seenExternal = {false};
        ph.onFrameEnded = (ext, r) -> seenExternal[0] = ext;
        // Order A: paced(T) already scheduled -> external(T) upgrades p1 IN PLACE (returns null) -> p1 fires on time at T as external!
        long tA = 24 * ph.period;
        FramePacer.WakeReq p1 = ph.pacer.scheduleWake(tA / 1e6, true);
        FramePacer.WakeReq e1 = ph.pacer.scheduleWake(tA / 1e6, false);
        boolean upgradedInPlace = p1 != null && e1 == null && !p1.isPacedOnly() && ph.pacer.isWakeCurrent(p1);
        ph.main(tA - ph.period, () -> ph.wakeAt(p1));
        ph.runUntil(tA + 2 * ph.period);
        boolean orderADelivered = upgradedInPlace && seenExternal[0] && ph.drawn.size() == 1;

        // Order B: external(T) -> paced(T) keeps external (returns null), delivers at T with externalDemand=true
        seenExternal[0] = false;
        long tB = 48 * ph.period;
        FramePacer.WakeReq e2 = ph.pacer.scheduleWake(tB / 1e6, false);
        FramePacer.WakeReq p2 = ph.pacer.scheduleWake(tB / 1e6, true);
        boolean keptExternal = e2 != null && p2 == null && !e2.isPacedOnly() && ph.pacer.isWakeCurrent(e2);
        ph.main(tB - ph.period, () -> ph.wakeAt(e2));
        ph.runUntil(tB + 2 * ph.period);
        boolean orderBDelivered = keptExternal && seenExternal[0] && ph.drawn.size() == 2;

        // Earlier deadline and clearWake() reject stale tokens
        FramePacer.WakeReq later = ph.pacer.scheduleWake(500.0, false);
        FramePacer.WakeReq earlier = ph.pacer.scheduleWake(450.0, true);
        boolean superseded = earlier != null && ph.pacer.isWakeCurrent(earlier)
                && ph.pacer.fireWake(later, 500_000_000L, 0) == 0;
        ph.pacer.clearWake();
        boolean cleared = !ph.pacer.isWakeCurrent(earlier) && ph.pacer.fireWake(earlier, 450_000_000L, 0) == 0;
        check("WakeReq atomic merge upgrades in place in both orders and rejects superseded/cleared tokens",
                orderADelivered && orderBDelivered && superseded && cleared,
                "orderA=" + orderADelivered + ", orderB=" + orderBDelivered
                        + ", superseded=" + superseded + ", cleared=" + cleared);
    }

    /** 9. wakeFrameNow + same-vsync vsyncCame in BOTH orders renders once, preserves shows, and keeps external demand. */
    static void wakeFrameNowSameVsyncNoDuplicateCase() {
        // Order 1: fireWake(req, v, shows) first, then queued vsyncCame(v, shows)
        Phone ph1 = new Phone(120, 3, true, 200_000);
        ph1.app = steady(1.0, 1.0, -1);
        long v = 12 * ph1.period;
        long expectedShows = v + 2 * ph1.period;
        final boolean[] ext1 = {false};
        ph1.onFrameEnded = (ext, r) -> ext1[0] = ext;
        ph1.main(v - ph1.period / 2, () -> {
            FramePacer.WakeReq req = ph1.pacer.scheduleWake(v / 1e6, false);
            ph1.nextVsync.add(() -> {
                ph1.pacer.fireWake(req, v, expectedShows);
                ph1.pacer.vsyncCame(v, expectedShows);
            });
        });
        ph1.runUntil(v + 3 * ph1.period);
        boolean ok1 = ph1.drawn.size() == 1 && ext1[0] && ph1.pacer.vsyncAt()[1] == expectedShows;

        // Order 2: vsyncCame(v, shows) first -> logic thread already consumed appWanted before clearWake() -> fireWake(req, v, shows)
        Phone ph2 = new Phone(120, 3, true, 200_000);
        ph2.app = new App() {
            @Override public double work(int f, double now) { return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return 20f; }
        };
        final long[] shows2 = {0};
        final float[] rateAtV = {0f};
        final int[] count2 = {0};
        ph2.onFrameEnded = (ext, r) -> { if (count2[0]++ == 0) rateAtV[0] = r; };
        ph2.main(v - ph2.period / 2, () -> {
            ph2.pacer.wantPacedFrame();
            FramePacer.WakeReq req = ph2.pacer.scheduleWake(v / 1e6, false);
            ph2.nextVsync.add(() -> {
                // wantPacedFrame()'s postVsync callback already ran vsyncCame(v, expectedShows) earlier in this vsync
                ph2.pacer.fireWake(req, v, expectedShows);
                shows2[0] = ph2.pacer.vsyncAt()[1];
            });
        });
        ph2.runUntil(v + 3 * ph2.period);
        boolean ok2 = ph2.renderRequests == 1 && ph2.drawn.size() == 1 && shows2[0] == expectedShows && rateAtV[0] == 120f;

        check("wakeFrameNow + same-vsync vsyncCame in both orders renders once, preserves shows, keeps external",
                ok1 && ok2,
                "ok1=" + ok1 + " (drawn=" + ph1.drawn.size() + "), ok2=" + ok2 + " (drawn=" + ph2.drawn.size() + ", rate=" + rateAtV[0] + ")");
    }

    /** 10. Astra #1: same-vsync external fireWake arriving AFTER begin() and BEFORE ended() lifts frame T and does NOT pollute T+1. */
    static void sameVsyncExternalAfterBeginBeforeEndedCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        final float[] frameRate = new float[2];
        final int[] frameIdx = {0};
        ph.app = new App() {
            @Override public double work(int f, double now) { return 4.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
            @Override public float paced(int f, double now) { return 20f; }
        };
        ph.onFrameEnded = (ext, r) -> {
            int idx = frameIdx[0]++;
            if (idx < 2) frameRate[idx] = r;
        };
        long t1 = 12 * ph.period;
        long shows1 = t1 + 2 * ph.period;
        // Deliver paced frame at t1; while frame 0 is mid-build (after begin(), before ended()), deliver external fireWake at t1.
        ph.main(t1 - ph.period / 2, ph.pacer::wantPacedFrame);
        ph.main(t1 + 1_000_000L, () -> {
            // Frame 0 already ran begin() at t1 + 200us and is mid-work (4ms); now external wake for same vsync t1 fires!
            FramePacer.WakeReq extReq = ph.pacer.scheduleWake(t1 / 1e6, false);
            if (extReq != null) ph.pacer.fireWake(extReq, t1, shows1);
        });
        ph.runUntil(t1 + 3 * ph.period);
        int drawnAfterT1 = ph.drawn.size();
        // Now deliver the next pure paced frame T+1 (~50ms later): it must NOT be polluted and must vote 20 Hz!
        ph.runUntil(t1 + 10 * ph.period);
        boolean ok = drawnAfterT1 == 1 && frameRate[0] == 120f && ph.drawn.size() >= 2 && frameRate[1] == 20f;
        check("same-vsync external wake after begin() lifts frame T to 120 Hz and leaves next paced frame T+1 at 20 Hz",
                ok, "drawnAtT1=" + drawnAfterT1 + ", rateT=" + frameRate[0] + ", rateT1=" + frameRate[1]);
    }

    /** 11. Astra #2: concurrent scheduleWake(T, false) vs fireWake(p1, T, shows) never leaves a duplicate token after external delivery. */
    static void wakeReqConcurrentUpgradeNoDuplicateCase() {
        boolean ok = true;
        int rounds = 200;
        for (int r = 0; r < rounds && ok; r++) {
            Phone ph = new Phone(120, 3, true, 200_000);
            long t = 24 * ph.period;
            double atMs = t / 1e6;
            FramePacer.WakeReq p1 = ph.pacer.scheduleWake(atMs, true);
            java.util.concurrent.CountDownLatch go = new java.util.concurrent.CountDownLatch(1);
            final FramePacer.WakeReq[] second = {null};
            Thread upgrader = new Thread(() -> {
                try { go.await(); } catch (InterruptedException ignored) {}
                second[0] = ph.pacer.scheduleWake(atMs, false);
            });
            upgrader.start();
            go.countDown();
            int res = ph.pacer.fireWake(p1, t, t + 2 * ph.period);
            try { upgrader.join(); } catch (InterruptedException ignored) {}
            if (res != 2) ok = false;
            // If fireWake consumed p1 as external (!p1.isPacedOnly()), upgrader must have upgraded p1 in place (second[0] == null).
            if (res == 2 && !p1.isPacedOnly() && second[0] != null) ok = false;
            // Conversely, if p1 was consumed as pacedOnly, upgrader saw wakeReq==null and installed a valid external token.
            if (res == 2 && p1.isPacedOnly()
                    && (second[0] == null || second[0].isPacedOnly() || !ph.pacer.isWakeCurrent(second[0]))) ok = false;
        }
        check("concurrent scheduleWake(T,false) vs fireWake(p1,T) never duplicates an already-upgraded token",
                ok, "rounds=" + rounds);
    }

    /** 12. Astra #1 (ahead): ask(true) claiming ahead + same-vsync fireWake renders once without duplicating. */
    static void aheadClaimedThenSameVsyncFireWakeCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        ph.app = steady(1.0, 1.0, -1);
        long t = 12 * ph.period;
        long shows = t + 2 * ph.period;
        ph.main(t - ph.period / 2, () -> {
            FramePacer.WakeReq req = ph.pacer.scheduleWake(t / 1e6, false);
            ph.nextVsync.add(() -> {
                // 1) vsyncCame with no pending demand stores ahead=true for vsync t
                ph.pacer.vsyncCame(t, shows);
                // 2) wantFrame() claims ahead via ask(true) and sets lastAppDispatchedVsyncNs=t (renderRequests == 1)
                ph.pacer.wantFrame();
                // 3) Main thread delivers fireWake(req, t, shows) for the same vsync t -> must NOT request a second render
                ph.pacer.fireWake(req, t, shows);
            });
        });
        ph.runUntil(t + 3 * ph.period);
        check("ask(true) claiming ahead deduplicates same-vsync fireWake (renders once)",
                ph.renderRequests == 1 && ph.drawn.size() == 1,
                "renderRequests=" + ph.renderRequests + ", drawn=" + ph.drawn.size());
    }

    /** 13. Astra #1: picture-only dispatch at T does NOT steal T+1's appWanted; T+1 dispatches cleanly and deduplicates same-vsync fireWake. */
    static void pictureUpgradedThenSameVsyncFireWakeCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long t1 = 12 * ph.period;
        long t2 = 13 * ph.period;
        long shows1 = t1 + 2 * ph.period;
        long shows2 = t2 + 2 * ph.period;
        final long[] begunVsync = {0, 0};
        final boolean[] picStayedPicture = {false};
        final int[] drawnCount = {0};
        ph.main(t1 - ph.period / 2, () -> {
            ph.pacer.picturesOnly.set(true);
            ph.nextVsync.add(() -> {
                // 1) vsyncCame(T1, shows1) dispatches picture-only (appDispatched == false, renderRequests == 1)
                ph.pacer.vsyncCame(t1, shows1);
                // 2) wantFrame() queues appWanted=true for T2 (ahead is false, so appDispatched stays false)
                ph.pacer.wantFrame();
                // 3) Picture callback runs takeRender(): must stay picture-only (NOT steal T2's appWanted!)
                FramePacer.Taken tkPic = ph.pacer.takeRender();
                ph.renderRequested = false;
                picStayedPicture[0] = !tkPic.app && tkPic.pictured;
                ph.pacer.redrawn();
                // 4) T2 arrives: vsyncCame(T2, shows2) dispatches T2 (appDispatched == true, renderRequests == 2)
                FramePacer.WakeReq req2 = ph.pacer.scheduleWake(t2 / 1e6, false);
                ph.pacer.vsyncCame(t2, shows2);
                FramePacer.Taken tk2 = ph.pacer.takeRender();
                ph.renderRequested = false;
                // 5) Before clearWake(), main thread delivers fireWake(req2, T2, shows2) -> must deduplicate (renderRequests stays 2)
                ph.pacer.fireWake(req2, t2, shows2);
                if (tk2.app) {
                    FramePacer.Begun b = ph.pacer.begin(tk2.vsyncAt, t2 + 200_000L, tk2.external);
                    ph.pacer.clearWake();
                    begunVsync[0] = b.vsync;
                    begunVsync[1] = b.shows;
                    ph.pacer.ended(false, false, b.following, 0f, b.externalDemand);
                    drawnCount[0]++;
                }
            });
        });
        ph.runUntil(t1 + 3 * ph.period);
        boolean ok = picStayedPicture[0] && ph.renderRequests == 2 && drawnCount[0] == 1 && ph.drawn.size() == 0
                && begunVsync[0] == t2 && begunVsync[1] == shows2;
        check("picture-only dispatch at T does not steal T+1 appWanted, and T+1 deduplicates same-vsync fireWake",
                ok, "picStayed=" + picStayedPicture[0] + ", renderRequests=" + ph.renderRequests
                        + ", drawn=" + drawnCount[0] + "+" + ph.drawn.size()
                        + ", begun=" + begunVsync[0] + "/" + begunVsync[1]);
    }

    /** 14. Astra #2: flushDeferredVsync atomically publishes (vsyncAt, appWanted) against concurrent picture takeRender(). */
    static void imeFlushAtomicWithPendingPictureCase() {
        boolean ok = true;
        int rounds = 200;
        for (int r = 0; r < rounds && ok; r++) {
            Phone ph = new Phone(120, 3, true, 200_000);
            long tPrev = 10 * ph.period;
            long tCur = 12 * ph.period;
            long expectedShows = tCur + 2 * ph.period;
            // Seed vsyncAt with previous vsync T-1 and a pending pictureOnly redraw
            ph.pacer.vsyncCame(tPrev, tPrev + 2 * ph.period);
            ph.pacer.takeRender();
            ph.pacer.picturesOnly.set(true);
            ph.pacer.setImeMoving(true);
            FramePacer.WakeReq req = ph.pacer.scheduleWake(tCur / 1e6, false);
            ph.pacer.fireWake(req, tCur, expectedShows);
            // Race flushDeferredVsync (via setImeMoving(false)) on main vs pending picture takeRender() on drawing thread
            java.util.concurrent.CountDownLatch go = new java.util.concurrent.CountDownLatch(1);
            final FramePacer.Taken[] picTaken = {null};
            Thread drawer = new Thread(() -> {
                try { go.await(); } catch (InterruptedException ignored) {}
                picTaken[0] = ph.pacer.takeRender();
            });
            drawer.start();
            go.countDown();
            ph.pacer.setImeMoving(false);
            try { drawer.join(); } catch (InterruptedException ignored) {}
            // Check invariant: if drawer saw app==true, it MUST see (tCur, expectedShows), never tPrev!
            int appFrames = 0;
            long seenT = 0, seenShows = 0;
            if (picTaken[0].app) {
                appFrames++;
                seenT = picTaken[0].vsyncAt[0];
                seenShows = picTaken[0].vsyncAt[1];
            }
            // Drain any remaining app frame scheduled by flushDeferredVsync
            FramePacer.Taken second = ph.pacer.takeRender();
            if (second.app) {
                appFrames++;
                seenT = second.vsyncAt[0];
                seenShows = second.vsyncAt[1];
            }
            if (appFrames != 1 || seenT != tCur || seenShows != expectedShows) ok = false;
        }
        check("flushDeferredVsync publishes (vsyncAt, appWanted) atomically against concurrent picture takeRender()",
                ok, "rounds=" + rounds);
    }

    /** 13. Astra #2/#3: during imeMoving, fireWake coalesces into deferredVsync (with frameNow, flush, or pending pictureFrame). */
    static void imeMovingFireWakeCoalescesCase() {
        // (a) vsyncCame(T, shows) -> fireWake(req, T, shows) -> inset update + frameNow(): 1 frame, sees new inset, keeps shows.
        Phone ph1 = new Phone(120, 3, true, 200_000);
        final int[] inset = {0};
        final int[] seenInset = {-1};
        final long[] seenShows = {0};
        ph1.app = new App() {
            @Override public double work(int f, double now) {
                seenInset[0] = inset[0];
                seenShows[0] = ph1.pacer.vsyncAt()[1];
                return 1.0;
            }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
        };
        long t = 12 * ph1.period;
        long expectedShows = t + 2 * ph1.period;
        ph1.main(t - ph1.period / 2, () -> {
            ph1.pacer.setImeMoving(true);
            FramePacer.WakeReq req = ph1.pacer.scheduleWake(t / 1e6, true);
            ph1.nextVsync.add(() -> {
                ph1.pacer.fireWake(req, t, expectedShows);
            });
            ph1.onInsets = () -> {
                inset[0] = 320;
                ph1.pacer.frameNow();
                ph1.onInsets = null;
            };
        });
        ph1.runUntil(t + 2 * ph1.period);
        boolean okWithProgress = ph1.drawn.size() == 1 && seenInset[0] == 320 && seenShows[0] == expectedShows;

        // (b) No onProgress/frameNow(): flushDeferredVsync delivers 1 frame with expectedShows preserved.
        Phone ph2 = new Phone(120, 3, true, 200_000);
        ph2.app = steady(1.0, 1.0, -1);
        ph2.main(t - ph2.period / 2, () -> {
            ph2.pacer.setImeMoving(true);
            FramePacer.WakeReq req = ph2.pacer.scheduleWake(t / 1e6, false);
            ph2.nextVsync.add(() -> ph2.pacer.fireWake(req, t, expectedShows));
        });
        ph2.runUntil(t + 2 * ph2.period);
        boolean okFlushOnly = ph2.drawn.size() == 1 && ph2.pacer.vsyncAt()[1] == expectedShows;

        // (c) Pending pictureFrame redraw running between fireWake and onProgress must NOT consume deferredWakeApp prematurely.
        Phone ph3 = new Phone(120, 3, true, 200_000);
        final int[] inset3 = {0};
        final int[] seenInset3 = {-1};
        final long[] seenShows3 = {0};
        final int[] drawnAfterPicture = {-1};
        ph3.app = new App() {
            @Override public double work(int f, double now) {
                seenInset3[0] = inset3[0];
                seenShows3[0] = ph3.pacer.vsyncAt()[1];
                return 1.0;
            }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return false; }
        };
        ph3.main(t - ph3.period / 2, () -> {
            ph3.pacer.picturesOnly.set(true);
            ph3.pacer.setImeMoving(true);
            FramePacer.WakeReq req = ph3.pacer.scheduleWake(t / 1e6, true);
            ph3.nextVsync.add(() -> {
                ph3.pacer.fireWake(req, t, expectedShows);
                // Pending picture-only redraw runs before onProgress/frameNow(): must stay picture-only (drawn == 0)
                ph3.drawFrame();
                drawnAfterPicture[0] = ph3.drawn.size();
            });
            ph3.onInsets = () -> {
                inset3[0] = 320;
                ph3.pacer.frameNow();
                ph3.onInsets = null;
            };
        });
        ph3.runUntil(t + 2 * ph3.period);
        boolean okPictureBeforeProgress = drawnAfterPicture[0] == 0 && ph3.drawn.size() == 1
                && seenInset3[0] == 320 && seenShows3[0] == expectedShows;

        check("imeMoving coalesces fireWake into deferredVsync (onProgress, flush, and pending pictureFrame) preserving shows",
                okWithProgress && okFlushOnly && okPictureBeforeProgress,
                "withProgress=" + okWithProgress + " (drawn=" + ph1.drawn.size() + ", inset=" + seenInset[0]
                        + "), flushOnly=" + okFlushOnly + " (drawn=" + ph2.drawn.size()
                        + "), picBefore=" + okPictureBeforeProgress + " (afterPic=" + drawnAfterPicture[0]
                        + ", drawn=" + ph3.drawn.size() + ", inset=" + seenInset3[0] + ")");
    }

    /** 15. Astra #1: wantFrame() between takeRender() and begin() is NOT stolen by T; T keeps 120 Hz because appWanted is already set, and T+1 receives external=true and stays 120 Hz. */
    static void wantFrameBetweenTakeAndBeginPreservesExternalCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long t1 = 12 * ph.period;
        long t2 = 13 * ph.period;
        // Frame T is a pure paced frame
        ph.pacer.wantPacedFrame();
        ph.pacer.vsyncCame(t1, t1 + 2 * ph.period);
        FramePacer.Taken tk1 = ph.pacer.takeRender();
        // External wantFrame() arrives AFTER T's takeRender() and BEFORE T's begin()!
        ph.pacer.wantFrame();
        FramePacer.Begun b1 = ph.pacer.begin(tk1.vsyncAt, t1 + 200_000L, tk1.external);
        ph.pacer.ended(false, false, b1.following, 20f, b1.externalDemand);
        float rateT = ph.rate;

        // Frame T+1 runs on the next vsync (even with paced=20f): it must receive external==true and lift to 120 Hz!
        ph.pacer.vsyncCame(t2, t2 + 2 * ph.period);
        FramePacer.Taken tk2 = ph.pacer.takeRender();
        FramePacer.Begun b2 = ph.pacer.begin(tk2.vsyncAt, t2 + 200_000L, tk2.external);
        ph.pacer.ended(false, false, b2.following, 20f, b2.externalDemand);
        float rateT1 = ph.rate;

        boolean ok = !tk1.external && !b1.externalDemand && rateT == 120f
                && tk2.external && b2.externalDemand && rateT1 == 120f;
        check("wantFrame() between takeRender() and begin() is not stolen by T (T+1 keeps external and stays 120 Hz)",
                ok, "tk1.ext=" + tk1.external + ", rateT=" + rateT + ", tk2.ext=" + tk2.external + ", rateT1=" + rateT1);
    }

    /** 16. Astra #2: ONE-mode extra GL callback before T+1 does not steal T+1's appWanted or clear askedAtEnd, always redrawing validly. */
    static void oneModeFlushStalePictureDoesNotDoubleDrawCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        final boolean[] systemFrameNeeded = {false};
        final boolean[] nextMore = {true};
        final int[] appDraws = {0}, redraws = {0}, swaps = {0}, picActivity = {0};
        final java.util.List<Long> begunVsyncs = new java.util.ArrayList<>();
        final double[] lastLate = {0.0};
        Runnable oneOnDrawFrame = () -> {
            FramePacer.Taken tk = ph.pacer.takeRender();
            boolean sys = systemFrameNeeded[0];
            systemFrameNeeded[0] = false;
            if (!tk.app && !sys) {
                redraws[0]++;
                if (tk.pictured) {
                    picActivity[0]++;
                    ph.pacer.redrawn();
                }
                swaps[0]++; // GLSurfaceView unconditionally calls eglSwapBuffers after onDrawFrame
                return;
            }
            FramePacer.Begun b = ph.pacer.begin(tk.vsyncAt, ph.now, tk.external);
            begunVsyncs.add(b.vsync);
            lastLate[0] = b.late;
            boolean more = nextMore[0];
            nextMore[0] = false;
            ph.pacer.ended(more, false, b.following, 0f, b.externalDemand);
            appDraws[0]++;
            swaps[0]++;
        };

        long t1 = 12 * ph.period;
        long t2 = t1 + 2 * ph.period; // deliberately 1 refresh late to prove askedAtEnd survived Callback 2!
        long shows1 = t1 + 2 * ph.period;
        long shows2 = t2 + 2 * ph.period;
        // Pending picture redraw + IME flushDeferredVsync publishes (t1, shows1)
        ph.pacer.pictureFrame();
        ph.pacer.setImeMoving(true);
        FramePacer.WakeReq req = ph.pacer.scheduleWake(t1 / 1e6, false);
        ph.pacer.fireWake(req, t1, shows1);
        ph.pacer.setImeMoving(false); // flushDeferredVsync publishes appWanted=true, appDispatched=true for t1
        // Callback 1 builds T1 and calls ended(more=true) -> sets askedAtEnd=true & wantFrame() for T2 (appDispatched=false!)
        ph.now = t1 + 200_000L;
        oneOnDrawFrame.run();
        // Callback 2 (extra GL callback before T2's vsyncCame): must NOT steal T2's appWanted or clear askedAtEnd!
        oneOnDrawFrame.run();
        int appAfterExtra = appDraws[0], swapsAfterExtra = swaps[0], validAfterExtra = appDraws[0] + redraws[0];
        // Now T2 arrives 1 refresh late -> Callback 3 builds T2 with b.late > 0 (proving askedAtEnd was intact!)
        ph.now = t2;
        ph.pacer.vsyncCame(t2, shows2);
        ph.now = t2 + 200_000L;
        oneOnDrawFrame.run();
        int appAfterT2 = appDraws[0];
        double lateAtT2 = lastLate[0];

        // System onSurfaceChanged (systemFrameNeeded=true) builds an app frame even when !app && !pictured
        systemFrameNeeded[0] = true;
        oneOnDrawFrame.run();
        int appAfterResize = appDraws[0];

        // System expose (!app && !sys && !pictured) redraws kept frame (valid swap, no extra app frame, no picActivity)
        oneOnDrawFrame.run();
        int appAfterExpose = appDraws[0], validAfterExpose = appDraws[0] + redraws[0];

        boolean seqOk = begunVsyncs.size() >= 2 && begunVsyncs.get(0) == t1 && begunVsyncs.get(1) == t2;
        boolean ok = appAfterExtra == 1 && swapsAfterExtra == 2 && validAfterExtra == 2
                && appAfterT2 == 2 && seqOk && lateAtT2 > 0.0
                && appAfterResize == 3 && appAfterExpose == 3 && validAfterExpose == swaps[0] && picActivity[0] == 0;
        check("ONE-mode extra callback before T+1 does not steal appWanted or clear askedAtEnd (always valid swap)",
                ok, "appAfterExtra=" + appAfterExtra + ", appAfterT2=" + appAfterT2 + ", seqOk=" + seqOk
                        + ", lateAtT2=" + lateAtT2 + ", valid=" + validAfterExpose + "/" + swaps[0]
                        + ", picAct=" + picActivity[0]);
    }

    /** 17. Astra: duplicate vsyncCame(T) in either order (before or after ended(more=true)) never stalls T+1 on real Phone clock. */
    static void duplicateVsyncAtSameTDoesNotStallNextFrameCase() {
        // Order A: vsyncCame(T) -> takeRender()+begin() -> duplicate vsyncCame(T) -> ended(more=true) -> Phone clock alone drives T+1!
        Phone phA = new Phone(120, 3, true, 200_000);
        final double[] nowA = new double[4];
        phA.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nowA[f] = now; return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        long t = 12 * phA.period;
        long shows = t + 2 * phA.period;
        phA.main(t - phA.period / 2, phA.pacer::wantFrame);
        // Duplicate vsyncCame(t, shows) arrives after frame 0's takeRender()+begin() (t+0.2ms) and before ended(more=true) (t+1.2ms)
        phA.main(t + 500_000L, () -> phA.pacer.vsyncCame(t, shows));
        phA.runUntil(t + 4 * phA.period);
        boolean okA = phA.drawn.size() >= 2 && nowA[1] > t / 1e6;

        // Order B: vsyncCame(T) -> takeRender()+begin()+ended(more=true) -> duplicate vsyncCame(T) -> 0 extra postVsync & T+1 on time!
        Phone phB = new Phone(120, 3, true, 200_000);
        final double[] nowB = new double[4];
        final int[] postsDeltaB = {-1};
        phB.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nowB[f] = now; return 0.5; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        phB.main(t - phB.period / 2, phB.pacer::wantFrame);
        // Duplicate vsyncCame(t, shows) arrives after frame 0's ended(more=true) (t+0.7ms) has already queued T+1
        phB.main(t + 1_500_000L, () -> {
            int before = phB.vsyncPosts;
            phB.pacer.vsyncCame(t, shows);
            postsDeltaB[0] = phB.vsyncPosts - before;
        });
        phB.runUntil(t + 4 * phB.period);
        boolean okB = phB.drawn.size() >= 2 && postsDeltaB[0] == 0
                && Math.abs(nowB[1] - (t + phB.period) / 1e6) < 0.01;

        // Order C: frameNow() at T -> ended(more=true) queues T+1 -> duplicate vsyncCame(T) hits lastFrameNowAt fast path -> 0 extra postVsync & T+1 on time!
        Phone phC = new Phone(120, 3, true, 200_000);
        final double[] nowC = new double[4];
        final int[] postsDeltaC = {-1};
        phC.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nowC[f] = now; return 0.5; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        phC.main(t + 100_000L, phC.pacer::frameNow);
        phC.main(t + 1_500_000L, () -> {
            int before = phC.vsyncPosts;
            phC.pacer.vsyncCame(t, shows);
            postsDeltaC[0] = phC.vsyncPosts - before;
        });
        phC.runUntil(t + 4 * phC.period);
        boolean okC = phC.drawn.size() >= 2 && postsDeltaC[0] == 0
                && Math.abs(nowC[1] - (t + phC.period) / 1e6) < 0.01;

        check("duplicate vsyncCame(T) before/after ended(more=true) or frameNow never stalls or double-posts T+1",
                okA && okB && okC, "okA=" + okA + " (drawn=" + phA.drawn.size() + ", t1=" + nowA[1]
                        + "), okB=" + okB + " (deltaPosts=" + postsDeltaB[0] + ", t1=" + nowB[1]
                        + "), okC=" + okC + " (deltaPosts=" + postsDeltaC[0] + ", t1=" + nowC[1] + ")");
    }

    /** 18. Opus: wantImmediateFrame() while ahead==true clears ahead on takeRender() so ended(more=true) drives T+1 on real clock. */
    static void wantImmediateFrameClearsAheadForNextFrameCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        final double[] nows = new double[4];
        ph.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nows[f] = now; return 1.0; }
            @Override public double gpu(int f, double now) { return 1.0; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        long t = 12 * ph.period;
        ph.main(t, () -> {
            // Store ahead=true for vsync t (no pending demand)
            ph.pacer.vsyncCame(t, t + 2 * ph.period);
            // Mid-frame imeBottom change calls wantImmediateFrame() + makeFrame()
            ph.pacer.wantImmediateFrame();
            ph.requestRender();
        });
        ph.runUntil(t + 4 * ph.period);
        boolean ok = ph.drawn.size() >= 2 && nows[1] > t / 1e6;
        check("wantImmediateFrame() while ahead==true clears ahead in takeRender() and drives T+1",
                ok, "drawn=" + ph.drawn.size() + ", t0=" + nows[0] + ", t1=" + nows[1]);
    }

    /** 19. Astra: same-vsync fireWake after begin()->askAhead() does not clear wanted for T+1 or cause double postVsync. */
    static void sameVsyncFireWakeAfterAskAheadDoesNotDoublePostCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        final double[] nows = new double[4];
        final int[] postsBeforeT = {-1};
        final int[] postsAfterTEnded = {-1};
        ph.app = new App() {
            @Override public double work(int f, double now) {
                if (f < 4) nows[f] = now;
                return f == 1 ? 2.0 : 0.5;
            }
            @Override public double gpu(int f, double now) { return 0.5; }
            @Override public boolean more(int f, double now) { return f <= 1; }
        };
        long tPrev = 12 * ph.period;
        long t = 13 * ph.period;
        long showsT = t + 2 * ph.period;
        // Frame 0 at tPrev ends with more=true -> frame 1 at t calls askAhead() inside begin()!
        ph.main(tPrev - ph.period / 2, ph.pacer::wantFrame);
        ph.at(t - 100_000L, () -> postsBeforeT[0] = ph.vsyncPosts);
        // Schedule an external WakeReq for t, and fire it AFTER frame 1's begin()->askAhead() (t+0.2ms) and BEFORE ended() (t+2.2ms)
        ph.main(t + 1_000_000L, () -> {
            FramePacer.WakeReq req = ph.pacer.scheduleWake(t / 1e6, false);
            if (req != null) ph.pacer.fireWake(req, t, showsT);
        });
        ph.at(t + 3_000_000L, () -> postsAfterTEnded[0] = ph.vsyncPosts);
        ph.runUntil(t + 4 * ph.period);
        int postsForT1 = postsAfterTEnded[0] - postsBeforeT[0];
        boolean ok = ph.drawn.size() >= 3 && postsForT1 == 1
                && Math.abs(nows[2] - (t + ph.period) / 1e6) < 0.01;
        check("same-vsync fireWake after askAhead() preserves wanted for T+1 (1 postVsync, T+1 on time)",
                ok, "postsForT1=" + postsForT1 + ", drawn=" + ph.drawn.size() + ", t2=" + nows[2]);
    }

    /** 20. Astra (reverse order): wantFrame() then fireWake(req, T) in T's vsync callback does not clear T+1's wanted (1 postVsync total). */
    static void wantFrameBeforeFireWakeAtSameTDoesNotDoublePostCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        final double[] nows = new double[4];
        final int[] postsBefore = {-1};
        final int[] postsAt3ms = {-1};
        final int[] fireRes = {-1};
        ph.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nows[f] = now; return 0.5; }
            @Override public double gpu(int f, double now) { return 0.5; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        long t = 12 * ph.period;
        long showsT = t + 2 * ph.period;
        ph.main(t - ph.period / 2, () -> {
            FramePacer.WakeReq req = ph.pacer.scheduleWake(t / 1e6, false);
            ph.nextVsync.add(() -> {
                postsBefore[0] = ph.vsyncPosts;
                ph.pacer.wantFrame();
                fireRes[0] = ph.pacer.fireWake(req, t, showsT);
            });
        });
        ph.at(t + 3_000_000L, () -> postsAt3ms[0] = ph.vsyncPosts);
        ph.runUntil(t + 4 * ph.period);
        int postsDelta = postsAt3ms[0] - postsBefore[0];
        boolean okNonIme = fireRes[0] == 2 && postsDelta == 1 && ph.drawn.size() >= 2
                && Math.abs(nows[1] - (t + ph.period) / 1e6) < 0.01;

        // (a) IME flushDeferredVsync path (wake-created deferredVsync, no vsyncCame): must NOT clear T+1's wanted!
        Phone phFlush = new Phone(120, 3, true, 200_000);
        final double[] nowsFlush = new double[4];
        final int[] beforeFlush = {-1}, at3msFlush = {-1}, resFlush = {-1};
        phFlush.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nowsFlush[f] = now; return 0.5; }
            @Override public double gpu(int f, double now) { return 0.5; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        phFlush.main(t - phFlush.period / 2, () -> {
            FramePacer.WakeReq req = phFlush.pacer.scheduleWake(t / 1e6, false);
            phFlush.nextVsync.add(() -> {
                beforeFlush[0] = phFlush.vsyncPosts;
                phFlush.pacer.wantFrame();
                phFlush.pacer.setImeMoving(true);
                resFlush[0] = phFlush.pacer.fireWake(req, t, showsT);
            });
        });
        phFlush.at(t + 3_000_000L, () -> at3msFlush[0] = phFlush.vsyncPosts);
        phFlush.runUntil(t + 4 * phFlush.period);
        int deltaFlush = at3msFlush[0] - beforeFlush[0];
        boolean okImeFlush = resFlush[0] == 2 && deltaFlush == 1 && phFlush.drawn.size() >= 2
                && Math.abs(nowsFlush[1] - (t + phFlush.period) / 1e6) < 0.01;

        // (b) IME onInsets/frameNow path (wake-created deferredVsync, no vsyncCame): must NOT clear T+1's wanted!
        Phone phInsets = new Phone(120, 3, true, 200_000);
        final double[] nowsInsets = new double[4];
        final int[] beforeInsets = {-1}, at3msInsets = {-1}, resInsets = {-1};
        phInsets.app = new App() {
            @Override public double work(int f, double now) { if (f < 4) nowsInsets[f] = now; return 0.5; }
            @Override public double gpu(int f, double now) { return 0.5; }
            @Override public boolean more(int f, double now) { return f == 0; }
        };
        phInsets.main(t - phInsets.period / 2, () -> {
            FramePacer.WakeReq req = phInsets.pacer.scheduleWake(t / 1e6, false);
            phInsets.nextVsync.add(() -> {
                beforeInsets[0] = phInsets.vsyncPosts;
                phInsets.pacer.wantFrame();
                phInsets.pacer.setImeMoving(true);
                resInsets[0] = phInsets.pacer.fireWake(req, t, showsT);
            });
            phInsets.onInsets = () -> {
                phInsets.pacer.frameNow();
                phInsets.onInsets = null;
            };
        });
        phInsets.at(t + 3_000_000L, () -> at3msInsets[0] = phInsets.vsyncPosts);
        phInsets.runUntil(t + 4 * phInsets.period);
        int deltaInsets = at3msInsets[0] - beforeInsets[0];
        boolean okImeInsets = resInsets[0] == 2 && deltaInsets == 1 && phInsets.drawn.size() >= 2
                && Math.abs(nowsInsets[1] - (t + phInsets.period) / 1e6) < 0.01;

        check("wantFrame() before fireWake(req, T) preserves T+1 wanted (non-IME, IME flush, IME frameNow)",
                okNonIme && okImeFlush && okImeInsets,
                "nonIme=" + postsDelta + ", imeFlush=" + deltaFlush + " (t1=" + nowsFlush[1]
                        + "), imeInsets=" + deltaInsets + " (t1=" + nowsInsets[1] + ")");
    }

    /** 21. applyRate + scheduleNext matches ended() and covers pacedBefore || pacedNow on paced exit and follow-up frame. */
    static void applyRateScheduleNextEquivalenceCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        long t1 = 12 * ph.period;
        ph.pacer.wantPacedFrame();
        ph.pacer.vsyncCame(t1, t1 + 2 * ph.period);
        FramePacer.Taken tk1 = ph.pacer.takeRender();
        FramePacer.Begun b1 = ph.pacer.begin(tk1.vsyncAt, t1 + 200_000L, tk1.external);
        boolean pacedBefore1 = ph.pacer.isPacedActive();
        boolean pacedNow1 = ph.pacer.applyRate(false, false, b1.following, 20f, b1.externalDemand);
        ph.pacer.scheduleNext(false);
        boolean ok1 = !pacedBefore1 && pacedNow1 && (pacedBefore1 || pacedNow1)
                && ph.pacer.isPacedActive() && ph.rate == 20f;

        // Exit frame (20 Hz -> 120 Hz): pacedBefore=true, pacedNow=false, pacedBefore || pacedNow == true.
        long t2 = 13 * ph.period;
        ph.pacer.wantFrame();
        ph.pacer.vsyncCame(t2, t2 + 2 * ph.period);
        FramePacer.Taken tk2 = ph.pacer.takeRender();
        FramePacer.Begun b2 = ph.pacer.begin(tk2.vsyncAt, t2 + 200_000L, tk2.external);
        boolean pacedBefore2 = ph.pacer.isPacedActive();
        boolean pacedNow2 = ph.pacer.applyRate(true, false, b2.following, 20f, b2.externalDemand);
        int postsBefore = ph.vsyncPosts;
        ph.pacer.scheduleNext(true);
        ph.runUntil(ph.now);
        boolean ok2 = pacedBefore2 && !pacedNow2 && (pacedBefore2 || pacedNow2)
                && !ph.pacer.isPacedActive() && ph.rate == 120f && ph.vsyncPosts > postsBefore;

        // Following normal interactive frame: pacedBefore=false, pacedNow=false, pacedBefore || pacedNow == false.
        long t3 = 14 * ph.period;
        ph.pacer.vsyncCame(t3, t3 + 2 * ph.period);
        FramePacer.Taken tk3 = ph.pacer.takeRender();
        FramePacer.Begun b3 = ph.pacer.begin(tk3.vsyncAt, t3 + 200_000L, tk3.external);
        boolean pacedBefore3 = ph.pacer.isPacedActive();
        boolean pacedNow3 = ph.pacer.applyRate(true, false, b3.following, 0f, b3.externalDemand);
        ph.pacer.scheduleNext(true);
        boolean ok3 = !pacedBefore3 && !pacedNow3 && !(pacedBefore3 || pacedNow3)
                && !ph.pacer.isPacedActive() && ph.rate == 120f;

        check("applyRate + scheduleNext matches ended() and tracks pacedBefore || pacedNow across exit",
                ok1 && ok2 && ok3, "ok1=" + ok1 + ", ok2=" + ok2 + ", ok3=" + ok3);
    }

    /** 22. cpuDeltaNanos, glWorkNanos, and measureGl separate GL work from raw wall time and measurement flags. */
    static void cpuDeltaAndGlWorkNanosCase() {
        // cpuDeltaNanos edge cases: both -1 (must NOT return 0!), single -1, backwards, normal.
        boolean cpuOk = FramePacer.cpuDeltaNanos(-1L, -1L) == -1L
                && FramePacer.cpuDeltaNanos(-1L, 1_000_000L) == -1L
                && FramePacer.cpuDeltaNanos(1_000_000L, -1L) == -1L
                && FramePacer.cpuDeltaNanos(5_000_000L, 4_000_000L) == -1L
                && FramePacer.cpuDeltaNanos(1_000_000L, 3_000_000L) == 2_000_000L;

        long d0 = 100_000_000L;
        // Non-paced with 48 ms GPU backpressure in swap: must report full 50 ms wall time.
        long nonPaced = FramePacer.glWorkNanos(d0, d0 + 2_000_000L, d0 + 50_000_000L, 2_000_000L, false);
        // Paced with 2 ms CPU and 50 ms wall (eglSwapBuffers sleep): reports 2 ms CPU.
        long pacedSwapSleep = FramePacer.glWorkNanos(d0, d0 + 2_000_000L, d0 + 50_000_000L, 2_000_000L, true);
        // Paced with lazy dequeueBuffer sleep inside draw (48 ms drawWall, 2 ms CPU): reports 2 ms CPU.
        long pacedLazyDequeue = FramePacer.glWorkNanos(d0, d0 + 48_000_000L, d0 + 50_000_000L, 2_000_000L, true);
        // Paced with CPU time unavailable (-1): falls back to pre-swap drawWall (2 ms), not 50 ms swapWall.
        long pacedNoCpu = FramePacer.glWorkNanos(d0, d0 + 2_000_000L, d0 + 50_000_000L, -1L, true);
        // Fallback path (swapEnd used as swapDoneNs, swapCpuEnd used for cpuDelta): excludes lazy dequeue sleep.
        long fallbackPaced = FramePacer.glWorkNanos(
                d0, d0 + 48_000_000L, d0 + 48_000_000L, FramePacer.cpuDeltaNanos(10_000_000L, 12_000_000L), true);

        // measureGl produces both workNs and rawWallNs from the same sample with paced/swapMeasured flags.
        FramePacer.GlTiming mPaced = FramePacer.measureGl(0L, 2_000_000L, 50_000_000L, 2_000_000L, true, true);
        FramePacer.GlTiming mFallback = FramePacer.measureGl(0L, 5_000_000L, 50_000_000L, 2_000_000L, true, false);
        FramePacer.GlTiming mNonPaced = FramePacer.measureGl(0L, 2_000_000L, 50_000_000L, 2_000_000L, false, true);
        boolean dualOk = mPaced.workNs == 2_000_000L && mPaced.rawWallNs == 50_000_000L && mPaced.paced && mPaced.swapMeasured
                && mFallback.workNs == 2_000_000L && mFallback.rawWallNs == 5_000_000L && mFallback.paced && !mFallback.swapMeasured
                && mNonPaced.workNs == 50_000_000L && mNonPaced.rawWallNs == 50_000_000L && !mNonPaced.paced && mNonPaced.swapMeasured;

        boolean workOk = nonPaced == 50_000_000L
                && pacedSwapSleep == 2_000_000L
                && pacedLazyDequeue == 2_000_000L
                && pacedNoCpu == 2_000_000L
                && fallbackPaced == 2_000_000L;
        check("cpuDeltaNanos, glWorkNanos & measureGl preserve backpressure, strip paced sleep, and keep raw wall",
                cpuOk && workOk && dualOk, "cpuOk=" + cpuOk + ", workOk=" + workOk + ", dualOk=" + dualOk);
    }

    /** 23. Production FramePacer.AdpfState end-to-end: IME wake, 60 Hz cap, failed vote, gesture release, stale matrix. */
    static void adpfTargetNanosAndTouchBoostCase() {
        long period50ms = 50_000_000L;
        long period33ms = 33_333_333L;
        long period16ms = 16_666_667L;
        long period8ms = 8_333_333L;
        long expectedTopTarget = (long) (1e9 / 120f) * 7L / 10L;  // 5_833_333 ns
        long expected60Target = period16ms * 7L / 10L;            // 11_666_666 ns
        long expectedPacedTarget = period50ms * 7L / 10L;         // 35_000_000 ns

        final List<Long> targets = new ArrayList<>();
        final List<Long> actuals = new ArrayList<>();
        FramePacer.AdpfSession sess = new FramePacer.AdpfSession() {
            @Override public void updateTargetWorkDuration(long nanos) { targets.add(nanos); }
            @Override public void reportActualWorkDuration(long nanos) { actuals.add(nanos); }
        };

        // 1. 20 Hz (50ms, topRate=120) touch -> wake -> IME wake (timeline still 50ms): stays 5.83ms, never 35ms.
        FramePacer.AdpfState st = new FramePacer.AdpfState();
        st.onSessionCreated(expectedPacedTarget, sess);
        targets.clear();
        actuals.clear();
        boolean boosted = st.beginTouchBoost(true, 1_000_000_000L, period50ms, 120f);
        st.wake(period50ms, 120f, false, true, 120f, false, sess);
        st.wake(period50ms, 120f, false, true, 120f, false, sess); // IME wakeHints() while timeline still 50ms
        boolean sc1 = boosted && st.boostActive
                && targets.equals(List.of(expectedTopTarget))
                && actuals.equals(List.of(expectedTopTarget, expectedTopTarget));

        // 2. Gesture ends (touching=false) on a system-capped 60 Hz (16.67ms) 120 Hz device: clears boost -> 11.67ms.
        targets.clear();
        actuals.clear();
        st.frameWorked(2_000_000L, 1_500_000L, 1_050_000_000L, period16ms, 120f, false, false, 120f, sess);
        boolean sc2 = !st.boostActive
                && targets.equals(List.of(expected60Target))
                && actuals.equals(List.of(2_000_000L));

        // 3. Rate lift transiently failed (pacedActive=true) while finger is still down (touching=true, 50ms):
        //    frameWorked keeps boostActive=true (5.83ms); once finger lifts (touching=false), clears boost -> 35ms.
        st.reset();
        st.onSessionCreated(expectedPacedTarget, sess);
        targets.clear();
        actuals.clear();
        st.beginTouchBoost(true, 2_000_000_000L, period50ms, 120f);
        st.frameWorked(3_000_000L, 1_000_000L, 2_010_000_000L, period50ms, 120f, true, true, 20f, sess);
        boolean keptWhileDown = st.boostActive && targets.equals(List.of(expectedTopTarget));
        targets.clear();
        st.frameWorked(3_000_000L, 1_000_000L, 2_020_000_000L, period50ms, 120f, true, false, 20f, sess);
        boolean clearedOnLift = !st.boostActive && targets.equals(List.of(expectedPacedTarget));
        boolean sc3 = keptWhileDown && clearedOnLift;

        // 4. Gesture ends and high-rate vote withdrawn (touching=false, rateSaid=0) even while period stays 50ms: clears boost.
        st.reset();
        st.onSessionCreated(expectedPacedTarget, sess);
        targets.clear();
        st.beginTouchBoost(true, 3_000_000_000L, period50ms, 120f);
        st.wake(period50ms, 120f, false, true, 120f, false, sess);
        targets.clear();
        st.frameWorked(2_000_000L, 1_000_000L, 3_100_000_000L, period50ms, 120f, false, false, 0f, sess);
        boolean sc4 = !st.boostActive && targets.equals(List.of(expectedPacedTarget));

        // 5. isStalePacedPeriod boundary matrix: {50ms, 33.3ms, 16.7ms, 8.3ms} x {120Hz, 90Hz, 60Hz, 0Hz}.
        boolean sc5 = FramePacer.isStalePacedPeriod(period50ms, 120f)
                && FramePacer.isStalePacedPeriod(period33ms, 120f)
                && !FramePacer.isStalePacedPeriod(period16ms, 120f)
                && !FramePacer.isStalePacedPeriod(period8ms, 120f)
                && FramePacer.isStalePacedPeriod(period50ms, 90f)
                && FramePacer.isStalePacedPeriod(period33ms, 90f)
                && !FramePacer.isStalePacedPeriod(period16ms, 90f)
                && !FramePacer.isStalePacedPeriod(period8ms, 90f)
                && FramePacer.isStalePacedPeriod(period50ms, 60f)
                && FramePacer.isStalePacedPeriod(period33ms, 60f)
                && !FramePacer.isStalePacedPeriod(period16ms, 60f)
                && !FramePacer.isStalePacedPeriod(period8ms, 60f)
                && !FramePacer.isStalePacedPeriod(period50ms, 0f)
                && !FramePacer.isStalePacedPeriod(period33ms, 0f)
                && !FramePacer.isStalePacedPeriod(period16ms, 0f)
                && !FramePacer.isStalePacedPeriod(period8ms, 0f);

        // 6. Fixed 120 Hz screen (8.33ms, topRate=120) with lastFrameWorked 50 ms ago (< 250 ms):
        //    beginTouchBoost(true) still returns true (bypasses 250 ms throttle) while keeping boostActive=false,
        //    and wake() reports expectedTopTarget (5.83ms) without clamping.
        st.reset();
        st.onSessionCreated(expectedTopTarget, sess);
        st.lastFrameWorkedNs = 4_000_000_000L;
        targets.clear();
        actuals.clear();
        boolean fixedWakeAllowed = st.beginTouchBoost(true, 4_050_000_000L, period8ms, 120f);
        st.wake(period8ms, 120f, false, true, 120f, false, sess);
        boolean sc6 = fixedWakeAllowed && !st.boostActive
                && targets.isEmpty()
                && actuals.equals(List.of(expectedTopTarget));

        check("AdpfState handles IME wake, 60 Hz cap, failed rate lift, vote release, stale matrix, and fixed-120 wake",
                sc1 && sc2 && sc3 && sc4 && sc5 && sc6,
                "sc1=" + sc1 + ", sc2=" + sc2 + ", sc3=" + sc3 + ", sc4=" + sc4 + ", sc5=" + sc5 + ", sc6=" + sc6);
    }

    /** 24. Picture-only redraw triggered from 20 Hz keeps picturedPaced even if posted recheckRate() lifts before takeRender(). */
    static void picturedPacedSurvivesEarlyRecheckCase() {
        Phone ph = new Phone(120, 3, true, 200_000);
        // Enter 20 Hz paced mode.
        long t1 = 12 * ph.period;
        ph.pacer.wantPacedFrame();
        ph.pacer.vsyncCame(t1, t1 + 2 * ph.period);
        FramePacer.Taken tkInit = ph.pacer.takeRender();
        FramePacer.Begun bInit = ph.pacer.begin(tkInit.vsyncAt, t1 + 200_000L, tkInit.external);
        ph.pacer.applyRate(false, false, bInit.following, 20f, bInit.externalDemand);
        ph.pacer.scheduleNext(false);
        boolean inPaced = ph.pacer.isPacedActive();

        // Picture arrives while paced: capture wasPaced, mark pictureActive, queue pictureFrame(wasPaced).
        boolean wasPaced = ph.pacer.isPacedActive();
        ph.pictureActive = true;
        ph.pacer.pictureFrame(wasPaced);
        // Simulate posted recheckRate() running on app thread BEFORE next vsync's frameOnApp().
        ph.pacer.recheckRate();
        boolean liftedEarly = !ph.pacer.isPacedActive() && ph.rate == 120f;

        // Next vsync arrives -> takeRender() still carries picturedPaced=true so transition frame is attributed.
        long t2 = 13 * ph.period;
        ph.pacer.vsyncCame(t2, t2 + 2 * ph.period);
        FramePacer.Taken tk1 = ph.pacer.takeRender();
        boolean pacedBefore1 = ph.pacer.isPacedActive();
        boolean ok1 = tk1.pictured && !tk1.app && tk1.picturedPaced && (pacedBefore1 || tk1.picturedPaced);

        // Subsequent normal picture redraw after exit must NOT inherit picturedPaced.
        ph.pacer.pictureFrame(ph.pacer.isPacedActive());
        long t3 = 14 * ph.period;
        ph.pacer.vsyncCame(t3, t3 + 2 * ph.period);
        FramePacer.Taken tk2 = ph.pacer.takeRender();
        boolean ok2 = tk2.pictured && !tk2.app && !tk2.picturedPaced;

        check("pictureFrame from 20 Hz retains picturedPaced across early recheckRate() and clears on next frame",
                inPaced && liftedEarly && ok1 && ok2,
                "inPaced=" + inPaced + ", liftedEarly=" + liftedEarly + ", ok1=" + ok1 + ", ok2=" + ok2);
    }

    public static void main(String[] args) throws IOException {
        motionCase("a motion of 1 ms CPU and 1 ms GPU a frame shows a new frame at every refresh", 1, 1, true);
        motionCase("a motion of 0.5 ms CPU and 7 ms GPU a frame (the GPU under a refresh) shows a new frame at every refresh", 0.5, 7, true);
        motionCase("the same, a driver whose swap does not wait for the GPU", 0.5, 7, false);
        motionCase("a motion of 6 ms CPU and 1 ms GPU a frame shows a new frame at every refresh", 6, 1, true);
        typingCase();
        rateAfterMotion();
        pacedCase();
        frameNowAfterPictureCase();
        imeWarmupRateCase();
        imeMovingWithAnimationCoalescesCase();
        imeMovingWithoutProgressFallsBackCase();
        frameNowDoesNotDuplicatePendingVsyncCase();
        imeMovingPureSlideKeepsTimelineCase();
        idleExternalFramesSayNoRateCase();
        paced20FixedScreenCase();
        paced20LtpoScreenCase();
        pacedExternalBurstLiftsCase();
        pacedNonPacedActiveLiftsCase();
        motionRateReleasesWithNativeViewAnimatingCase();
        pacedStopExitsLowRateCase();
        surfaceResetInvalidatesStillForCase();
        setRateFailureRetryCase();
        wakeReqAtomicMergeCase();
        wakeFrameNowSameVsyncNoDuplicateCase();
        sameVsyncExternalAfterBeginBeforeEndedCase();
        wakeReqConcurrentUpgradeNoDuplicateCase();
        aheadClaimedThenSameVsyncFireWakeCase();
        pictureUpgradedThenSameVsyncFireWakeCase();
        imeFlushAtomicWithPendingPictureCase();
        imeMovingFireWakeCoalescesCase();
        wantFrameBetweenTakeAndBeginPreservesExternalCase();
        oneModeFlushStalePictureDoesNotDoubleDrawCase();
        duplicateVsyncAtSameTDoesNotStallNextFrameCase();
        wantImmediateFrameClearsAheadForNextFrameCase();
        sameVsyncFireWakeAfterAskAheadDoesNotDoublePostCase();
        wantFrameBeforeFireWakeAtSameTDoesNotDoublePostCase();
        applyRateScheduleNextEquivalenceCase();
        cpuDeltaAndGlWorkNanosCase();
        adpfTargetNanosAndTouchBoostCase();
        picturedPacedSurvivesEarlyRecheckCase();
        if (args.length > 0) {
            replay(args[0], 1);
            replay(args[0], 7);
        }
        if (failures > 0) {
            System.out.println(failures + " failed");
            System.exit(1);
        }
    }
}
