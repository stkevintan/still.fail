// Shared host frame_late continuity helpers: computes how late the previous frame reached
// the screen, and immediately breaks the chain whenever no next app frame was requested.
#pragma once

static inline double mb_frame_late_from_begin(double last_begin, double begins, double period_ms, int scripted) {
  if (last_begin < 0.0 || scripted) return 0.0;
  double late = begins - last_begin - period_ms;
  return late > 0.0 ? late : 0.0;
}

static inline double mb_frame_late_from_target(double last_target, double now_ms) {
  if (last_target < 0.0) return 0.0;
  double late = now_ms - last_target;
  return late > 0.0 ? late : 0.0;
}

static inline double mb_frame_late_next(int want_next, double mark) {
  return want_next ? mark : -1.0;
}
