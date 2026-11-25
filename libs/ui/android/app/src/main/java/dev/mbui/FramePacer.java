package dev.mbui;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Which vsync the app's next frame is drawn for, and what rate the surface says of the display (MBView's, kept apart
 * from Android so a test can run it: FramePacerTest, on its own clock and threads). MBView hands it the system's
 * vsyncs, the frames' work and the hand; it asks MBView's Platform for a vsync, a frame made and a rate said. Its
 * threads are MBView's: the main thread's (vsyncs, the hand), the drawing thread's (the app's thread, which makes the
 * frames, the GL thread drawing each it hands over; the GL thread itself with MBView.ONE: frames, the rate), any (a
 * frame wanted).
 */
final class FramePacer {
    /** What the pacer asks of the system (MBView's; the test's own). */
    interface Platform {
        /** The system's clock (ns), the vsyncs'. */
        long nanoTime();

        /** Whether this is the main thread. */
        boolean onMain();

        /** {@code r} run on the main thread, after what is there now. */
        void postMain(Runnable r);

        /** The next vsync asked for (main thread): {@link #vsyncCame} told at it. */
        void postVsync();

        /** {@code r} run on the drawing thread once the next vsync has come (asked on the main thread). */
        void atNextVsyncOnDrawing(Runnable r);

        /** A frame made on the drawing thread, as soon as it can (MBView.makeFrame; GLSurfaceView's requestRender with ONE). */
        void requestRender();

        /** The surface says the display's rate {@code rate} (0: nothing); false where it cannot be said. */
        boolean setRate(float rate);

        /** Whether the app's field is being typed into (the focus, or the soft keyboard up over it). */
        boolean typing();

        /** Whether GL adaptive glass is currently settling and needs high refresh. */
        default boolean glSettling() {
            return false;
        }

        /** Whether a native view's picture recently redrew and needs high refresh. */
        default boolean pictureActive() {
            return false;
        }
    }

    private final Platform p;

    FramePacer(Platform p) {
        this.p = p;
    }

    /**
     * The display's frame (ns), read as the view is shown and as the display changes its rate, and since Android 13 from
     * each vsync's timelines (main thread).
     */
    volatile long framePeriod = 16_666_667L;
    /** The display's highest rate at its size now (MBView's readFramePeriod). */
    volatile float topRate;
    /** Whether a finger is on the screen (main thread writes it, from its touches). */
    volatile boolean touching;

    /**
     * The vsync the next frame is drawn for and when the system is to show it (ns, the system's clock; 0: not said): since
     * Android 13, the expected presentation of the vsync's preferred frame timeline (Choreographer.FrameData), the
     * refresh a frame of the system's own drawn for that vsync is shown at.
     */
    private volatile long[] vsyncAt = {0, 0};
    private final AtomicBoolean wanted = new AtomicBoolean();
    /**
     * A vsync asked for ahead came and no frame was drawn for it (vsyncCame): the next frame wanted is drawn at once,
     * for it, while it is the latest vsync (a frame later than that is the next vsync's).
     */
    private final AtomicBoolean ahead = new AtomicBoolean();
    /** A frame asked of the app (wantFrame), or only for a view's picture (pictureFrame), since the last was drawn. */
    final AtomicBoolean appWanted = new AtomicBoolean(), picturesOnly = new AtomicBoolean();
    /** Non-paced external demand (wantFrame/frameNow), distinguished from paced timer wakeups (wantPacedFrame). */
    final AtomicBoolean externalWanted = new AtomicBoolean();
    /** External demand arriving for an already-dispatched vsync, consumed at that frame's ended(). */
    private final AtomicLong externalForVsync = new AtomicLong(0L);

    /** Timed wake request: merges same-deadline requests in place under wakeLock while preserving external demand. */
    static final class WakeReq {
        final long gen;
        final double at;
        volatile boolean pacedOnly;

        WakeReq(long gen, double at, boolean pacedOnly) {
            this.gen = gen;
            this.at = at;
            this.pacedOnly = pacedOnly;
        }

        boolean isPacedOnly() {
            return pacedOnly;
        }
    }

    private final Object wakeLock = new Object();
    private long wakeGen;
    private WakeReq wakeReq;

    /** Schedules or upgrades a timed wake; returns the new request to post, or null if an earlier/same-deadline one stands. */
    WakeReq scheduleWake(double at, boolean pacedOnly) {
        synchronized (wakeLock) {
            if (wakeReq != null) {
                if (wakeReq.at < at) return null;
                if (wakeReq.at == at) {
                    if (!pacedOnly) wakeReq.pacedOnly = false;
                    return null;
                }
            }
            WakeReq next = new WakeReq(++wakeGen, at, pacedOnly);
            wakeReq = next;
            return next;
        }
    }

    /** Clears any pending timed wake (called as a new app frame begins). */
    void clearWake() {
        synchronized (wakeLock) {
            wakeReq = null;
        }
    }

    /** Whether {@code req} is still the active scheduled wake. */
    boolean isWakeCurrent(WakeReq req) {
        synchronized (wakeLock) {
            return req != null && wakeReq == req;
        }
    }

    /** Atomic snapshot of frame demand and vsync timeline taken by the drawing thread. */
    static final class Taken {
        final boolean app, pictured, external, picturedPaced;
        final long[] vsyncAt;

        Taken(boolean app, boolean pictured, boolean external, boolean picturedPaced, long[] vsyncAt) {
            this.app = app;
            this.pictured = pictured;
            this.external = external;
            this.picturedPaced = picturedPaced;
            this.vsyncAt = vsyncAt;
        }
    }

    private final Object dispatchLock = new Object();
    /** Whether the current vsyncAt has been dispatched for an app frame (prevents stealing T+1's appWanted early). */
    private boolean appDispatched;
    /** Whether a pending picture-only redraw originated while a low-rate paced vote was active (guarded by dispatchLock). */
    private boolean picturedFromPaced;

    /** Atomically consumes pending frame flags, reads vsyncAt, and claims vsyncAt[0] when building an app frame. */
    Taken takeRender() {
        synchronized (dispatchLock) {
            boolean app = appDispatched && appWanted.getAndSet(false);
            if (app) {
                appDispatched = false;
                ahead.set(false);
            }
            boolean pictured = picturesOnly.getAndSet(false);
            boolean picturedPaced = pictured && picturedFromPaced;
            if (pictured) picturedFromPaced = false;
            boolean external = app && externalWanted.getAndSet(false);
            long[] at = vsyncAt;
            if (app && at[0] != 0) lastAppDispatchedVsyncNs.set(at[0]);
            return new Taken(app, pictured, external, picturedPaced, at);
        }
    }

    /** Marks an immediate app frame without waiting for the next vsync (e.g. mid-frame imeBottom change). */
    void wantImmediateFrame() {
        synchronized (dispatchLock) {
            appWanted.set(true);
            appDispatched = true;
        }
    }

    /** Delivers a due timed wake directly on the current Choreographer vsync (main thread). */
    void wakeFrameNow(long vsyncNs, long shows, boolean pacedOnly) {
        boolean needFlushPost = false;
        boolean shouldRender = false;
        synchronized (dispatchLock) {
            if (vsyncNs != 0 && lastAppDispatchedVsyncNs.get() == vsyncNs) {
                if (!pacedOnly) externalForVsync.set(vsyncNs);
            } else if (imeMoving) {
                deferredWakeApp = true;
                if (!pacedOnly) deferredWakeExternal = true;
                ahead.set(false);
                if (!deferredVsync) {
                    deferredVsyncT = vsyncNs;
                    deferredVsyncShows = shows;
                    deferredVsync = true;
                    deferredFromVsync = false;
                    needFlushPost = true;
                } else if (deferredVsyncShows == 0 && shows != 0) {
                    deferredVsyncShows = shows;
                }
            } else {
                if (!pacedOnly) externalWanted.set(true);
                appWanted.set(true);
                appDispatched = true;
                ahead.set(false);
                if (vsyncNs != 0) lastAppDispatchedVsyncNs.set(vsyncNs);
                lastFrameNowAt = vsyncNs;
                if (deferredVsync) {
                    boolean fromVsync = deferredFromVsync;
                    deferredVsync = false;
                    deferredFromVsync = false;
                    deferredWakeApp = false;
                    deferredWakeExternal = false;
                    vsyncAt = new long[] {deferredVsyncT, deferredVsyncShows};
                    if (fromVsync) clearWantedForLocked(deferredVsyncT);
                } else {
                    long s = shows != 0 ? shows : (vsyncAt[0] == vsyncNs ? vsyncAt[1] : 0);
                    vsyncAt = new long[] {vsyncNs, s};
                }
                shouldRender = true;
            }
        }
        if (needFlushPost) p.postMain(this::flushDeferredVsync);
        else if (shouldRender) p.requestRender();
    }

    /** Convenience overload with shows = 0 (API < 33). */
    int fireWake(WakeReq req, long vsyncNs) {
        return fireWake(req, vsyncNs, 0);
    }

    /**
     * Evaluates a scheduled wake at Choreographer {@code doFrame(vsyncNs)} / {@code onVsync(vsyncNs, shows)} (main thread):
     * 0 = stale/replaced, 1 = not yet due (re-post next vsync), 2 = delivered on this vsync, 3 = requested for next vsync.
     */
    int fireWake(WakeReq req, long vsyncNs, long shows) {
        int action;
        boolean pacedOnly;
        synchronized (wakeLock) {
            if (req == null || wakeReq != req) return 0;
            if (vsyncNs / 1e6 >= req.at - 0.5) {
                wakeReq = null;
                pacedOnly = req.pacedOnly;
                action = 2;
            } else if ((vsyncNs + framePeriod) / 1e6 >= req.at - 0.5) {
                wakeReq = null;
                pacedOnly = req.pacedOnly;
                action = 3;
            } else {
                return 1;
            }
        }
        if (action == 2) {
            wakeFrameNow(vsyncNs, shows, pacedOnly);
        } else {
            if (pacedOnly) wantPacedFrame();
            else wantFrame();
        }
        return action;
    }

    private double lastFrame;
    // the frame before's vsync (0: none, or it had none), and whether it asked for this one (askAhead: the vsync after
    // its own, or where its work went past that one, the first after its work)
    private long lastVsync;
    private boolean askedAtEnd;
    // main-thread state for coalescing CALLBACK_ANIMATION (vsyncCame) with CALLBACK_INSETS_ANIMATION (frameNow)
    private boolean imeMoving;
    private boolean deferredVsync;
    private boolean deferredFromVsync;
    private boolean deferredWakeApp;
    private boolean deferredWakeExternal;
    private long deferredVsyncT, deferredVsyncShows;
    private long lastFrameNowAt;
    private long wantedAfterVsyncNs;
    private final AtomicLong lastAppDispatchedVsyncNs = new AtomicLong(0L);

    private boolean nonPacedActive() {
        return p.glSettling() || p.pictureActive();
    }

    private boolean claimPostVsyncLocked() {
        if (!wanted.compareAndSet(false, true)) return false;
        wantedAfterVsyncNs = lastAppDispatchedVsyncNs.get();
        return true;
    }

    private void postVsyncOutOfLock() {
        if (p.onMain()) p.postVsync();
        else p.postMain(p::postVsync);
    }

    private void clearWantedForLocked(long t) {
        if (!(wanted.get() && t != 0 && wantedAfterVsyncNs >= t)) {
            wanted.set(false);
        }
    }

    /** Handles a duplicate vsync callback for an already-dispatched vsync t (inside dispatchLock). Returns 2 to postVsync. */
    private int handleDuplicateVsyncLocked(long t) {
        clearWantedForLocked(t);
        if (appWanted.get() && !appDispatched) {
            return claimPostVsyncLocked() ? 2 : 0;
        }
        return 0;
    }

    private void armImeVsync() {
        boolean postNext = false;
        synchronized (dispatchLock) {
            if (imeMoving) postNext = claimPostVsyncLocked();
        }
        if (postNext) postVsyncOutOfLock();
    }

    /** Whether the soft keyboard's inset animation is under way (main thread). */
    void setImeMoving(boolean moving) {
        imeMoving = moving;
        if (moving) armImeVsync();
        else if (deferredVsync) flushDeferredVsync();
    }

    /** The vsync the frame beginning now is for (its time, when it is shown; 0: not said). */
    long[] vsyncAt() {
        return vsyncAt;
    }

    /** Returns 0 = no-op, 1 = requestRender, 2 = postVsync for T+1. */
    private int dispatchVsyncLocked(long t, long shows, boolean fromVsync) {
        vsyncAt = new long[] {t, shows};
        boolean app = appWanted.get();
        if (t != 0 && lastAppDispatchedVsyncNs.get() == t) {
            if (fromVsync) {
                int dup = handleDuplicateVsyncLocked(t);
                if (dup != 0) return dup;
            }
            return (!app && picturesOnly.get()) ? 1 : 0;
        }
        if (app || picturesOnly.get()) {
            ahead.set(false);
            if (fromVsync) clearWantedForLocked(t);
            if (app) {
                if (t != 0) lastAppDispatchedVsyncNs.set(t);
                appDispatched = true;
            }
            return 1;
        }
        ahead.set(true);
        if (fromVsync) clearWantedForLocked(t);
        // (a frame wanted as this was kept: the one asking saw it not yet kept, and asked for another vsync, or none)
        boolean app2 = appWanted.get();
        if ((app2 || picturesOnly.get()) && ahead.getAndSet(false)) {
            if (app2) {
                if (t != 0) lastAppDispatchedVsyncNs.set(t);
                appDispatched = true;
            }
            return 1;
        }
        return 0;
    }

    private void finishDispatch(int act) {
        if (act == 1) p.requestRender();
        else if (act == 2) postVsyncOutOfLock();
    }

    private void dispatchVsync(long t, long shows) {
        int act;
        synchronized (dispatchLock) {
            act = dispatchVsyncLocked(t, shows, true);
        }
        finishDispatch(act);
    }

    private void flushDeferredVsync() {
        int act;
        synchronized (dispatchLock) {
            if (!deferredVsync) return;
            boolean fromVsync = deferredFromVsync;
            deferredVsync = false;
            deferredFromVsync = false;
            long t = deferredVsyncT, shows = deferredVsyncShows;
            vsyncAt = new long[] {t, shows};
            if (deferredWakeApp) {
                if (deferredWakeExternal) externalWanted.set(true);
                appWanted.set(true);
                deferredWakeApp = false;
                deferredWakeExternal = false;
            }
            act = dispatchVsyncLocked(t, shows, fromVsync);
        }
        finishDispatch(act);
    }

    /**
     * A vsync asked for came (main thread), at {@code t}, its frame shown at {@code shows} (vsyncAt): drawn for, where a
     * frame is wanted; where only the frame drawing now asked for it ahead (askAhead), kept for that frame to take as it
     * ends (ask), should it want one.
     */
    void vsyncCame(long t, long shows) {
        boolean needFlushPost = false;
        int act = 0;
        synchronized (dispatchLock) {
            if (shows != 0 && vsyncAt[0] == t && vsyncAt[1] == 0) {
                vsyncAt = new long[] {t, shows};
            }
            if (lastFrameNowAt != 0 && t <= lastFrameNowAt && lastFrameNowAt - t < framePeriod / 2) {
                act = handleDuplicateVsyncLocked(t);
            } else if (imeMoving) {
                deferredVsyncT = t;
                deferredVsyncShows = shows;
                deferredVsync = true;
                deferredFromVsync = true;
                needFlushPost = true;
            } else {
                act = dispatchVsyncLocked(t, shows, true);
            }
        }
        if (needFlushPost) p.postMain(this::flushDeferredVsync);
        else finishDispatch(act);
    }

    /**
     * The vsync after the frame beginning now asked for before its work (drawing thread), where the frame before asked
     * for this one (a motion going on): a frame asked for only as it ended had the first vsync after its work, so one
     * whose work went past the display's frame left a refresh with no new frame, what moved standing still for one and
     * then stepping two (an OPPO Find N6's inner screen, its frames 6–16 ms at 120 Hz). Asked ahead, the vsync comes
     * while the frame is drawn; one that ends after it draws the next at once, for that vsync and shown at its refresh
     * (showAt), as the system's own frames are asked for in the vsync before theirs: a frame over the display's frame
     * costs nothing where the next is lighter.
     */
    private void askAhead() {
        boolean postNext;
        synchronized (dispatchLock) {
            ahead.set(false);
            postNext = claimPostVsyncLocked();
        }
        if (postNext) p.postMain(p::postVsync);
    }

    /** A frame wanted (atomically sets flags under dispatchLock, from any thread): drawn for the vsync kept, or the next. */
    private void ask(boolean forApp, boolean isExternal, boolean fromPaced) {
        boolean renderNow = false;
        boolean postNext = false;
        synchronized (dispatchLock) {
            if (forApp) {
                if (isExternal) externalWanted.set(true);
                appWanted.set(true);
            } else {
                picturesOnly.set(true);
                if (fromPaced) picturedFromPaced = true;
            }
            boolean alreadyPendingForT = false;
            if (ahead.getAndSet(false) && p.nanoTime() - vsyncAt[0] < framePeriod) {
                long t = vsyncAt[0];
                if (forApp && t != 0 && lastAppDispatchedVsyncNs.getAndSet(t) == t) {
                    if (appDispatched) alreadyPendingForT = true;
                } else {
                    if (forApp) appDispatched = true;
                    renderNow = true;
                }
            }
            if (!alreadyPendingForT && !renderNow) {
                postNext = claimPostVsyncLocked();
            }
        }
        if (renderNow) p.requestRender();
        else if (postNext) postVsyncOutOfLock();
    }

    /** A frame at the next vsync (from any thread). */
    void wantFrame() {
        ask(true, true, false);
    }

    /** A paced timer wakeup frame at the next vsync (from any thread): does not mark externalDemand. */
    void wantPacedFrame() {
        ask(true, false, false);
    }

    /** Only a native view's picture to show again (from any thread): the last frame drawn again at the next vsync. */
    void pictureFrame() {
        pictureFrame(pacedActive);
    }

    /** Picture-only redraw with caller-captured paced state (sampled before lifting a low-rate vote). */
    void pictureFrame(boolean fromPaced) {
        ask(false, false, fromPaced);
    }

    /**
     * A frame now, at the vsync being drawn (main thread, within a Choreographer frame: the keyboard's motion), not the
     * next. (The frame's own vsync time is not public: now, a moment after it, never before a frame drawn; shown as soon
     * as it is drawn.)
     */
    void frameNow() {
        synchronized (dispatchLock) {
            externalWanted.set(true);
            appWanted.set(true);
            appDispatched = true;
            ahead.set(false);
            long now = p.nanoTime();
            lastFrameNowAt = now;
            long dt = deferredVsync ? deferredVsyncT : now;
            if (dt != 0) lastAppDispatchedVsyncNs.set(dt);
            if (deferredVsync) {
                boolean fromVsync = deferredFromVsync;
                deferredVsync = false;
                deferredFromVsync = false;
                deferredWakeApp = false;
                deferredWakeExternal = false;
                vsyncAt = new long[] {deferredVsyncT, deferredVsyncShows};
                if (fromVsync) clearWantedForLocked(deferredVsyncT);
            } else {
                vsyncAt = new long[] {now, 0};
            }
        }
        p.requestRender();
        armImeVsync();
    }

    /** The last frame drawn again for a view's picture alone (drawing thread): it asked for none after it. */
    void redrawn() {
        if (!appWanted.get()) askedAtEnd = false;
    }

    /** A frame of the app's begun (drawing thread): the time it is built for, how late it is, whether it follows. */
    static final class Begun {
        /** its vsync (0: none) and when it is shown (0: not said) */
        final long vsync, shows;
        /** the time it is built for (ms) and how late the frame before reached the screen (ms: @hostapi.frame_late) */
        final double now, late;
        /** drawn at the vsync after the frame before's: the hand moving what it holds, a frame each vsync */
        final boolean following;
        /** whether an external (non-paced) frame request triggered this frame */
        final boolean externalDemand;

        Begun(long vsync, long shows, double now, double late, boolean following, boolean externalDemand) {
            this.vsync = vsync;
            this.shows = shows;
            this.now = now;
            this.late = late;
            this.following = following;
            this.externalDemand = externalDemand;
        }
    }

    /** The app's frame beginning now (drawing thread), at {@code began} (the system's clock), for {@code at} (vsyncAt). */
    Begun begin(long[] at, long began) {
        return begin(at, began, externalWanted.getAndSet(false));
    }

    /** The app's frame beginning now (drawing thread) with {@code externalDemand} atomically taken by {@link #takeRender()}. */
    Begun begin(long[] at, long began, boolean externalDemand) {
        // (the frame before asked for this one: the one after it asked for now, before this one's work: askAhead)
        if (askedAtEnd) askAhead();
        // the vsync's time; a frame the system asked for (a resize) has none, and time never goes back
        long v = at[0];
        double now = v != 0 ? v / 1e6 : began / 1e6;
        if (now < lastFrame) now = lastFrame;
        lastFrame = now;
        // how late the frame before reached the screen (@hostapi.frame_late): the display's frames that passed past the one
        // after it without a frame, on the vsyncs' grid (its work over the display's frame and drawn on for the vsync it
        // asked ahead, shown at that vsync's refresh: none passed, it was in time; past that one too, this one's vsync is
        // the first after its work); 0 where it did not ask for this one (its vsync perhaps one during that work), or
        // either has no vsync. (Counted from when its work ended, a frame drawn on at once for the vsync asked ahead was
        // said late by a frame it was not: a page let go as the finger lifts, its slide held a frame and its first step
        // shown twice.)
        double late = 0;
        if (v != 0 && lastVsync != 0 && askedAtEnd) {
            long frames = Math.round((double) (v - lastVsync) / framePeriod);
            if (frames > 1) late = (frames - 1) * framePeriod / 1e6;
        }
        // drawn at the vsync after the frame before's: the hand moving what it holds, a frame each vsync
        boolean following = v > lastVsync && lastVsync != 0 && v - lastVsync < framePeriod * 3 / 2;
        lastVsync = v;
        return new Begun(v, at[1], now, late, following, externalDemand);
    }

    /**
     * The app's frame ended (drawing thread): whether it asks for another ({@code more}, what it said; {@code later}, a
     * back said for a later vsync), whether it followed the one before (Begun's), and the rate what moves on by the
     * clock alone needs where the frame said one ({@code paced}, MBView.framesPaced: its next woken for, not asked for
     * here; 0 none): the rate said, the next asked for. Paced, what moves is said at its rate, the display free to
     * refresh as slowly; anything else moving, at the display's highest.
     */
    void ended(boolean more, boolean later, boolean following, float paced) {
        ended(more, later, following, paced, false);
    }

    void ended(boolean more, boolean later, boolean following, float paced, boolean externalDemand) {
        applyRate(more, later, following, paced, externalDemand);
        scheduleNext(more || later);
    }

    /** Applies the frame's display-rate vote and returns whether a low-rate paced vote is active. */
    boolean applyRate(boolean more, boolean later, boolean following, float paced, boolean externalDemand) {
        boolean ext = externalDemand || (lastVsync != 0 && externalForVsync.compareAndSet(lastVsync, 0L));
        askedAtEnd = more || later;
        drawn++;
        if (paced > 0 && !more && !later && !touching && !p.typing() && !ext
                && !appWanted.get() && !nonPacedActive()) {
            moved = drawn;
            if (sayRate(paced)) {
                pacedSaid = true;
                pacedActive = true;
                // Dekker barrier recheck: if GL thread set nonPacedActive just as pacedActive became true, lift now.
                if (nonPacedActive()) recheckRate();
            }
        } else {
            boolean wasPaced = pacedSaid;
            if (wasPaced && paced == 0 && !more && !later && !touching && !p.typing()
                    && !ext && !nonPacedActive() && !appWanted.get()) {
                // Pure paced animation ended naturally (even with following==true on 50ms LTPO): drop directly to 0.
                if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
            } else if (more || later || following || p.typing() || touching) {
                if (topRate > 0) {
                    if (sayRate(true)) {
                        moved = drawn;
                        if (!more && !later && !p.typing() && !touching && rateSaid != 0) stillAfter(moved);
                    }
                } else if (wasPaced) {
                    if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
                }
            } else if (wasPaced || paced > 0) {
                if (topRate > 0) {
                    if (sayRate(true)) {
                        moved = drawn;
                        if (rateSaid != 0) stillAfter(moved);
                    }
                } else {
                    if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
                }
            } else if (rateSaid != 0) {
                stillAfter(moved);
            }
        }
        return pacedActive;
    }

    /** Schedules the next frame (or clears ahead) after handing over the current frame. */
    void scheduleNext(boolean wantMore) {
        if (wantMore) wantFrame();
        else ahead.set(false);
    }

    /** Valid thread CPU delta in ns, or -1 if either sample is unavailable or moved backwards. */
    static long cpuDeltaNanos(long cpuStartNs, long cpuEndNs) {
        return (cpuStartNs >= 0L && cpuEndNs >= cpuStartNs) ? (cpuEndNs - cpuStartNs) : -1L;
    }

    /**
     * GL thread work duration (ns): non-paced swaps keep full wall time (including real GPU backpressure);
     * paced swaps exclude intentional pacing sleep in eglSwapBuffers / lazy dequeueBuffer via thread CPU time,
     * falling back to pre-swap wall time if CPU time is unavailable.
     */
    static long glWorkNanos(long drawStartNs, long drawEndNs, long swapDoneNs, long cpuDeltaNs, boolean pacedSwap) {
        long wallNs = Math.max(0L, swapDoneNs - drawStartNs);
        if (!pacedSwap) return wallNs;
        if (cpuDeltaNs >= 0L) return Math.min(wallNs, cpuDeltaNs);
        return Math.min(wallNs, Math.max(0L, drawEndNs - drawStartNs));
    }

    /** ADPF target work duration (70% of period), optionally clamped to the display's top refresh rate. */
    static long adpfTargetNanos(long framePeriodNs, float topRate, boolean clampToTop) {
        long period = framePeriodNs;
        if (clampToTop && topRate > 0f) {
            long topPeriod = (long) (1e9 / topRate);
            if (topPeriod > 0L && (period <= 0L || topPeriod < period)) period = topPeriod;
        }
        return period > 0L ? period * 7L / 10L : 0L;
    }

    /**
     * Whether {@code framePeriodNs} is still a stale low-rate paced timeline (20-30 Hz: 33-50 ms) rather than
     * a normal or system-capped interactive rate (e.g. 60 Hz = 16.67 ms on a 120 Hz panel).
     */
    static boolean isStalePacedPeriod(long framePeriodNs, float topRate) {
        if (topRate <= 0f || framePeriodNs <= 0L) return false;
        long threshold = Math.max(20_000_000L, (long) (1.75e9 / topRate));
        return framePeriodNs > threshold;
    }

    /** Minimal ADPF hint session interface (plain Java, no Android dependency). */
    interface AdpfSession {
        void updateTargetWorkDuration(long nanos);

        void reportActualWorkDuration(long nanos);
    }

    /**
     * Unified ADPF target/boost policy state (drawing thread), shared across touch boost, IME warmup,
     * resume, session creation, and per-frame work reporting.
     */
    static final class AdpfState {
        boolean boostActive;
        long hintTarget;
        long lastFrameWorkedNs;

        void reset() {
            boostActive = false;
            hintTarget = 0L;
        }

        private void refreshBoost(long framePeriodNs, float topRate, boolean pacedActive, boolean touching, float rateSaid) {
            if (!boostActive) return;
            if (!isStalePacedPeriod(framePeriodNs, topRate)
                    || (!touching && (pacedActive || rateSaid == 0f))) {
                boostActive = false;
            }
        }

        long targetNanos(long framePeriodNs, float topRate, boolean pacedActive, boolean touching, float rateSaid) {
            refreshBoost(framePeriodNs, topRate, pacedActive, touching, rateSaid);
            return adpfTargetNanos(framePeriodNs, topRate, boostActive);
        }

        boolean onSessionCreated(long target, AdpfSession session) {
            hintTarget = target;
            if (session != null && target > 0L) {
                session.reportActualWorkDuration(target);
                return true;
            }
            return false;
        }

        boolean beginTouchBoost(boolean fromPaced, long nowNs, long framePeriodNs, float topRate) {
            if (fromPaced) {
                if (isStalePacedPeriod(framePeriodNs, topRate)) {
                    boostActive = true;
                }
                return true;
            }
            if (boostActive) return true;
            return lastFrameWorkedNs == 0L || nowNs - lastFrameWorkedNs >= 250_000_000L;
        }

        void wake(long framePeriodNs, float topRate, boolean pacedActive, boolean touching, float rateSaid,
                  boolean created, AdpfSession session) {
            long target = targetNanos(framePeriodNs, topRate, pacedActive, touching, rateSaid);
            if (session == null) return;
            if (target > 0L && target != hintTarget) {
                hintTarget = target;
                session.updateTargetWorkDuration(target);
            }
            if (!created && hintTarget > 0L) {
                session.reportActualWorkDuration(hintTarget);
            }
        }

        void frameWorked(long nanos, long gl, long nowNs, long framePeriodNs, float topRate,
                         boolean pacedActive, boolean touching, float rateSaid, AdpfSession session) {
            lastFrameWorkedNs = nowNs;
            long target = targetNanos(framePeriodNs, topRate, pacedActive, touching, rateSaid);
            if (session == null) return;
            if (target > 0L && target != hintTarget) {
                hintTarget = target;
                session.updateTargetWorkDuration(target);
            }
            long actual = Math.max(nanos, gl);
            if (actual > 0L) session.reportActualWorkDuration(actual);
        }
    }

    /** Dual GL timing reading: ADPF/work duration alongside raw wall time and measurement flags. */
    static final class GlTiming {
        final long workNs;
        final long rawWallNs;
        final boolean paced;
        final boolean swapMeasured;

        GlTiming(long workNs, long rawWallNs, boolean paced, boolean swapMeasured) {
            this.workNs = workNs;
            this.rawWallNs = rawWallNs;
            this.paced = paced;
            this.swapMeasured = swapMeasured;
        }
    }

    /** Computes both GL work duration and raw wall duration from a single GL frame sample. */
    static GlTiming measureGl(long d0, long drawEnd, long swapEnd, long cpuDeltaNs, boolean paced, boolean swapMeasured) {
        long effectiveEnd = swapMeasured ? swapEnd : drawEnd;
        long rawWallNs = Math.max(0L, effectiveEnd - d0);
        long workNs = glWorkNanos(d0, drawEnd, effectiveEnd, cpuDeltaNs, paced);
        return new GlTiming(workNs, rawWallNs, paced, swapMeasured);
    }

    // ---- the display's rate ----

    /**
     * The rate this surface's frames want of the display (Surface.setFrameRate), said as the system's own views say
     * theirs (a list flung, a view moved: Android 15's frame rate categories): the display's highest while the app
     * draws frame after frame (a motion, the hand moving what it holds), and from a finger going down (as the system's
     * touch boost: the motion it starts is not where the display goes over to it) until it lifts; nothing once a vsync
     * passes with none drawn and no finger on the screen. Withdrawn as a single vsync passed with none drawn while a
     * finger was down, it went down and up again within a gesture, wherever a vsync brought no touch (a finger slowing,
     * the touches' own rate a little off the display's), and each change of the display's rate can step what moves (OPPO
     * Find N6, 0.1.5814: scrolling stepped all along, its frames 1.3–2.7 ms).
     * A surface that says nothing is left at the rate the system picks for it from how often its buffers came: a phone
     * that does 120 Hz (an OPPO Find N6) kept the display at 60 for the app, every motion with half the frames its
     * own views' get. Said only while it moves: a rate said keeps the display at it for as long as the surface shows,
     * still or not.
     */
    /** The rate this surface says of the display now (drawing thread; 0 none: a new surface says nothing). */
    private float rateSaid;
    /** Whether the current rate vote is a low-rate paced vote (drawing thread). */
    private boolean pacedSaid;
    /** Read-only mirror of {@link #pacedSaid} for the GL thread to check without a data race. */
    private volatile boolean pacedActive;
    /** Surface generation counter: invalidates stale stillFor countdowns across surface recreation (drawing thread). */
    private int surfaceGen;
    /** The app's frames drawn (drawing thread): one drawn since a frame that asked for none is told by it. */
    private int drawn;
    /** The last frame drawn that moved something (drawing thread): a motion, the hand moving what it holds. */
    private int moved;
    /** The motion whose end is being counted down to saying no rate (drawing thread; -1 none). */
    private int stillFrom = -1;

    /** The rate the surface says of the display now (drawing thread; 0 none). */
    float rateSaid() {
        return rateSaid;
    }

    /** Whether the surface is currently holding a low-rate paced vote (readable from any thread). */
    boolean isPacedActive() {
        return pacedActive;
    }

    /** The surface says the display's highest rate, or nothing (drawing thread). */
    boolean sayRate(boolean on) {
        if (on && topRate <= 0) return false;
        if (sayRate(on ? topRate : 0)) {
            pacedSaid = false;
            pacedActive = false;
            return true;
        }
        return false;
    }

    /** The surface says the display's rate {@code rate} (drawing thread; 0 nothing). */
    private boolean sayRate(float rate) {
        if (rate == rateSaid) return true;
        if (p.setRate(rate)) {
            rateSaid = rate;
            return true;
        }
        return false;
    }

    /** Exits a low-rate paced vote immediately if non-paced work became active (drawing thread). */
    void recheckRate() {
        if (!pacedSaid || !nonPacedActive()) return;
        if (topRate > 0) {
            if (sayRate(true)) {
                moved = ++drawn;
                if (rateSaid != 0) stillAfter(moved);
            }
        } else {
            if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
        }
    }

    /** Bounded retry when releasing a paced vote via setRate(0) fails transiently (drawing thread). */
    private void retryRelease(int at, int gen, int attempts) {
        if (attempts >= 3) return;
        p.atNextVsyncOnDrawing(() -> {
            if (gen != surfaceGen || drawn != at || appWanted.get() || touching || p.typing() || rateSaid == 0) return;
            if (!sayRate(false)) retryRelease(at, gen, attempts + 1);
        });
    }

    /** Resets surface-bound rate state when the Surface is destroyed (drawing thread). */
    void surfaceReset() {
        surfaceGen++;
        rateSaid = 0;
        pacedSaid = false;
        pacedActive = false;
        stillFrom = -1;
    }

    /**
     * The motion that ended with frame {@code at} (drawing thread): no rate said once the display's highest rate's worth of
     * vsyncs (a second) passed with nothing moved since, none asked and no finger down. A frame drawn meanwhile that moves
     * nothing (a spinner's step, a page's words coming in) does not keep it. Said at once after the motion, the display
     * went down to the rate the system picks from how often frames came (a spinner stepping: 12-60 Hz on an OPPO Find
     * N6), and the next flick's first frames stepped up through it at 83, 17, 17, 17 ms before 8.3 (2026-11-04: 5-8
     * frames at the start of every swipe, the app's own work 2-5 ms each): a list is flicked again well within a second.
     */
    private void stillAfter(int at) {
        if (stillFrom == at) return;
        stillFrom = at;
        stillFor(at, surfaceGen, Math.max(1, Math.round(topRate)), 0);
    }

    private void stillFor(int at, int gen, int left, int failRetries) {
        p.atNextVsyncOnDrawing(() -> {
            if (gen != surfaceGen) return;
            if (moved != at || appWanted.get() || touching || p.typing() || rateSaid == 0) {
                if (stillFrom == at) stillFrom = -1;
                return;
            }
            if (p.glSettling()) {
                stillFor(at, gen, Math.max(1, Math.round(topRate)), 0);
                return;
            }
            if (left > 1) {
                stillFor(at, gen, left - 1, 0);
                return;
            }
            if (sayRate(false)) {
                stillFrom = -1;
            } else if (failRetries < 3) {
                stillFrom = at;
                stillFor(at, gen, 1, failRetries + 1);
            } else if (stillFrom == at) {
                stillFrom = -1;
            }
        });
    }

    /** The field's typing begun or ended (drawing thread): the rate said or let go from now. */
    void typingChanged() {
        if (p.typing()) sayRate(true);
        else if (rateSaid != 0) stillAfter(moved);
    }
}
