// Deterministic unit tests and network jitter simulation benchmarks for stream_pace.h.
// Compile & run:
//   clang -O2 -Wall -Wextra -Werror -std=c11 libs/ui/src/host/stream_pace_test.c -lm -o /tmp/stream_pace_test && /tmp/stream_pace_test
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "stream_pace.h"

// Deterministic PRNG (xorshift64*) for reproducible jitter simulations.
static uint64_t rng_state = 0x9e3779b97f4a7c15ULL;
static double rng_uniform(void) {
  uint64_t x = rng_state;
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  rng_state = x;
  return (double)((x * 2685821657736338717ULL) >> 11) * (1.0 / 9007199254740992.0);
}

typedef struct {
  double ts_us;
  double arrived_ms;
  double base_ms;
  uint8_t immediate;
} sim_item_t;

typedef struct {
  double intervals[2000];
  int n_intervals;
  int shown;
  int dropped_collide;  // overwritten in same VSync period (never seen by viewer)
  int dropped_pace;     // intentionally dropped by catch-up/overrun
  int repeated_vsyncs;  // VSync ticks with no new frame during active stream
  double total_wait_ms;
  double max_hold_ms;
  double final_hold_ms;
} sim_stats_t;

static void stats_summary(const sim_stats_t *st, double *stddev_out, double *p95_err_out, double *p99_err_out,
                          double target_ms) {
  double errs[2000];
  double mean = 0.0;
  for (int i = 0; i < st->n_intervals; i++) mean += st->intervals[i];
  if (st->n_intervals > 0) mean /= st->n_intervals;
  double var = 0.0;
  for (int i = 0; i < st->n_intervals; i++) {
    double d = st->intervals[i] - mean;
    var += d * d;
    errs[i] = fabs(st->intervals[i] - target_ms);
  }
  *stddev_out = st->n_intervals > 1 ? sqrt(var / st->n_intervals) : 0.0;
  if (st->n_intervals > 0) {
    mb_pace_sort_doubles(errs, (size_t)st->n_intervals);
    *p95_err_out = errs[(size_t)floor(0.95 * (st->n_intervals - 1))];
    *p99_err_out = errs[(size_t)floor(0.99 * (st->n_intervals - 1))];
  } else {
    *p95_err_out = *p99_err_out = 0.0;
  }
}

// Simulate legacy direct-present (0ms buffer, Windows) or 4ms timer (macOS) on a 60Hz display.
static sim_stats_t sim_legacy(const double *arrivals, int nframes, double vsync_ms, double pace_ms) {
  sim_stats_t st;
  memset(&st, 0, sizeof(st));
  double put_at = -1e9;
  double held_due = -1.0;
  int has_held = 0;

  // Map each presented frame to the VSync slot it actually scans out on.
  int last_vsync_slot = -1;
  double last_scan_ms = -1.0;

  // Process all frame arrivals and pending 4ms timer firings in chronological order.
  for (int i = 0; i < nframes; i++) {
    double t = arrivals[i];
    if (has_held && held_due <= t) {
      int slot = (int)ceil(held_due / vsync_ms);
      if (slot == last_vsync_slot) {
        st.dropped_collide++;
      } else {
        if (last_vsync_slot >= 0) {
          if (slot > last_vsync_slot + 1) st.repeated_vsyncs += (slot - last_vsync_slot - 1);
          double scan_ms = slot * vsync_ms;
          if (st.n_intervals < 2000) st.intervals[st.n_intervals++] = scan_ms - last_scan_ms;
          last_scan_ms = scan_ms;
        } else {
          last_scan_ms = slot * vsync_ms;
        }
        last_vsync_slot = slot;
        st.shown++;
      }
      put_at = held_due;
      has_held = 0;
    }

    if (pace_ms > 0.0 && !has_held && (t - put_at) < pace_ms) {
      has_held = 1;
      held_due = put_at + pace_ms;
    } else {
      if (has_held) {
        // Third frame arrived while one was held -> overwrote held frame!
        st.dropped_collide++;
        has_held = 0;
      }
      int slot = (int)ceil(t / vsync_ms);
      if (slot == last_vsync_slot) {
        st.dropped_collide++;
      } else {
        if (last_vsync_slot >= 0) {
          if (slot > last_vsync_slot + 1) st.repeated_vsyncs += (slot - last_vsync_slot - 1);
          double scan_ms = slot * vsync_ms;
          if (st.n_intervals < 2000) st.intervals[st.n_intervals++] = scan_ms - last_scan_ms;
          last_scan_ms = scan_ms;
        } else {
          last_scan_ms = slot * vsync_ms;
        }
        last_vsync_slot = slot;
        st.shown++;
      }
      put_at = t;
    }
  }
  return st;
}

// Simulate the new VSync-aligned adaptive jitter buffer (stream_pace.h).
static sim_stats_t sim_adaptive(const double *ts_us, const double *arrivals, int nframes, double vsync_ms,
                                int skip_warmup) {
  sim_stats_t st;
  memset(&st, 0, sizeof(st));

  mb_pace_t pace;
  mb_pace_init(&pace);

  sim_item_t q[MB_PACE_QUEUE_CAP];
  int qlen = 0;
  int drawn_this_tick = 0;

  double end_ms = arrivals[nframes - 1] + 200.0;
  int next_frame = 0;
  int last_vsync_slot = -1;
  double last_scan_ms = -1.0;
  int shown_total = 0;

  for (int slot = 0;; slot++) {
    double tick_ms = slot * vsync_ms;
    if (tick_ms > end_ms && next_frame >= nframes && qlen == 0) break;

    // Deliver all frames that arrived before or at this VSync tick.
    while (next_frame < nframes && arrivals[next_frame] <= tick_ms) {
      double t = arrivals[next_frame];
      double ts = ts_us[next_frame];
      next_frame++;

      mb_pace_arrival_t obs = mb_pace_observe(&pace, ts, t);
      if (pace.hold_ms > st.max_hold_ms) st.max_hold_ms = pace.hold_ms;

      if (qlen >= MB_PACE_QUEUE_CAP) {
        memmove(&q[0], &q[1], (size_t)(qlen - 1) * sizeof(q[0]));
        qlen--;
        st.dropped_pace++;
      }
      int was_empty = (qlen == 0);
      q[qlen].ts_us = ts;
      q[qlen].arrived_ms = obs.arrived_ms;
      q[qlen].base_ms = obs.base_ms;
      q[qlen].immediate = obs.immediate;
      qlen++;

      int due = 0;
      while (due < qlen && mb_pace_is_due(&pace, q[due].ts_us, q[due].base_ms, q[due].immediate, t)) due++;
      int drop = mb_pace_trim(&pace, due, 0, qlen > 0 ? q[0].arrived_ms : 0.0, t, NULL);
      if (drop > 0) {
        if (drop > qlen) drop = qlen;
        memmove(&q[0], &q[drop], (size_t)(qlen - drop) * sizeof(q[0]));
        qlen -= drop;
        st.dropped_pace += drop;
      }

      if (was_empty && !drawn_this_tick && qlen > 0 &&
          mb_pace_is_due(&pace, q[0].ts_us, q[0].base_ms, q[0].immediate, t)) {
        sim_item_t f = q[0];
        memmove(&q[0], &q[1], (size_t)(qlen - 1) * sizeof(q[0]));
        qlen--;
        drawn_this_tick = 1;
        uint32_t wus = mb_pace_wait_us(f.arrived_ms, t);
        st.total_wait_ms += (double)wus / 1000.0;
        shown_total++;
        if (shown_total > skip_warmup) {
          if (slot == last_vsync_slot) {
            st.dropped_collide++;
          } else {
            if (last_vsync_slot >= 0) {
              if (slot > last_vsync_slot + 1) st.repeated_vsyncs += (slot - last_vsync_slot - 1);
              double scan_ms = slot * vsync_ms;
              if (st.n_intervals < 2000) st.intervals[st.n_intervals++] = scan_ms - last_scan_ms;
              last_scan_ms = scan_ms;
            } else {
              last_scan_ms = slot * vsync_ms;
            }
            last_vsync_slot = slot;
            st.shown++;
          }
        }
      }
    }

    // VSync tick fires at tick_ms.
    drawn_this_tick = 0;
    int due = 0;
    while (due < qlen && mb_pace_is_due(&pace, q[due].ts_us, q[due].base_ms, q[due].immediate, tick_ms)) due++;
    int drop = mb_pace_trim(&pace, due, 1, qlen > 0 ? q[0].arrived_ms : 0.0, tick_ms, NULL);
    if (drop > 0) {
      if (drop > qlen) drop = qlen;
      memmove(&q[0], &q[drop], (size_t)(qlen - drop) * sizeof(q[0]));
      qlen -= drop;
      st.dropped_pace += drop;
    }
    if (qlen > 0 && mb_pace_is_due(&pace, q[0].ts_us, q[0].base_ms, q[0].immediate, tick_ms)) {
      sim_item_t f = q[0];
      memmove(&q[0], &q[1], (size_t)(qlen - 1) * sizeof(q[0]));
      qlen--;
      drawn_this_tick = 1;
      uint32_t wus = mb_pace_wait_us(f.arrived_ms, tick_ms);
      st.total_wait_ms += (double)wus / 1000.0;
      shown_total++;
      if (shown_total > skip_warmup) {
        int scan_slot = slot + 1;
        if (scan_slot == last_vsync_slot) {
          st.dropped_collide++;
        } else {
          if (last_vsync_slot >= 0) {
            if (scan_slot > last_vsync_slot + 1) st.repeated_vsyncs += (scan_slot - last_vsync_slot - 1);
            double scan_ms = scan_slot * vsync_ms;
            if (st.n_intervals < 2000) st.intervals[st.n_intervals++] = scan_ms - last_scan_ms;
            last_scan_ms = scan_ms;
          } else {
            last_scan_ms = scan_slot * vsync_ms;
          }
          last_vsync_slot = scan_slot;
          st.shown++;
        }
      }
    }
  }
  st.final_hold_ms = pace.hold_ms;
  return st;
}

static void test_lan_low_jitter(void) {
  const int N = 300;
  const double vsync_ms = 1000.0 / 60.0;
  double ts_us[300], arrivals[300];
  rng_state = 0x1111222233334444ULL;
  for (int i = 0; i < N; i++) {
    double ideal = i * vsync_ms;
    ts_us[i] = ideal * 1000.0;
    double jitter = rng_uniform() * 1.0;  // 0-1 ms LAN jitter
    arrivals[i] = ideal + 2.0 + jitter;
  }
  sim_stats_t st = sim_adaptive(ts_us, arrivals, N, vsync_ms, 15);
  double sd, p95, p99;
  stats_summary(&st, &sd, &p95, &p99, vsync_ms);
  printf("[1. LAN 0-1ms jitter] hold_final=%.2fms hold_max=%.2fms interval_stddev=%.3fms p95_err=%.3fms collide=%d repeat=%d\n",
         st.final_hold_ms, st.max_hold_ms, sd, p95, st.dropped_collide, st.repeated_vsyncs);
  assert(st.final_hold_ms <= 2.0);
  assert(st.max_hold_ms <= 2.0);
  assert(sd < 0.5);
  assert(st.dropped_collide == 0);
}

static void test_wan_jitter_comparison(void) {
  const int N = 600;  // 10 seconds @ 60fps
  const double vsync_ms = 1000.0 / 60.0;
  double ts_us[600], arrivals[600];
  rng_state = 0xCAFEBABE12345678ULL;
  double prev_arr = 0.0;
  for (int i = 0; i < N; i++) {
    double ideal = i * vsync_ms;
    ts_us[i] = ideal * 1000.0;
    // Same-city WAN: base 15ms RTT + ±12-20ms bursty jitter (exponential + uniform mix)
    double j = (rng_uniform() * 24.0) + (rng_uniform() < 0.15 ? rng_uniform() * 16.0 : 0.0);
    double arr = ideal + 15.0 + j;
    if (arr < prev_arr + 0.2) arr = prev_arr + 0.2;  // TCP/QUIC in-order delivery
    arrivals[i] = arr;
    prev_arr = arr;
  }

  sim_stats_t leg0 = sim_legacy(arrivals + 60, N - 60, vsync_ms, 0.0);
  sim_stats_t leg4 = sim_legacy(arrivals + 60, N - 60, vsync_ms, 4.0);
  sim_stats_t adap = sim_adaptive(ts_us, arrivals, N, vsync_ms, 60);

  double sd0, p95_0, p99_0;
  double sd4, p95_4, p99_4;
  double sda, p95_a, p99_a;
  stats_summary(&leg0, &sd0, &p95_0, &p99_0, vsync_ms);
  stats_summary(&leg4, &sd4, &p95_4, &p99_4, vsync_ms);
  stats_summary(&adap, &sda, &p95_a, &p99_a, vsync_ms);

  printf("[2. Same-City WAN 60fps +-12..20ms jitter (540 steady frames)]\n");
  printf("    Legacy 0ms (Win)  : p95_err=%5.2fms p99_err=%5.2fms stddev=%5.2fms collide_drops=%3d repeat_vsyncs=%3d\n",
         p95_0, p99_0, sd0, leg0.dropped_collide, leg0.repeated_vsyncs);
  printf("    Legacy 4ms (Mac)  : p95_err=%5.2fms p99_err=%5.2fms stddev=%5.2fms collide_drops=%3d repeat_vsyncs=%3d\n",
         p95_4, p99_4, sd4, leg4.dropped_collide, leg4.repeated_vsyncs);
  printf("    Adaptive VSync    : p95_err=%5.2fms p99_err=%5.2fms stddev=%5.2fms collide_drops=%3d repeat_vsyncs=%3d hold=%.1fms\n",
         p95_a, p99_a, sda, adap.dropped_collide, adap.repeated_vsyncs, adap.final_hold_ms);

  assert(adap.dropped_collide == 0);
  assert(adap.repeated_vsyncs < leg0.repeated_vsyncs / 4);
  assert(adap.repeated_vsyncs < leg4.repeated_vsyncs / 4);
  assert(p95_a < p95_0);
  assert(sda < sd0 / 2.0);
  assert(adap.final_hold_ms <= MB_PACE_MAX_HOLD_MS);
}

static void test_silence_first_frame_zero_wait(void) {
  mb_pace_t p;
  mb_pace_init(&p);

  // Warm up with jittery frames so hold_ms rises to ~25ms.
  for (int i = 0; i < 40; i++) {
    double ts_ms = i * 16.667;
    double late = (i % 5 == 0) ? 25.0 : 0.0;
    mb_pace_observe(&p, ts_ms * 1000.0, ts_ms + late);
  }
  assert(p.hold_ms >= 20.0);

  // Now 500ms of silence (static screen, user moves mouse).
  double silent_ts_ms = 40 * 16.667 + 500.0;
  double arrive_ms = silent_ts_ms + 5.0;
  mb_pace_arrival_t first = mb_pace_observe(&p, silent_ts_ms * 1000.0, arrive_ms);
  assert(first.immediate == 1u);
  // First frame after silence MUST be immediately due regardless of hold_ms!
  assert(mb_pace_is_due(&p, silent_ts_ms * 1000.0, first.base_ms, first.immediate, arrive_ms) == 1);
  assert(mb_pace_wait_us(first.arrived_ms, arrive_ms) == 0u);

  // Subsequent continuous motion frame (16.67ms later) should NOT bypass pacing.
  double next_ts_ms = silent_ts_ms + 16.667;
  double next_arr_ms = arrive_ms + 16.667;
  mb_pace_arrival_t second = mb_pace_observe(&p, next_ts_ms * 1000.0, next_arr_ms);
  assert(second.immediate == 0u);
  printf("[3. Silence 500ms -> first frame] immediate=%u wait_us=%u next_immediate=%u hold=%.2fms\n",
         first.immediate, mb_pace_wait_us(first.arrived_ms, arrive_ms), second.immediate, p.hold_ms);
}

static void test_burst_catchup_and_overrun(void) {
  mb_pace_t p;
  mb_pace_init(&p);

  // Establish 0ms baseline.
  mb_pace_observe(&p, 0.0, 0.0);
  mb_pace_observe(&p, 16667.0, 16.667);

  // Simulate 6 frames arriving in a burst, all due at t=100ms.
  mb_pace_phase_t phase = MB_PACE_IDLE;
  int drop0 = mb_pace_trim(&p, 6, 1, 80.0, 100.0, &phase);
  assert(phase == MB_PACE_BACKLOG);
  assert(drop0 == 0);  // Brief backlog tolerated without immediate drop.

  // Still 6 due after 300ms (< 500ms grace): still backlog.
  int drop1 = mb_pace_trim(&p, 6, 1, 250.0, 400.0, &phase);
  assert(phase == MB_PACE_BACKLOG);
  assert(drop1 == 0);

  // Still 6 due after 550ms (>= 500ms grace): smooth catch-up drops exactly 1 frame.
  int drop2 = mb_pace_trim(&p, 6, 1, 500.0, 650.0, &phase);
  assert(phase == MB_PACE_CATCH_UP);
  assert(drop2 == 1);

  // 100ms later (< 250ms catch-up interval): back to backlog (no consecutive double-drop).
  int drop3 = mb_pace_trim(&p, 5, 1, 600.0, 750.0, &phase);
  assert(phase == MB_PACE_BACKLOG);
  assert(drop3 == 0);

  // 260ms after last catch-up: drops 1 more frame smoothly.
  int drop4 = mb_pace_trim(&p, 5, 1, 760.0, 910.0, &phase);
  assert(phase == MB_PACE_CATCH_UP);
  assert(drop4 == 1);

  // Extreme overrun (> 10 due frames): jumps immediately leaving 2 due frames.
  int drop_over = mb_pace_trim(&p, 12, 1, 900.0, 950.0, &phase);
  assert(phase == MB_PACE_OVERRUN);
  assert(drop_over == 10);

  // Verify wait_us accuracy & clamping.
  assert(mb_pace_wait_us(100.0, 118.5) == 18500u);
  assert(mb_pace_wait_us(100.0, 99.0) == 0u);
  assert(mb_pace_wait_us(0.0, 5e6) == 0xFFFFFFFFu);

  printf("[4. Burst catch-up & overrun] backlog=0 catchUp=1 interval_gated=0 overrun(12->2)=%d wait_us(18.5ms)=%u\n",
         drop_over, mb_pace_wait_us(100.0, 118.5));
}

static void test_clock_jump_and_reset(void) {
  mb_pace_t p;
  mb_pace_init(&p);

  for (int i = 0; i < 30; i++) {
    mb_pace_observe(&p, i * 16667.0, i * 16.667 + (i % 4 == 0 ? 20.0 : 0.0));
  }
  assert(p.hold_ms >= 15.0);

  // Jump > 500ms in offset -> automatic reset.
  mb_pace_arrival_t jumped = mb_pace_observe(&p, 500000.0, 5000.0);
  assert(jumped.immediate == 1u);
  assert(p.hold_ms == 0.0);
  assert(p.sample_count == 1u);

  // Explicit reset clears everything.
  mb_pace_reset(&p);
  assert(p.sample_count == 0u);
  assert(p.hold_ms == 0.0);
  assert(p.has_last_arrival == 0u);

  printf("[5. Clock jump & reset] jump_reset_hold=%.2fms sample_count_after_reset=%u OK\n",
         p.hold_ms, p.sample_count);
}

int main(void) {
  test_lan_low_jitter();
  test_wan_jitter_comparison();
  test_silence_first_frame_zero_wait();
  test_burst_catchup_and_overrun();
  test_clock_jump_and_reset();
  printf("ALL stream_pace TESTS PASSED\n");
  return 0;
}
