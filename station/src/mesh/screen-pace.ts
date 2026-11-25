// How fast a view's frames go ("Pace"): which may be sent now, and the bit rate its source is
// asked to encode at. Both from what the client's acknowledgements say of the link: how long a frame takes from sent to
// decoded (the round trip), and how much went through in the last second.
//
// Frames go while those on the way go through as fast as the link has gone lately: the oldest not acknowledged waiting
// no longer than the quickest round trip of the last RTT_WINDOW_MS and `queueMs` of it. A far link so carries as many
// frames a second as a near one. Once one waits longer a queue is building (a link slower than the frames, a packet lost
// and sent again): none goes until an acknowledgement, and once frames stay held back, the bit rate goes down to what
// went through (no lower than half of what it was at a time), so the frames that come next are as many and smaller
// rather than fewer and late. A screen that changes little holds nothing back, and an acknowledgement late alone (a
// large picture of a still screen) lowers nothing. It goes up again a step at a time while nothing
// is lowered, to the source's own. A view starts at START_RATE (its first frame, a whole picture, is its largest: on a
// narrow link one at the source's own rate held the view up for a second) and goes up by START_UP each step until it
// is first lowered; a link known to carry more as the view opens (`startRate`: a direct way of a short round trip, a
// near relay) starts higher, its first picture sharp at once.
import { wall } from "../ops/fibers.ts";

/// Frames sent and not acknowledged, at most: before the link's round trip is known, and however short it is.
export const START_UNACKED = 2;
export const MAX_UNACKED = 16;
/// Minimum concurrent frames allowed in flight once RTT is known (unless severe backlog builds), so normal LAN/metro
/// jitter of a single frame never starves the frame cadence.
export const MIN_INFLIGHT_FRAMES = 3;
/// Jitter-aware queuing budget (ms): at least QUEUE_MS, scaling with base RTT and measured jitter, capped at
/// QUEUE_BUDGET_MAX_MS.
export const QUEUE_MS = 45;
export const QUEUE_SHARE = 0.6;
export const QUEUE_JITTER_MULT = 2.5;
export const QUEUE_BUDGET_MAX_MS = 180;
export const SEVERE_QUEUE_MS = 120;
export const queueMs = (rtt: number, jitter = 0) =>
  Math.min(QUEUE_BUDGET_MAX_MS, Math.max(QUEUE_MS, rtt * QUEUE_SHARE + jitter * QUEUE_JITTER_MULT));
export const severeQueueMs = (budget: number) => Math.max(SEVERE_QUEUE_MS, budget * 2);
/// EWMA smoothing factors for network jitter and queuing delay.
const JITTER_ALPHA = 0.125;
const JITTER_SAMPLE_CAP_MS = 50;
const QUEUE_EWMA_ALPHA = 0.25;
const OVER_QUEUE_STREAK = 3;
/// How much longer a key frame on the way (sent and not acknowledged, or acknowledged now) may wait: a whole picture
/// (a game's scene cut, a key frame asked) is many times a moving one's, and its taking longer to go is its size, not
/// a queue in front of the link.
export const KEY_QUEUE_MS = 25;
/// How long a round trip counts towards the quickest (the link changes: another way, a relay).
export const RTT_WINDOW_MS = 10_000;
/// Most client-side jitter hold time (ms) credited to the viewer's in-flight budget before pacing pauses.
export const VIEWER_HOLD_LIMIT_MS = 100;
/// What went through is counted over this long.
export const DELIVERY_WINDOW_MS = 1000;
/// Steady-state bitrate control parameters:
/// - Confirm sustained queuing for HOLD_MS before cutting to filter single-frame Wi-Fi/routing spikes.
/// - Enforce CUT_COOLDOWN_MS between cuts to prevent cascading bitrate collapse.
/// - Use gentle multiplicative cuts (LIGHT_CUT / MILD_CUT) for mild congestion, deeper CUT only for severe congestion
///   or high loss (> 5%).
/// - Only anchor cuts to measured `through * DOWN` when the encoder is saturating the target rate (never during still
///   or throttled periods).
/// - Deduplicate keyframe/loss notifications over LOST_COOLDOWN_MS with a gentle LOST_CUT.
/// - Probe back up smoothly (UP every UP_EVERY_MS ≈ +10%/s) once calm and loss < 1%.
export const MIN_RATE = 300_000;
export const DOWN = 0.85;
export const CUT = 0.72;
export const MILD_CUT = 0.85;
export const LIGHT_CUT = 0.88;
export const LOST_CUT = 0.88;
export const HOLD_MS = 550;
export const CUT_COOLDOWN_MS = 850;
export const LOST_COOLDOWN_MS = 1000;
export const SATURATED_SEND_SHARE = 0.65;
export const SATURATED_MIN_FRAMES = 15;
export const UP = 1.05;
export const UP_FAST = 1.12;
export const UP_FAST_AFTER_MS = 4000;
export const UP_EVERY_MS = 500;
export const UP_AFTER_MS = 1500;
export const START_RATE = 1_500_000;
export const START_UP = 1.25;
/// Soft quality floors on healthy/low-loss links (< 2% loss, non-high RTT, non-saturated bottleneck).
export const FLOOR_1080P = 2_500_000;
export const FLOOR_1440P = 4_000_000;
export const HIGH_LOSS_PCT = 2.0;
export const SEVERE_LOSS_PCT = 5.0;
export const HIGH_RTT_MS = 150;
/// Where the view's link is known as it opens (its connection's selected way, else its first direct one, else its
/// first): a direct way within LAN_RTT_MS starts at LAN_RATE (a LAN, a near direct link), within NEAR_RTT_MS at
/// NEAR_RATE, within FAR_RTT_MS (or not measured yet) at DIRECT_RATE; a relay within RELAY_RTT_MS at RELAY_RATE; else
/// START_RATE. A link that carries less lowers it as before (the pace's `#queuing`), a few round trips on.
export const LAN_RTT_MS = 12;
export const LAN_RATE = 25_000_000;
export const NEAR_RTT_MS = 40;
export const NEAR_RATE = 12_000_000;
export const FAR_RTT_MS = 100;
export const DIRECT_RATE = 4_000_000;
export const RELAY_RTT_MS = 35;
export const RELAY_RATE = 4_000_000;
export type StartPath = { selected?: boolean; relay?: string | null; ip?: string | null; rttMs?: number | null };
const directPath = (p: StartPath) => !p.relay && typeof p.ip === "string" && p.ip !== "";
export function startRate(paths?: readonly StartPath[]): number {
  if (!paths || paths.length === 0) return START_RATE;
  const p = paths.find((w) => w.selected === true) ?? paths.find(directPath) ?? paths[0]!;
  const rtt = typeof p.rttMs === "number" && Number.isFinite(p.rttMs) && p.rttMs > 0 ? p.rttMs : null;
  if (directPath(p)) {
    if (rtt !== null && rtt <= LAN_RTT_MS) return LAN_RATE;
    if (rtt !== null && rtt <= NEAR_RTT_MS) return NEAR_RATE;
    return rtt === null || rtt <= FAR_RTT_MS ? DIRECT_RATE : START_RATE;
  }
  return rtt !== null && rtt <= RELAY_RTT_MS ? RELAY_RATE : START_RATE;
}
/// What went through is counted only once acknowledgements have come for this long.
export const MEASURED_MS = 500;

/// The bit rate a source encodes a picture of this size at when not asked (still.fail Helper's, stillfail-screen's).
export const ownRate = (width: number, height: number) => Math.max(1_000_000, width * height * 3);

/// The 画质 a view asks (the client's `quality`): none for 自动 or a client from before it. `qhd` (2K) is 原画's size
/// (never made smaller) at 4:2:0.
export type Quality = "smooth" | "hd" | "qhd" | "original";
export const QUALITIES: readonly Quality[] = ["smooth", "hd", "qhd", "original"];
/// The most a view is asked at, whatever its 画质 and 帧率.
export const MAX_RATE = 100_000_000;
/// The most a picture of this size is asked at: its pixels × 16 a second (at most MAX_RATE, at least its own: 1080p 33
/// Mbit/s), 2K and 原画 × 20 (1440p 73.7), 流畅 × 6 (12.4). 自动 is the best the link carries, as 原画 and 高清 are (they
/// choose the size alone): the link lowers it where it carries less. On a LAN a desktop's text at its own rate (× 3,
/// about 0.05 bit a pixel at 60 frames a second) stayed soft as it moved, and at 原画's × 8 too (2026-11-06); Moonlight
/// asks 20 Mbit/s for 1080p at 60. A 帧率 over 60 (`fps`) has as many bits a picture fewer to go by: up by a third of
/// what it adds over 60 per 60 (90: × 1.25, 120: × 1.5), at most FPS_SCALE_MOST.
export const FPS_SCALE_MOST = 1.6;
export const fpsScale = (fps?: number) => (fps !== undefined && fps > 60 ? Math.min(FPS_SCALE_MOST, 1 + (fps - 60) / 120) : 1);
export function rateCeiling(width: number, height: number, quality?: Quality, fps?: number): number {
  const own = ownRate(width, height);
  const per = quality === "smooth" ? 6 : quality === "qhd" || quality === "original" ? 20 : 16;
  return Math.max(own, Math.min(MAX_RATE, width * height * per * fpsScale(fps)));
}

/// The frame rates a view may ask (the client's `fps`, its 帧率): at most this many frames a second, fewer where the
/// link or the screen gives fewer. None asked (自动, or a client before it): as many as the source makes and the link
/// carries (still.fail Helper's 60 a second; stillfail-screen's as many as the display draws).
export const FPS_CHOICES = [120, 90, 60, 30, 15] as const;
export type Fps = (typeof FPS_CHOICES)[number];
export const isFps = (v: unknown): v is Fps => FPS_CHOICES.includes(v as Fps);

/// How long the station's own loop stood still (ms, in all, since it was first asked): a frame's round trip and the wait
/// of the oldest on the way are counted without it. A Mac host's loop stood still 40–140 ms every few seconds
/// (2026-10-29: busy with searches asked again and again) on a LAN of 4 ms and nothing lost: its frames' acknowledgements
/// were read that late, taken for frames held back by the link, and the rate went down to what the source made (a
/// screen changing little makes little), on to MIN_RATE and the picture to LOW_BOUNDS. A frame held at the client
/// (decoded slowly) or on the link (a queue, a packet lost) is held as before.
export const STALL_TICK_MS = 10;
export class LoopStall {
  #total = 0;
  #last = 0;
  #stop: (() => void) | null = null;
  #users = 0;
  readonly #now: () => number;
  constructor(now: () => number = () => hostNow()) {
    this.#now = now;
  }

  /// Counted while someone uses it (a view): the function says how long the loop stood still so far.
  use(): { stalled: () => number; done: () => void } {
    if (this.#users++ === 0) {
      this.#last = this.#now();
      this.#stop = wall.every(STALL_TICK_MS, () => this.#tick());
    }
    let done = false;
    return {
      stalled: () => this.stalled(),
      done: () => {
        if (done) return;
        done = true;
        if (--this.#users === 0 && this.#stop !== null) {
          this.#stop();
          this.#stop = null;
        }
      },
    };
  }

  /// How long it stood still so far, the stand it is in now (its tick not come yet) with it.
  stalled(): number {
    return this.#total + Math.max(0, this.#now() - this.#last - STALL_TICK_MS);
  }

  #tick() {
    const now = this.#now();
    this.#total += Math.max(0, now - this.#last - STALL_TICK_MS);
    this.#last = now;
  }
}
export const loopStall = new LoopStall();

export class Pacer {
  /// The frames sent and not acknowledged, oldest first: their timestamps, sizes, when they went and how long the
  /// loop had stood still by then.
  readonly #out: { ts: number; bytes: number; at: number; stall: number; key: boolean }[] = [];
  /// Round trips measured (net of viewer wait), oldest first.
  #trips: { at: number; ms: number }[] = [];
  /// Client-reported viewer wait times (ms) over RTT_WINDOW_MS, oldest first.
  #viewerWaits: { at: number; ms: number }[] = [];
  /// The frames acknowledged lately: when, and their sizes.
  #through: { at: number; bytes: number }[] = [];
  /// Frames sent lately: when, and their sizes (used to tell saturated encoding from still/low-motion screens).
  #sentWindow: { at: number; bytes: number }[] = [];
  /// Highest acknowledged frame timestamp, for idempotent duplicate/out-of-order ACK rejection.
  #lastAckedTs = -Infinity;
  /// EWMA network jitter (ms) and last measured net RTT.
  #jitter = 0;
  #lastNetTrip: number | null = null;
  /// EWMA smoothed queuing delay (ms) above baseline RTT, last update time, and consecutive over-budget ack streak.
  #smoothQueue = 0;
  #lastAckAt = -Infinity;
  #overQueueStreak = 0;
  /// Consecutive cuts during the current congestion episode.
  #cutStreak = 0;
  /// Last time `lost()` was received and last time `lost()` applied a rate cut.
  #lastLostAt = -Infinity;
  #lastLostCutAt = -Infinity;
  /// Latest link packet loss percentage reported by LinkLoss (0..100).
  #lossPct = 0;
  /// Active video frame dimensions for quality floor calculation.
  #size: { width: number; height: number } | null = null;
  /// The bit rate asked of the source, and the most it is asked (its own); null before its size is known.
  #rate: number | null = null;
  #ceiling: number | null = null;
  #down = -Infinity;
  #up = -Infinity;
  /// Since when sustained queuing has been observed, or null; and when last held/queued.
  #since: number | null = null;
  #held = -Infinity;
  #first = Infinity;
  /// The 帧率 asked: ms between frames (none: as many as come), and when the next may go. Each frame takes the next
  /// slot of 1000/fps ms; one late by up to half a slot lets the next come that much sooner, so a source that makes
  /// frames at the same rate (still.fail Helper's capture, asked it) is not cut to fewer by the jitter of its frames,
  /// and no second carries more than fps + 1.
  readonly #gap: number | null;
  #due = -Infinity;
  readonly #now: () => number;
  readonly #stalled: () => number;
  /// `start`: the bit rate the source was opened at (none: its own); `fps`: the 帧率 asked (none: 自动); `stalled`: how
  /// long the station's loop stood still so far (LoopStall), left out of round trips and waits.
  constructor(now: () => number, start: number | null = null, fps?: number, stalled: () => number = () => 0) {
    this.#now = now;
    this.#stalled = stalled;
    this.#rate = start;
    this.#gap = fps !== undefined && fps > 0 ? 1000 / fps : null;
  }

  /// How long until the next frame may go by the 帧率 asked, in whole ms (0: now; none asked, always 0): a clock read in
  /// nanoseconds a hair short of the slot waits a ms, not 0 ms again and again.
  wait(): number {
    const left = this.#gap === null ? 0 : this.#due - this.#now();
    return left > 0 ? Math.ceil(left) : 0;
  }

  get unacked(): number {
    return this.#out.length;
  }

  /// The source's own bit rate (its picture's size changed): what it is asked goes no higher.
  ceiling(rate: number) {
    this.#ceiling = rate;
    this.#rate = Math.min(this.#rate ?? rate, rate);
  }

  /// Current ceiling rate, or null before set.
  ceilingRate(): number | null {
    return this.#ceiling;
  }

  /// Inform Pacer of the current encoded picture size for soft quality-floor protection.
  setSize(width: number, height: number) {
    if (width > 0 && height > 0) this.#size = { width, height };
  }

  /// Inform Pacer of the latest link packet loss percentage (0..100).
  setLoss(pct: number) {
    if (Number.isFinite(pct) && pct >= 0) this.#lossPct = pct;
  }

  /// Measured network jitter EWMA (ms).
  jitter(): number {
    return this.#jitter;
  }

  /// Smoothed queuing delay EWMA (ms).
  smoothQueue(): number {
    return this.#smoothQueue;
  }

  /// Current jitter-aware queuing budget (ms).
  queueBudget(): number {
    const rtt = this.rtt();
    return rtt === null ? QUEUE_MS : queueMs(rtt, this.#jitter);
  }

  /// Whether the link is healthy enough for gentle sharpening (no queuing, loss < 0.5%, not backlogged).
  healthy(): boolean {
    if (this.#since !== null || this.#lossPct >= 0.5 || this.backlogged()) return false;
    const budget = this.queueBudget();
    return this.#smoothQueue <= budget * 0.5;
  }

  /// A frame went (`key`: a key frame, a whole picture).
  sent(ts: number, bytes: number, key = false) {
    const now = this.#now();
    this.#out.push({ ts, bytes, at: now, stall: this.#stalled(), key });
    this.#sentWindow.push({ at: now, bytes });
    while (this.#sentWindow.length > 0 && this.#sentWindow[0]!.at < now - DELIVERY_WINDOW_MS) this.#sentWindow.shift();
    if (this.#gap !== null) this.#due = Math.max(this.#due + this.#gap, now + this.#gap / 2);
  }

  /// The viewer cannot use the frames on the way and asked for a new key frame. Do not count them as delivered, or
  /// let their missing acknowledgements hold the replacement behind them. Deduplicated over LOST_COOLDOWN_MS so a
  /// keyframe storm cannot collapse bitrate.
  lost() {
    const now = this.#now();
    this.#out.length = 0;
    this.#lastLostAt = now;
    if (
      this.#rate !== null &&
      this.#trips.length > 0 &&
      now - this.#lastLostCutAt >= LOST_COOLDOWN_MS &&
      now - this.#down >= CUT_COOLDOWN_MS
    ) {
      this.#lastLostCutAt = now;
      this.#down = now;
      this.#held = now;
      const floor = this.#floorRate(now, false);
      this.#rate = Math.max(floor, Math.min(this.#rate, this.#rate * LOST_CUT));
    }
  }

  /// The client decoded every frame up to `ts`; the newest of them gives a round trip.
  /// `viewerWaitMs`: how long (ms) the client held the frame (e.g. jitter buffer) before showing or dropping it.
  /// Idempotent for duplicate or out-of-order late ACKs.
  acked(ts: number, viewerWaitMs = 0) {
    if (ts <= this.#lastAckedTs) return;
    const now = this.#now();
    let newest: { at: number; stall: number } | null = null;
    let key = false;
    while (this.#out.length > 0 && this.#out[0]!.ts <= ts) {
      const f = this.#out.shift()!;
      this.#through.push({ at: now, bytes: f.bytes });
      newest = f;
      key ||= f.key;
    }
    if (newest === null) return;
    this.#lastAckedTs = ts;
    this.#first = Math.min(this.#first, now);
    while (this.#through.length > 0 && this.#through[0]!.at < now - DELIVERY_WINDOW_MS) this.#through.shift();
    const totalTrip = Math.max(0, now - newest.at - (this.#stalled() - newest.stall));
    const wait = Number.isFinite(viewerWaitMs) && viewerWaitMs > 0 && viewerWaitMs <= totalTrip ? viewerWaitMs : 0;
    this.#viewerWaits.push({ at: now, ms: wait });
    while (this.#viewerWaits.length > 1 && this.#viewerWaits[0]!.at < now - RTT_WINDOW_MS) this.#viewerWaits.shift();
    const netTrip = Math.max(0, totalTrip - wait);
    const base = this.rtt();
    if (this.#lastNetTrip !== null) {
      const delta = Math.abs(netTrip - this.#lastNetTrip);
      this.#jitter += JITTER_ALPHA * (Math.min(delta, JITTER_SAMPLE_CAP_MS) - this.#jitter);
    }
    this.#lastNetTrip = netTrip;
    this.#trips.push({ at: now, ms: netTrip });
    // The latest is kept however old: a still screen sends nothing for long.
    while (this.#trips.length > 1 && this.#trips[0]!.at < now - RTT_WINDOW_MS) this.#trips.shift();
    if (base !== null) {
      const budget = queueMs(base, this.#jitter);
      const effQueue = Math.max(0, netTrip - base - (key ? KEY_QUEUE_MS : 0));
      // Time-decay stale queuing EWMA across idle/low-fps gaps so healthy frames after calm periods are never penalized.
      const dt = this.#lastAckAt === -Infinity ? 0 : Math.max(0, now - this.#lastAckAt);
      const timeDecay = dt > 100 ? Math.exp(-dt / 500) : 1;
      const decayed = this.#smoothQueue * timeDecay;
      this.#smoothQueue = decayed * (1 - QUEUE_EWMA_ALPHA) + effQueue * QUEUE_EWMA_ALPHA;
      if (effQueue > budget) this.#overQueueStreak++;
      else this.#overQueueStreak = 0;
      const severe = effQueue > severeQueueMs(budget);
      // Only treat as active queuing when the current ack itself shows queuing (never penalize a clean 0-queue ack).
      const sustainedQueue =
        severe ||
        (effQueue > budget * 0.5 && (this.#smoothQueue > budget || (effQueue > budget && this.#overQueueStreak >= OVER_QUEUE_STREAK)));
      if (sustainedQueue) {
        this.#since ??= now;
        this.#held = now;
        this.#queuing(now, severe);
      } else if (this.#smoothQueue <= budget * 0.7 || effQueue <= budget * 0.5) {
        this.#steady(now);
      }
    } else {
      this.#steady(now);
    }
    this.#lastAckAt = now;
  }

  /// Recent viewer hold time (ms) credited to the in-flight window, capped at VIEWER_HOLD_LIMIT_MS.
  viewerWait(): number {
    if (this.#viewerWaits.length === 0) return 0;
    let max = 0;
    for (const w of this.#viewerWaits) if (w.ms > max) max = w.ms;
    return Math.min(VIEWER_HOLD_LIMIT_MS, max);
  }

  /// The quickest round trip lately, or null before one.
  rtt(): number | null {
    if (this.#trips.length === 0) return null;
    let min = this.#trips[0]!.ms;
    for (let i = 1; i < this.#trips.length; i++) {
      const ms = this.#trips[i]!.ms;
      if (ms < min) min = ms;
    }
    return min;
  }

  /// Whether the next frame may go now; when not, a queue is building.
  may(): boolean {
    const may = this.free();
    if (!may && this.rtt() !== null) {
      const now = this.#now();
      this.#since ??= now;
      this.#held = now;
      const rtt = this.rtt()!;
      const budget = queueMs(rtt, this.#jitter);
      const netWaited = this.#netWaited(now, rtt);
      this.#queuing(now, netWaited > severeQueueMs(budget));
    }
    return may;
  }

  /// Whether the next frame may go now, as `may` says, asking nothing of the pace (a frame asked of the source ahead of
  /// its going: screens.ts `#pump`).
  free(): boolean {
    if (this.#out.length === 0) return true;
    const rtt = this.rtt();
    if (rtt === null) return this.#out.length < START_UNACKED;
    if (this.#out.length >= MAX_UNACKED) return false;
    const now = this.#now();
    const budget = queueMs(rtt, this.#jitter);
    const netWaited = this.#netWaited(now, rtt);
    if (netWaited > severeQueueMs(budget)) return false;
    if (this.#out.length < MIN_INFLIGHT_FRAMES) return true;
    if (netWaited <= budget) return true;
    // Between budget and severe threshold: allow in-flight bytes up to BDP + jitter headroom unless smoothed queue is already over budget.
    if (this.#smoothQueue > budget) return false;
    const rate = this.#rate ?? START_RATE;
    const bdpBytes = (rate / 8) * ((rtt + budget) / 1000);
    const limitBytes = Math.max(bdpBytes * 1.5, (rate / 8) * 0.12, 64_000);
    let inflightBytes = 0;
    for (const f of this.#out) inflightBytes += f.bytes;
    return inflightBytes <= limitBytes;
  }

  /// How long the oldest unacked frame has waited past RTT, viewer hold, and keyframe allowance.
  #netWaited(now: number, rtt: number): number {
    const keyBonus = this.#out.some((f) => f.key) ? KEY_QUEUE_MS : 0;
    return this.#waited(now) - rtt - this.viewerWait() - keyBonus;
  }

  /// Whether the frames on the way wait in front of the link: the oldest not acknowledged waited longer than the round
  /// trip and the jitter-aware queue budget. Asks nothing of the pace, as `may` does: what else goes on the view's
  /// stream (its sound) is left out while it holds, so that the pictures go first.
  backlogged(): boolean {
    if (this.#out.length <= 1) return false;
    const rtt = this.rtt();
    if (rtt === null) return false;
    const budget = queueMs(rtt, this.#jitter);
    return this.#netWaited(this.#now(), rtt) > budget;
  }

  /// How long the oldest frame not acknowledged has waited, the station's own loop standing still left out.
  #waited(now: number): number {
    const oldest = this.#out[0]!;
    return now - oldest.at - (this.#stalled() - oldest.stall);
  }

  /// The bit rate to ask of the source, or null while its own is not known.
  rate(): number | null {
    return this.#rate;
  }

  /// What went through in the last second, in bits a second.
  through(): number {
    return this.#delivered(this.#now());
  }

  /// What went through in the last second, in bits a second.
  #delivered(now: number): number {
    while (this.#through.length > 0 && this.#through[0]!.at < now - DELIVERY_WINDOW_MS) this.#through.shift();
    if (this.#through.length === 0) return 0;
    // Over the window, or since the first acknowledgement when it came within it.
    const span = Math.max(100, Math.min(DELIVERY_WINDOW_MS, now - this.#first));
    return (this.#through.reduce((sum, f) => sum + f.bytes, 0) * 8 * 1000) / span;
  }

  /// Encoder output rate over the last second, in bits a second.
  #sentRate(now: number): number {
    while (this.#sentWindow.length > 0 && this.#sentWindow[0]!.at < now - DELIVERY_WINDOW_MS) this.#sentWindow.shift();
    if (this.#sentWindow.length === 0) return 0;
    const span = Math.max(100, Math.min(DELIVERY_WINDOW_MS, now - this.#sentWindow[0]!.at));
    return (this.#sentWindow.reduce((sum, f) => sum + f.bytes, 0) * 8 * 1000) / span;
  }

  /// Whether measured `through` reflects actual link saturation rather than a still/low-motion or freshly throttled screen.
  #isSaturated(now: number): boolean {
    if (this.#rate === null) return false;
    if (now - this.#lastLostAt < DELIVERY_WINDOW_MS) return false;
    if (this.#through.length < SATURATED_MIN_FRAMES) return false;
    return this.#sentRate(now) >= this.#rate * SATURATED_SEND_SHARE;
  }

  /// Soft quality floor: protects 1080p/1440p from collapsing into mosaic on low-loss metro links while still allowing
  /// real constrained/lossy links to probe down to MIN_RATE.
  #floorRate(now: number, sustainedBottleneck: boolean): number {
    if (this.#size === null) return MIN_RATE;
    const pixels = this.#size.width * this.#size.height;
    let soft = MIN_RATE;
    if (pixels >= 2560 * 1440 * 0.9) soft = FLOOR_1440P;
    else if (pixels >= 1920 * 1080 * 0.9) soft = FLOOR_1080P;
    if (soft <= MIN_RATE) return MIN_RATE;
    const rtt = this.rtt() ?? 0;
    const budget = queueMs(rtt, this.#jitter);
    const realWeakLink =
      this.#lossPct >= HIGH_LOSS_PCT ||
      rtt > HIGH_RTT_MS ||
      this.#smoothQueue > Math.max(SEVERE_QUEUE_MS, budget * 1.5) ||
      sustainedBottleneck;
    return realWeakLink ? MIN_RATE : Math.min(soft, this.#ceiling ?? soft);
  }

  #queuing(now: number, severe = false) {
    if (this.#since === null || this.#calm(now)) return;
    const rtt = this.rtt() ?? 0;
    if (this.#rate === null || now - this.#since < Math.max(HOLD_MS, 2 * rtt) || now - this.#down < Math.max(CUT_COOLDOWN_MS, rtt + HOLD_MS)) return;
    // What went through is not known yet (the first frame, a whole picture, is most of it): nothing to go by.
    if (now - this.#first < MEASURED_MS) return;
    this.#down = now;
    this.#cutStreak++;
    const through = this.#delivered(now);
    const saturated = this.#isSaturated(now);
    const persistent = now - this.#since >= HOLD_MS * 2 && this.#cutStreak >= 2;
    const heavy = severe || this.#lossPct > SEVERE_LOSS_PCT || this.#cutStreak >= 3;
    const cutFactor = heavy ? CUT : this.#cutStreak === 1 ? LIGHT_CUT : MILD_CUT;
    let to: number;
    if (!saturated || through <= 0) {
      // Never anchor bitrate to low `through` measured during still/low-motion or freshly throttled periods.
      // Only allow deeper step-down if genuine persistent queuing continues across multiple cooldowns with active traffic.
      to = persistent && this.#sentWindow.length >= SATURATED_MIN_FRAMES ? this.#rate * cutFactor : this.#rate * LIGHT_CUT;
    } else {
      to = Math.min(this.#rate * LIGHT_CUT, Math.max(this.#rate * cutFactor, through * DOWN));
    }
    const sustainedBottleneck = persistent && this.#sentWindow.length >= SATURATED_MIN_FRAMES;
    const floor = this.#floorRate(now, sustainedBottleneck);
    this.#rate = Math.max(floor, Math.min(this.#rate, to));
  }

  /// Nothing held back for UP_AFTER_MS and two round trips: the queue gone.
  #calm(now: number): boolean {
    if (now - this.#held <= Math.max(UP_AFTER_MS, 2 * (this.rtt() ?? 0))) return false;
    this.#since = null;
    this.#cutStreak = 0;
    this.#smoothQueue = 0;
    this.#overQueueStreak = 0;
    return true;
  }

  #steady(now: number) {
    // Frames held back lately: as it is (the link carries no more than it goes at).
    if (this.#since !== null && !this.#calm(now)) return;
    if (this.#lossPct >= 1.0) return;
    if (this.#rate === null || this.#ceiling === null || this.#rate >= this.#ceiling) return;
    // Starting: never lowered yet. Up once it has not been lowered for UP_AFTER_MS.
    const starting = this.#down === -Infinity;
    if ((!starting && now - this.#down < UP_AFTER_MS) || now - this.#up < UP_EVERY_MS) return;
    this.#up = now;
    const step = starting ? START_UP : now - Math.max(this.#held, this.#down) >= UP_FAST_AFTER_MS ? UP_FAST : UP;
    this.#rate = Math.min(this.#ceiling, this.#rate * step);
  }
}

/// Gentle sharpening: instead of blasting a 2×-bitrate keyframe 250ms after every pause, only request a keyframe
/// when the link is completely healthy, the previous picture was encoded at a genuinely compressed rate (< 60% of
/// the recovered rate), and at least SHARPEN_COOLDOWN_MS (5000ms) has elapsed since the last sharpen.
export const STILL_MS = 1000;
export const SHARPEN_COOLDOWN_MS = 5000;
export const SHARPEN_LOW_RATIO = 0.6;
export const SHARPEN_BOOST_CAP = 1.2;
export const SHARPER = 1 / SHARPEN_LOW_RATIO;
export const MOVING_SHARPEN_MS = 5000;
export const MOVING_SHARPEN_UP = 1 / SHARPEN_LOW_RATIO;

/// When a still screen's picture or moving stream is gently sharpened after recovering from genuine rate compression.
export class Sharpener {
  #at = -Infinity;
  #rate: number | null = null;
  /// The last key frame (or the first frame with a rate, standing for it): when, and at what rate.
  #keyAt = -Infinity;
  #keyRate: number | null = null;
  /// Last time a sharpen keyframe was requested (enforces SHARPEN_COOLDOWN_MS).
  #lastSharpenAt = -Infinity;

  /// A frame went at `now`, encoded at `rate` (null: a source with no rate of its own, a JPEG's); `key`: a key frame.
  sent(now: number, rate: number | null, key = false) {
    this.#at = now;
    this.#rate = rate;
    if (rate === null) {
      this.#keyAt = -Infinity;
      this.#keyRate = null;
    } else if (key || this.#keyRate === null) {
      this.#keyAt = now;
      this.#keyRate = rate;
    }
  }

  /// How long until the screen has been still for STILL_MS and past SHARPEN_COOLDOWN_MS (0: ready).
  left(now: number): number {
    return Math.max(0, Math.max(this.#at + STILL_MS, this.#lastSharpenAt + SHARPEN_COOLDOWN_MS) - now);
  }

  /// Whether a gentle still-screen refresh keyframe is due now: only when healthy, still for STILL_MS, cooled down
  /// for SHARPEN_COOLDOWN_MS, and the last frame was encoded below SHARPEN_LOW_RATIO (< 60%) of the recovered rate.
  due(now: number, rate: number | null, healthy = true): boolean {
    if (!healthy || rate === null || this.#rate === null) return false;
    if (this.left(now) > 0) return false;
    if (this.#rate >= rate * SHARPEN_LOW_RATIO) return false;
    this.#lastSharpenAt = now;
    return true;
  }

  /// Whether a moving screen's key frame is to be gently refreshed now: only when healthy, past MOVING_SHARPEN_MS
  /// and SHARPEN_COOLDOWN_MS, and the last keyframe was encoded below SHARPEN_LOW_RATIO (< 60%) of the recovered rate.
  dueMoving(now: number, rate: number | null, healthy = true): boolean {
    if (!healthy || rate === null || this.#keyRate === null) return false;
    if (now - this.#keyAt < MOVING_SHARPEN_MS || now - this.#lastSharpenAt < SHARPEN_COOLDOWN_MS) return false;
    if (this.#keyRate >= rate * SHARPEN_LOW_RATIO) return false;
    this.#keyAt = now;
    this.#keyRate = rate;
    this.#lastSharpenAt = now;
    return true;
  }

  /// Optional gentle rate cap (at most SHARPEN_BOOST_CAP × steady rate, never exceeding ceiling) for a sharpen refresh.
  static gentleRate(rate: number, ceiling: number | null = null): number {
    const boosted = Math.round(rate * SHARPEN_BOOST_CAP);
    return ceiling !== null ? Math.min(ceiling, boosted) : boosted;
  }
}

/// A picture fitted into 1280×720 while the link carries little.
export const LOW_BOUNDS = { maxWidth: 1280, maxHeight: 720 };
/// Minimum usable bitrate thresholds for resolution downsize based on actual pixel count:
/// 1440p/4K only downsizes when sustained below 3.0 Mbps; 1080p only when sustained below 1.5 Mbps.
export const DOWNSIZE_RATE_1440P = 3_000_000;
export const DOWNSIZE_RATE_1080P = 1_500_000;
export const DOWNSIZE_RATE_MIN = 1_000_000;
export function downsizeThreshold(width: number, height: number): number {
  const pixels = width * height;
  if (pixels >= 2560 * 1440 * 0.9) return DOWNSIZE_RATE_1440P;
  if (pixels >= 1920 * 1080 * 0.9) return DOWNSIZE_RATE_1080P;
  return Math.max(DOWNSIZE_RATE_MIN, Math.round((pixels / (1920 * 1080)) * DOWNSIZE_RATE_1080P));
}
export const USED = 0.6;
export const DOWNSIZE_MS = 8000;
/// Wide hysteresis and minimum dwell time before upsizing back to full resolution, preventing 1440p ↔ 720p oscillation.
export const UPSIZE_MS = 15_000;
export const UPSIZE_HYSTERESIS = 1.8;

/// How large a picture a view asks of its source by the rate the pace asks: as the view asked it, or LOW_BOUNDS while
/// the link sustains below the resolution's real minimum usable bitrate for DOWNSIZE_MS (8 s) under active encoding.
/// Upsizes back only after dwelling at least UPSIZE_MS (15 s) with bitrate >= 1.8× the downsize threshold.
/// Never smaller when the view asked 原画 or 2K.
export class Sizer {
  readonly #now: () => number;
  #asked: { maxWidth: number; maxHeight: number };
  #low = false;
  #since: number | null = null;
  #changedAt = -Infinity;
  #downThreshold = DOWNSIZE_RATE_1080P;
  /// 原画 or 2K asked: the picture is never made smaller (a link that carries less gets fewer frames of it).
  readonly #whole: boolean;
  readonly #quality: Quality | undefined;
  constructor(now: () => number, asked: { maxWidth: number; maxHeight: number }, quality?: Quality) {
    this.#now = now;
    this.#asked = asked;
    this.#quality = quality;
    this.#whole = quality === "original" || quality === "qhd";
  }

  get low(): boolean {
    return this.#low;
  }

  /// The bounds the view asks for now.
  get asked(): { maxWidth: number; maxHeight: number } {
    return { ...this.#asked };
  }

  /// The view asks for other bounds (a part of the screen, shown as large as the client has room for: a look): the
  /// bounds to ask of the source now, the smaller one's within them while the link carries little.
  ask(asked: { maxWidth: number; maxHeight: number }): { maxWidth: number; maxHeight: number } {
    this.#asked = { ...asked };
    this.#since = null;
    return this.bounds();
  }

  /// With the rate asked now, what went through, and the picture's size now: the bounds to ask for, when they change;
  /// else null.
  step(rate: number, through: number, size: { width: number; height: number }): { maxWidth: number; maxHeight: number } | null {
    // Asked no larger than the small one, or 原画: nothing to make smaller.
    if (this.#whole || (this.#asked.maxWidth <= LOW_BOUNDS.maxWidth && this.#asked.maxHeight <= LOW_BOUNDS.maxHeight)) return null;
    const now = this.#now();
    const threshold = downsizeThreshold(size.width, size.height);
    const upsizeTarget = Math.min(this.#downThreshold * UPSIZE_HYSTERESIS, rateCeiling(size.width, size.height, this.#quality) * 0.95);
    const holds = this.#low
      ? rate >= upsizeTarget
      : rate <= threshold && through >= rate * USED;
    if (!holds) {
      this.#since = null;
      return null;
    }
    this.#since ??= now;
    const needed = this.#low ? UPSIZE_MS : DOWNSIZE_MS;
    if (now - this.#since < needed) return null;
    if (this.#low && now - this.#changedAt < UPSIZE_MS) return null;
    if (!this.#low) this.#downThreshold = threshold;
    this.#since = null;
    this.#changedAt = now;
    this.#low = !this.#low;
    return this.bounds();
  }

  /// The bounds to ask of the source as things are: the view's, or the smaller one's within them.
  bounds(): { maxWidth: number; maxHeight: number } {
    const a = this.#asked;
    return this.#low ? { maxWidth: Math.min(a.maxWidth, LOW_BOUNDS.maxWidth), maxHeight: Math.min(a.maxHeight, LOW_BOUNDS.maxHeight) } : { ...a };
  }
}

/// How late a view's frames are, said every LATENCY_EVERY_MS while frames go: from a picture's capture to its drawing on
/// the device (`frame`; the acknowledgement's arrival less half the link's quickest round trip, the way back), and from
/// its capture to its going out (`before`: waiting to be asked for, encoded; an encoder that holds a picture back until
/// the next comes shows here). Medians of the last LATENCY_WINDOW_MS. A frame's timestamp is its capture time on the
/// host's own clock (still.fail Helper's mach time, stillfail-screen's QPC: what `now` reads here); one off it by more
/// than 10 s (a source with a clock of its own) is not counted.
export const LATENCY_EVERY_MS = 1000;
export const LATENCY_WINDOW_MS = 2000;

/// The host's clock in ms, as the helpers stamp frames (process.hrtime: mach_absolute_time, QueryPerformanceCounter).
export const hostNow = () => Number(process.hrtime.bigint()) / 1e6;

export class FrameLatency {
  readonly #now: () => number;
  readonly #out = new Map<number, { capture: number; sent: number }>();
  #samples: { at: number; frame: number; before: number }[] = [];
  #said = -Infinity;
  constructor(now: () => number = hostNow) {
    this.#now = now;
  }

  /// A frame of capture time `ts` (µs) went out now.
  sent(ts: number) {
    const now = this.#now();
    const capture = ts / 1000;
    if (now - capture < 0 || now - capture > 10_000) return;
    this.#out.set(ts, { capture, sent: now });
  }

  /// Frames the viewer gave up will not contribute latency samples.
  lost() {
    this.#out.clear();
  }

  /// The client drew every frame up to `ts`; `rtt`: the link's quickest round trip (ms), the way back its half.
  acked(ts: number, rtt: number) {
    const now = this.#now();
    let newest: { capture: number; sent: number } | null = null;
    for (const [t, f] of this.#out) {
      if (t > ts) continue;
      if (t === ts) newest = f;
      this.#out.delete(t);
    }
    if (newest === null) return;
    this.#samples.push({ at: now, frame: Math.max(0, now - rtt / 2 - newest.capture), before: newest.sent - newest.capture });
    while (this.#samples.length > 0 && this.#samples[0]!.at < now - LATENCY_WINDOW_MS) this.#samples.shift();
  }

  /// What to say now (once each LATENCY_EVERY_MS, when there are frames to say it of): the medians, in whole ms.
  take(): { frame: number; before: number } | null {
    const now = this.#now();
    // A still screen sends nothing: what is older than the window is not said again.
    while (this.#samples.length > 0 && this.#samples[0]!.at < now - LATENCY_WINDOW_MS) this.#samples.shift();
    if (this.#samples.length === 0 || now - this.#said < LATENCY_EVERY_MS) return null;
    this.#said = now;
    const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;
    return { frame: Math.round(median(this.#samples.map((s) => s.frame))), before: Math.round(median(this.#samples.map((s) => s.before))) };
  }
}

/// How much of what went over a view's link was lost, as its station counts it (the statistics' 丢包率): the view's
/// pictures are nearly all of what goes, from the station to the client, and a QUIC endpoint counts only what it sent
/// and lost itself (iroh's `udp_tx.datagrams` and `lost_packets` of its paths), so it is the station's to count and the
/// client's to be told. Sampled every LOSS_EVERY_MS from the connection's selected path, over the last LOSS_WINDOW_MS;
/// a path changed (another relay, a direct way) or counters gone back start again from it. Fewer than LOSS_MIN_PACKETS
/// in the window with fewer than LOSS_MIN_LOST lost (a still screen's few packets) says 0, never a share of a handful.
export const LOSS_EVERY_MS = 1000;
export const LOSS_WINDOW_MS = 60_000;
export const LOSS_MIN_PACKETS = 20;
export const LOSS_MIN_LOST = 3;
export type LinkPath = { id?: string; selected: boolean; relay?: string | null; ip?: string | null; rttMs?: number | null; txPackets: number; lostPackets: number };

export class LinkLoss {
  readonly #now: () => number;
  /// The selected path's counters as last sampled, and which path it was.
  #last: { key: string; sent: number; lost: number } | null = null;
  /// What each sample added, oldest first.
  #samples: { at: number; sent: number; lost: number }[] = [];
  /// The share last said, in percent.
  #said: number | null = null;
  constructor(now: () => number) {
    this.#now = now;
  }

  /// The connection's paths now: the share to say now (in percent, to a tenth), when it changed since it was last said;
  /// else null (nothing new, or nothing went in the window).
  step(paths: readonly LinkPath[]): number | null {
    const pct = this.sample(paths);
    if (pct === null || pct === this.#said) return null;
    this.#said = pct;
    return pct;
  }

  /// The share over the window as of now (null: nothing went in it), the counters taken in.
  sample(paths: readonly LinkPath[]): number | null {
    const now = this.#now();
    const way = paths.find((p) => p.selected);
    if (way === undefined) {
      this.#last = null;
    } else {
      const key = way.id ?? way.relay ?? way.ip ?? "";
      const last = this.#last;
      if (last !== null && last.key === key && way.txPackets >= last.sent && way.lostPackets >= last.lost) {
        this.#samples.push({ at: now, sent: way.txPackets - last.sent, lost: way.lostPackets - last.lost });
      }
      this.#last = { key, sent: way.txPackets, lost: way.lostPackets };
    }
    while (this.#samples.length > 0 && this.#samples[0]!.at < now - LOSS_WINDOW_MS) this.#samples.shift();
    let sent = 0;
    let lost = 0;
    for (const s of this.#samples) {
      sent += s.sent;
      lost += s.lost;
    }
    if (sent === 0) return null;
    if (sent < LOSS_MIN_PACKETS && lost < LOSS_MIN_LOST) return 0;
    return Math.min(100, Math.round((lost / sent) * 1000) / 10);
  }
}
