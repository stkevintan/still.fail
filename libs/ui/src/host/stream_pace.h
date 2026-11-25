// Adaptive jitter-absorbing presentation clock and four-state catch-up pacer for remote screen streams.
// Header-only pure C99, zero external dependencies, shared by macOS/iOS, Windows, and Linux hosts.
#ifndef MB_STREAM_PACE_H
#define MB_STREAM_PACE_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// Sliding window durations and tuning parameters (aligned with libs/ui/web/host.js).
#define MB_PACE_CLOCK_WINDOW_MS 5000.0
#define MB_PACE_JITTER_WINDOW_MS 2000.0
#define MB_PACE_JITTER_QUANTILE 0.95
#define MB_PACE_MAX_HOLD_MS 60.0
#define MB_PACE_HOLD_DECAY 0.04
#define MB_PACE_CLOCK_JUMP_MS 500.0
#define MB_PACE_SILENCE_MS 200.0

// Four-state catch-up thresholds.
#define MB_PACE_IDLE_DUE 2
#define MB_PACE_OVERRUN_DUE 10
#define MB_PACE_OVERRUN_STAY_MS 180.0
#define MB_PACE_BACKLOG_GRACE_MS 500.0
#define MB_PACE_CATCH_UP_INTERVAL_MS 250.0

// Ring buffer capacity (power of 2; holds >8s at 120fps).
#define MB_PACE_MAX_SAMPLES 1024u
#define MB_PACE_SAMPLE_MASK (MB_PACE_MAX_SAMPLES - 1u)

// Recommended hard cap for decoded-frame presentation queues on native hosts.
#define MB_PACE_QUEUE_CAP 12

// Consecutive empty VSync ticks (~250 ms at 60 Hz) before stopping the display-synced pacer,
// avoiding 60 Hz start/stop thrashing on low-jitter LAN streams where frames present immediately.
#define MB_PACE_IDLE_STOP_TICKS 15

typedef enum {
  MB_PACE_IDLE = 0,
  MB_PACE_BACKLOG = 1,
  MB_PACE_CATCH_UP = 2,
  MB_PACE_OVERRUN = 3
} mb_pace_phase_t;

typedef struct {
  double time_ms;
  double offset_ms;
  double late_ms;
  uint64_t seq;
} mb_pace_sample_t;

typedef struct {
  double base_ms;
  double arrived_ms;
  uint8_t immediate;
} mb_pace_arrival_t;

typedef struct {
  mb_pace_sample_t samples[MB_PACE_MAX_SAMPLES];
  uint32_t sample_head;
  uint32_t sample_count;
  uint64_t next_seq;

  // Monotonic increasing deque of sample ring indices for O(1) sliding minimum offset.
  uint32_t lows[MB_PACE_MAX_SAMPLES];
  uint32_t low_head;
  uint32_t low_count;

  double hold_ms;
  double last_arrival_ms;
  uint8_t has_last_arrival;

  double backlog_since_ms;
  uint8_t has_backlog;

  double last_catch_up_ms;
  uint8_t has_catch_up;
} mb_pace_t;

static inline void mb_pace_init(mb_pace_t *p) {
  if (!p) return;
  memset(p, 0, sizeof(*p));
}

static inline void mb_pace_reset(mb_pace_t *p) {
  mb_pace_init(p);
}

static inline void mb_pace_sort_doubles(double *a, size_t n) {
  // Shell sort with Ciura gap sequence: zero recursion, zero heap allocation, fast for n <= 1024.
  static const size_t gaps[] = {701, 301, 132, 57, 23, 10, 4, 1};
  for (size_t g = 0; g < sizeof(gaps) / sizeof(gaps[0]); g++) {
    size_t gap = gaps[g];
    if (gap >= n) continue;
    for (size_t i = gap; i < n; i++) {
      double v = a[i];
      size_t j = i;
      while (j >= gap && a[j - gap] > v) {
        a[j] = a[j - gap];
        j -= gap;
      }
      a[j] = v;
    }
  }
}

// Observe a frame arrival (sender timestamp `ts_us` in microseconds, local monotonic clock `arrived_ms` in ms).
// Updates the sliding baseline clock and P95 jitter hold estimate, and returns arrival metadata for pacing.
static inline mb_pace_arrival_t mb_pace_observe(mb_pace_t *p, double ts_us, double arrived_ms) {
  mb_pace_arrival_t out;
  out.arrived_ms = arrived_ms;
  out.base_ms = arrived_ms - ts_us / 1000.0;
  out.immediate = 1u;
  if (!p || !(ts_us == ts_us) || !(arrived_ms == arrived_ms)) return out;

  double offset = arrived_ms - ts_us / 1000.0;
  uint8_t immediate = 0u;

  // First frame of the stream, or first frame after >= 200 ms of silence: present immediately with zero jitter wait.
  if (!p->has_last_arrival || (arrived_ms - p->last_arrival_ms >= MB_PACE_SILENCE_MS)) {
    immediate = 1u;
  }

  // Detect large clock jumps, pause/resume, or backwards clock jumps and reset the baseline estimator.
  if (p->sample_count > 0u) {
    uint32_t last_idx = (p->sample_head + p->sample_count - 1u) & MB_PACE_SAMPLE_MASK;
    double prev_offset = p->samples[last_idx].offset_ms;
    if (fabs(offset - prev_offset) > MB_PACE_CLOCK_JUMP_MS || arrived_ms < p->last_arrival_ms - 50.0) {
      p->sample_head = 0u;
      p->sample_count = 0u;
      p->low_head = 0u;
      p->low_count = 0u;
      p->hold_ms = 0.0;
      p->has_backlog = 0u;
      immediate = 1u;
    }
  }

  double prev_time = arrived_ms;
  if (p->sample_count > 0u) {
    uint32_t last_idx = (p->sample_head + p->sample_count - 1u) & MB_PACE_SAMPLE_MASK;
    prev_time = p->samples[last_idx].time_ms;
  }

  // If the ring buffer is full, evict the oldest sample first.
  if (p->sample_count == MB_PACE_MAX_SAMPLES) {
    uint64_t evicted_seq = p->samples[p->sample_head].seq;
    p->sample_head = (p->sample_head + 1u) & MB_PACE_SAMPLE_MASK;
    p->sample_count--;
    if (p->low_count > 0u && p->samples[p->lows[p->low_head]].seq == evicted_seq) {
      p->low_head = (p->low_head + 1u) & MB_PACE_SAMPLE_MASK;
      p->low_count--;
    }
  }

  // Append the new sample.
  uint32_t ins_idx = (p->sample_head + p->sample_count) & MB_PACE_SAMPLE_MASK;
  uint64_t seq = ++p->next_seq;
  p->samples[ins_idx].time_ms = arrived_ms;
  p->samples[ins_idx].offset_ms = offset;
  p->samples[ins_idx].late_ms = 0.0;
  p->samples[ins_idx].seq = seq;
  p->sample_count++;

  // Maintain monotonic increasing deque of offsets.
  while (p->low_count > 0u) {
    uint32_t back_pos = (p->low_head + p->low_count - 1u) & MB_PACE_SAMPLE_MASK;
    uint32_t back_idx = p->lows[back_pos];
    if (p->samples[back_idx].offset_ms >= offset) {
      p->low_count--;
    } else {
      break;
    }
  }
  uint32_t low_ins = (p->low_head + p->low_count) & MB_PACE_SAMPLE_MASK;
  p->lows[low_ins] = ins_idx;
  p->low_count++;

  // Evict samples outside the 5s sliding baseline window.
  double cutoff = arrived_ms - MB_PACE_CLOCK_WINDOW_MS;
  while (p->sample_count > 1u && p->samples[p->sample_head].time_ms < cutoff) {
    uint64_t evicted_seq = p->samples[p->sample_head].seq;
    p->sample_head = (p->sample_head + 1u) & MB_PACE_SAMPLE_MASK;
    p->sample_count--;
    if (p->low_count > 0u && p->samples[p->lows[p->low_head]].seq == evicted_seq) {
      p->low_head = (p->low_head + 1u) & MB_PACE_SAMPLE_MASK;
      p->low_count--;
    }
  }

  double base = p->samples[p->lows[p->low_head]].offset_ms;
  double late = offset - base;
  if (late < 0.0) late = 0.0;
  p->samples[ins_idx].late_ms = late;

  // Gather lateness samples within the 2s jitter window and compute the P95 quantile.
  double recent[MB_PACE_MAX_SAMPLES];
  size_t nrecent = 0;
  double jcutoff = arrived_ms - MB_PACE_JITTER_WINDOW_MS;
  for (uint32_t i = p->sample_count; i > 0u; i--) {
    uint32_t idx = (p->sample_head + i - 1u) & MB_PACE_SAMPLE_MASK;
    if (p->samples[idx].time_ms < jcutoff) break;
    recent[nrecent++] = p->samples[idx].late_ms;
  }

  double target = 0.0;
  if (nrecent > 0) {
    mb_pace_sort_doubles(recent, nrecent);
    size_t qidx = (size_t)floor(MB_PACE_JITTER_QUANTILE * (double)(nrecent - 1));
    if (qidx >= nrecent) qidx = nrecent - 1;
    target = recent[qidx];
    if (target > MB_PACE_MAX_HOLD_MS) target = MB_PACE_MAX_HOLD_MS;
    if (target < 0.0) target = 0.0;
  }

  // Fast attack on jitter spikes, gentle linear decay when network calms.
  if (target >= p->hold_ms) {
    p->hold_ms = target;
  } else {
    double dt = arrived_ms - prev_time;
    if (dt < 0.0) dt = 0.0;
    double decayed = p->hold_ms - dt * MB_PACE_HOLD_DECAY;
    p->hold_ms = target > decayed ? target : decayed;
  }
  if (p->hold_ms < 0.0) p->hold_ms = 0.0;
  if (p->hold_ms > MB_PACE_MAX_HOLD_MS) p->hold_ms = MB_PACE_MAX_HOLD_MS;

  p->last_arrival_ms = arrived_ms;
  p->has_last_arrival = 1u;

  out.base_ms = base;
  out.arrived_ms = arrived_ms;
  out.immediate = immediate;
  return out;
}

// Whether a queued frame is due to be presented at `now_ms`.
static inline int mb_pace_is_due(const mb_pace_t *p, double ts_us, double base_ms, uint8_t immediate, double now_ms) {
  if (immediate) return 1;
  double hold = p ? p->hold_ms : 0.0;
  return (ts_us / 1000.0 + base_ms + hold) <= (now_ms + 1e-6);
}

// Actual time a frame spent buffered on the client before presentation or drop, in microseconds.
static inline uint32_t mb_pace_wait_us(double arrived_ms, double now_ms) {
  double ms = now_ms - arrived_ms;
  if (!(ms > 0.0)) return 0u;
  double us = ms * 1000.0 + 0.5;
  if (us >= 4294967295.0) return 0xFFFFFFFFu;
  return (uint32_t)us;
}

// Pure phase evaluation for the four-state catch-up state machine.
static inline mb_pace_phase_t mb_pace_phase(int due, int draws, double backlog_ms, double since_catch_up_ms,
                                            double head_overstay_ms) {
  if (due <= MB_PACE_IDLE_DUE) return MB_PACE_IDLE;
  if (due > MB_PACE_OVERRUN_DUE || head_overstay_ms > MB_PACE_OVERRUN_STAY_MS) return MB_PACE_OVERRUN;
  if (due - draws <= MB_PACE_IDLE_DUE) return MB_PACE_IDLE;
  if (backlog_ms < MB_PACE_BACKLOG_GRACE_MS || since_catch_up_ms < MB_PACE_CATCH_UP_INTERVAL_MS) {
    return MB_PACE_BACKLOG;
  }
  return MB_PACE_CATCH_UP;
}

// Decide how many oldest due frames to drop right now to keep latency bounded without stutter.
// `due`: number of currently due frames at the head of the queue.
// `draws`: 1 when called at the start of a VSync tick that will present a frame, 0 on arrival.
// `head_arrived_ms`: arrival timestamp (ms) of the oldest queued frame (ignored if due == 0).
// Returns the number of oldest frames the caller should drop and acknowledge.
static inline int mb_pace_trim(mb_pace_t *p, int due, int draws, double head_arrived_ms, double now_ms,
                               mb_pace_phase_t *phase_out) {
  if (!p || due <= 0) {
    if (p) p->has_backlog = 0u;
    if (phase_out) *phase_out = MB_PACE_IDLE;
    return 0;
  }

  double backlog_ms = p->has_backlog ? (now_ms - p->backlog_since_ms) : 0.0;
  if (backlog_ms < 0.0) backlog_ms = 0.0;
  double since_catch_up_ms = p->has_catch_up ? (now_ms - p->last_catch_up_ms) : 1e9;
  if (since_catch_up_ms < 0.0) since_catch_up_ms = 0.0;
  double head_overstay_ms = now_ms - head_arrived_ms - p->hold_ms;

  mb_pace_phase_t phase = mb_pace_phase(due, draws, backlog_ms, since_catch_up_ms, head_overstay_ms);
  if (phase_out) *phase_out = phase;

  if (phase == MB_PACE_IDLE) {
    p->has_backlog = 0u;
    return 0;
  }
  if (!p->has_backlog) {
    p->has_backlog = 1u;
    p->backlog_since_ms = now_ms;
  }
  if (phase == MB_PACE_BACKLOG) {
    return 0;
  }
  if (phase == MB_PACE_CATCH_UP) {
    p->last_catch_up_ms = now_ms;
    p->has_catch_up = 1u;
    if (due - 1 <= MB_PACE_IDLE_DUE) p->has_backlog = 0u;
    return 1;
  }

  // MB_PACE_OVERRUN: jump quickly to leave at most MB_PACE_IDLE_DUE due frames.
  int drop = due - MB_PACE_IDLE_DUE;
  p->has_backlog = 0u;
  return drop > 0 ? drop : 0;
}

#ifdef __cplusplus
}
#endif

#endif  // MB_STREAM_PACE_H
