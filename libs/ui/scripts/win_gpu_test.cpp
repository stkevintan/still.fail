// src/host/win_render.cpp's D3D11 timestamp query ring and dropped-frame counting tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_gpu_test.cpp \
//     -Foout/gpu/ -Feout/gpu/win_gpu_test.exe \
//     -link d3d11.lib d3dcompiler.lib dcomp.lib dwmapi.lib gdi32.lib user32.lib windowscodecs.lib ole32.lib
//   out/gpu/win_gpu_test.exe
// Verifies:
// 1. Non-blocking 4-slot D3D11 timestamp disjoint query ring produces valid GPU ms (or degrades cleanly on WARP)
//    and recycles slots across multiple frames and gpu_q_free() without leaking or stalling.
// 2. win_count_dropped_step() accurately counts drops during continuous animation, ignores idle pauses
//    (>= 2.5 * display_period between the samples' sync times), counts in frames of `beats` refreshes (240Hz/360Hz
//    paced to 120fps), clamps spikes to MB_WIN_DROPPED_CLAMP, and guards non-monotonic counters and missing times.
#define MB_NO_MOONBIT_H 1
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef const wchar_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;
static size_t test_mb_len = 0;
static size_t Moonbit_array_length(moonbit_bytes_t) { return test_mb_len; }

extern "C" {
const wchar_t *mb_win_env(const wchar_t *) { return NULL; }
const wchar_t *mb_win_app_id(void) { return L""; }
void mb_host_request_frame(void) {}
void *mb_image_srv(int) { return NULL; }
void *mb_stream_srv(int) { return NULL; }
void mb_text_set_scale(double) {}
int mb_views_count(void) { return 0; }
void mb_views_draw_under(uint8_t *, int, int, double) {}
double mb_app_scale(void) { return 1.0; }
}

#include "win_render.cpp"

static int failed = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static void fill_rect_instances(double *inst, int count) {
  memset(inst, 0, (size_t)count * MB_INST * sizeof(double));
  for (int i = 0; i < count; i++) {
    double *p = inst + (size_t)i * MB_INST;
    p[0] = (double)((i % 16) * 8);
    p[1] = (double)((i / 16) * 8);
    p[2] = 8.0;
    p[3] = 8.0;
    p[8] = 0.2;
    p[9] = 0.5;
    p[10] = 0.8;
    p[11] = 1.0;
    p[16] = -1e9;
    p[17] = -1e9;
    p[18] = 1e9;
    p[19] = 1e9;
  }
}

static void test_dropped_step_logic(void) {
  const int64_t freq = 10000000;  // 10 MHz QPC (10000 ticks = 1 ms)
  const double p60 = 1000.0 / 60.0;
  // First sample (has_prev = 0): never counts drops.
  CHECK(win_count_dropped_step(0, 0, 0, 0, 10, 20, 100000, freq, p60, 1) == 0);
  // Continuous 60Hz (dt = 16.67ms < 41.67ms), no drops (d_sync == d_present == 1).
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 101, 266700, freq, p60, 1) == 0);
  // Continuous animation (dt = 33.3ms < 41.67ms), 2 sync refreshes missed (d_sync=3, d_present=1).
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 103, 433000, freq, p60, 1) == 2);
  // Idle pause (dt = 50ms >= 2.5 * 16.67ms): ignored even if d_sync > d_present.
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 104, 600000, freq, p60, 1) == 0);
  // Huge spike within continuous window: clamped to MB_WIN_DROPPED_CLAMP (10).
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 11, 150, 300000, freq, p60, 1) == MB_WIN_DROPPED_CLAMP);
  // Non-monotonic QPC or PresentCount: 0.
  CHECK(win_count_dropped_step(10, 100, 200000, 1, 11, 103, 100000, freq, p60, 1) == 0);
  CHECK(win_count_dropped_step(10, 100, 100000, 1, 10, 103, 200000, freq, p60, 1) == 0);
  // 120Hz continuous (period = 8.33ms, 2.5x = 20.83ms): dt = 16.67ms counts 1 drop, dt = 22ms ignored.
  const double p120 = 1000.0 / 120.0;
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 12, 266700, freq, p120, 1) == 1);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 13, 320000, freq, p120, 1) == 0);

  // 240Hz paced to 120fps (beats = 2, period = 8.33ms per frame, 2.5x = 20.83ms): each present expects 2 syncs.
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 12, 183300, freq, p120, 2) == 0);   // normal frame
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 13, 225000, freq, p120, 2) == 0);   // one-beat phase jitter
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 266700, freq, p120, 2) == 1);   // one 120fps frame dropped
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 16, 300000, freq, p120, 2) == 2);   // two dropped
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 3, 16, 300000, freq, p120, 2) == 1);   // two presents, one dropped
  // 360Hz paced to 120fps (beats = 3).
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 13, 183300, freq, p120, 3) == 0);   // normal frame
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 16, 266700, freq, p120, 3) == 1);   // one dropped
  // Waking from a 500ms idle: the samples' own sync times are 500ms apart, so the long sync gap is not a drop.
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 130, 5100000, freq, p120, 2) == 0);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 130, 5100000, freq, p60, 1) == 0);
  // A sample without a sync time, or no beats: 0.
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 0, freq, p120, 2) == 0);
  CHECK(win_count_dropped_step(1, 10, 0, 1, 2, 14, 166700, freq, p120, 2) == 0);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 266700, freq, p120, 0) == 0);
  CHECK(win_count_dropped_step(1, 10, 100000, 1, 2, 14, 266700, freq, p120, -1) == 0);
}

static void fill_p0_rect(double *p, double x, double y, double w, double h, double kind, double r, double g, double b,
                         double a, double grp) {
  memset(p, 0, MB_INST * sizeof(double));
  p[0] = x;
  p[1] = y;
  p[2] = w;
  p[3] = h;
  p[5] = kind;
  p[8] = r;
  p[9] = g;
  p[10] = b;
  p[11] = a;
  p[16] = -1e9;
  p[17] = -1e9;
  p[18] = 1e9;
  p[19] = 1e9;
  p[20] = grp;
}

static int read_offscreen_pixel_rgb(int px, int py, uint8_t rgb[3]) {
  if (!dev || !ctx || !off_target) return 0;
  D3D11_TEXTURE2D_DESC td = {};
  off_target->GetDesc(&td);
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  ID3D11Texture2D *staging = NULL;
  if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) return 0;
  ctx->CopyResource(staging, off_target);
  D3D11_MAPPED_SUBRESOURCE m = {};
  int ok = 0;
  if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
    const uint8_t *p = (const uint8_t *)m.pData + (size_t)py * (size_t)m.RowPitch + (size_t)px * 4u;
    rgb[0] = p[2];  // R (off_target is DXGI_FORMAT_B8G8R8A8_UNORM)
    rgb[1] = p[1];  // G
    rgb[2] = p[0];  // B
    ctx->Unmap(staging, 0);
    ok = 1;
  }
  staging->Release();
  return ok;
}

static int read_ad_bright_t(double *out_t) {
  if (!dev || !ctx || !rw || !rw->ad_tex[rw->ad_cur].t) return 0;
  ID3D11Texture2D *src = rw->ad_tex[rw->ad_cur].t;
  D3D11_TEXTURE2D_DESC td = {};
  src->GetDesc(&td);
  td.Usage = D3D11_USAGE_STAGING;
  td.BindFlags = 0;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  td.MiscFlags = 0;
  ID3D11Texture2D *staging = NULL;
  if (FAILED(dev->CreateTexture2D(&td, NULL, &staging))) return 0;
  ctx->CopyResource(staging, src);
  D3D11_MAPPED_SUBRESOURCE m = {};
  int ok = 0;
  if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
    const uint8_t *p = (const uint8_t *)m.pData;
    *out_t = ((double)p[0] * 256.0 + (double)p[1]) / 65535.0;
    ctx->Unmap(staging, 0);
    ok = 1;
  }
  staging->Release();
  return ok;
}

static uint8_t *render_rgba_pixels_of(const double *inst, int count, double r, double g, double b, double scale, int w, int h) {
  size_t bytes = (size_t)w * (size_t)h * 4u;
  uint8_t *buf = (uint8_t *)malloc(bytes);
  if (!buf) return NULL;
  test_mb_len = bytes;
  int ok = mb_render_pixels_of(inst, count, r, g, b, scale, w, h, buf);
  test_mb_len = 0;
  if (!ok) {
    free(buf);
    return NULL;
  }
  return buf;
}

static void test_p0_liquid_glass_vectors(void) {
  struct VecCase {
    const char *name;
    double bg[3];
    double tint[4];
    int is_clear;
    int adaptive;
  };
  static const VecCase cases[7] = {
      {"dark_black", {0.0, 0.0, 0.0}, {32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0}, 0, 0},
      {"dark_1b1c1f", {27.0 / 255.0, 28.0 / 255.0, 31.0 / 255.0}, {32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0}, 0, 0},
      {"dark_ad_white", {1.0, 1.0, 1.0}, {32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0}, 0, 1},
      {"light_blue", {0.0, 136.0 / 255.0, 1.0}, {253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0x67 / 255.0}, 0, 0},
      {"pure_clear", {0.0, 1.0, 64.0 / 255.0}, {1.0, 1.0, 1.0, 0.0}, 1, 0},
      {"light_d9_blue", {0.0, 0.4, 1.0}, {253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0xD9 / 255.0}, 0, 0},
      {"light_ff_blue", {0.0, 0.4, 1.0}, {253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 1.0}, 0, 0},
  };
  for (int i = 0; i < 7; i++) {
    double inst[2 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, cases[i].bg[0], cases[i].bg[1], cases[i].bg[2], 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, cases[i].tint[0], cases[i].tint[1], cases[i].tint[2],
                 cases[i].tint[3], (double)(-40 - i));
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = 1.0;
    inst[MB_INST + 7] = cases[i].is_clear ? 0.0 : 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = cases[i].adaptive ? -1.0 : 0.0;
    inst[MB_INST + 15] = 1.0;
    uint8_t *px = render_rgba_pixels_of(inst, 2, cases[i].bg[0], cases[i].bg[1], cases[i].bg[2], 1.0, 128, 128);
    CHECK(px != NULL);
    if (!px) continue;
    const uint8_t *rgb = px + ((size_t)64 * 128u + 64u) * 4u;
    printf("win_gpu: p0 %s -> rgb(%u, %u, %u)\n", cases[i].name, rgb[0], rgb[1], rgb[2]);
    if (i == 0) {
      CHECK(rgb[0] >= 26 && rgb[0] <= 34 && rgb[1] >= 26 && rgb[1] <= 34 && rgb[2] >= 26 && rgb[2] <= 34);
    } else if (i == 1) {
      CHECK(rgb[0] >= 41 && rgb[0] <= 51 && rgb[1] >= 42 && rgb[1] <= 52 && rgb[2] >= 45 && rgb[2] <= 55);
    } else if (i == 2) {
      CHECK(rgb[0] >= 85 && rgb[0] <= 101 && rgb[1] >= 85 && rgb[1] <= 101 && rgb[2] >= 85 && rgb[2] <= 101);
    } else if (i == 3) {
      double mx = (double)(rgb[0] > rgb[1] ? (rgb[0] > rgb[2] ? rgb[0] : rgb[2]) : (rgb[1] > rgb[2] ? rgb[1] : rgb[2]));
      double mn = (double)(rgb[0] < rgb[1] ? (rgb[0] < rgb[2] ? rgb[0] : rgb[2]) : (rgb[1] < rgb[2] ? rgb[1] : rgb[2]));
      double sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
      CHECK(rgb[0] >= 27 && rgb[0] <= 51 && rgb[1] >= 142 && rgb[1] <= 166 && rgb[2] >= 243 && sat >= 0.80);
    } else if (i == 4) {
      CHECK(rgb[0] <= 8 && rgb[1] >= 247 && rgb[2] >= 56 && rgb[2] <= 72);
    } else if (i == 5) {
      CHECK(rgb[0] >= (uint8_t)(0.72 * 255.0 + 0.5) && rgb[1] >= 200 && rgb[2] >= 240);
    } else if (i == 6) {
      CHECK(rgb[0] >= 249 && rgb[1] >= 248 && rgb[2] >= 249);
    }
    free(px);
  }

  // Stateful adaptive transition test via submit() (verifies !is_new fix when serial == 0 and deterministic tau=70ms exponential convergence):
  {
    double inst[2 * MB_INST];
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0);
    fill_p0_rect(inst + MB_INST, 16.0, 16.0, 96.0, 96.0, 6.0, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0, -49.0);
    inst[MB_INST + 4] = 16.0;
    inst[MB_INST + 6] = 1.0;
    inst[MB_INST + 7] = 1.0;
    inst[MB_INST + 12] = 0.0;
    inst[MB_INST + 13] = 4.0;
    inst[MB_INST + 14] = -1.0;
    inst[MB_INST + 15] = 1.0;
    glass_free();
    ad_mode = 1;
    ad_cur_dt = 1.0 / 60.0;
    if (rw) {
      rw->ad_frame_serial = 0;
      memset(rw->ad_slots, 0, sizeof rw->ad_slots);
    }
    CHECK(submit(inst, 2, 1.0, 1.0, 1.0) == 1);
    ctx->Flush();
    double frame0_t = -1.0;
    uint8_t rgb0[3] = {0, 0, 0};
    CHECK(read_ad_bright_t(&frame0_t) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, rgb0) == 1);
    CHECK(frame0_t >= 0.98);
    CHECK(rgb0[0] >= 85 && rgb0[0] <= 101 && rgb0[1] >= 85 && rgb0[1] <= 101 && rgb0[2] >= 85 && rgb0[2] <= 101);

    // Flip backdrop from white -> black and advance rw->ad_frame_serial++ with deterministic dt = 1/60s.
    fill_p0_rect(inst, 0.0, 0.0, 128.0, 128.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0);
    double mid_frame3_t = -1.0, final_t = -1.0;
    uint8_t final_rgb[3] = {0, 0, 0};
    for (int f = 1; f <= 45; f++) {
      if (rw) rw->ad_frame_serial++;
      ad_cur_dt = 1.0 / 60.0;
      CHECK(submit(inst, 2, 0.0, 0.0, 0.0) == 1);
      ctx->Flush();
      if (f == 3) CHECK(read_ad_bright_t(&mid_frame3_t) == 1);
    }
    CHECK(read_ad_bright_t(&final_t) == 1);
    CHECK(read_offscreen_pixel_rgb(64, 64, final_rgb) == 1);
    printf("win_gpu: stateful_ad frame0_t=%.4f mid_frame3_t=%.4f final_t=%.4f final_rgb=(%u,%u,%u)\n",
           frame0_t, mid_frame3_t, final_t, final_rgb[0], final_rgb[1], final_rgb[2]);
    CHECK(mid_frame3_t > 0.25 && mid_frame3_t < 0.75);
    CHECK(final_t <= 0.02);
    CHECK(final_rgb[0] >= 26 && final_rgb[0] <= 34 && final_rgb[1] >= 26 && final_rgb[1] <= 34 && final_rgb[2] >= 26 && final_rgb[2] <= 34);
    ad_cur_dt = 0.0;
    glass_free();
  }
}

static void test_v8_v9_droplet_roi_gates(void) {
  const int VW = 160, VH = 80;
  const int AW3 = VW * 3, AH3 = VH * 3;
  #define W_PX(buf, w, xpx, ypx) ((buf) + ((size_t)(ypx) * (size_t)(w) + (size_t)(xpx)) * 4u)

  // V8a: Slider Dark & Light @ 3x (full dx in [0,6]pt scan + 5-point 3D thickness profile)
  for (int is_light = 0; is_light <= 1; is_light++) {
    double bg = is_light ? 1.0 : 28.0 / 255.0;
    double bg_b = is_light ? 1.0 : 30.0 / 255.0;
    double sl[4 * MB_INST];
    fill_p0_rect(sl, 0, 0, VW, VH, 0, bg, bg, bg_b, 1.0, 0);
    fill_p0_rect(sl + MB_INST, 10, 37, 70, 6, 0, 0.0, 136.0 / 255.0, 1.0, 1.0, 0);
    fill_p0_rect(sl + 2 * MB_INST, 80, 37, 70, 6, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 1.0, 0);
    fill_p0_rect(sl + 3 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, 0.0, (double)(-50 - is_light));
    sl[3 * MB_INST + 4] = 19.0; sl[3 * MB_INST + 6] = 1.0; sl[3 * MB_INST + 7] = -16.0;
    sl[3 * MB_INST + 12] = 1.0; sl[3 * MB_INST + 13] = 9.0; sl[3 * MB_INST + 15] = 1.0;
    sl[3 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sl, 4, bg, bg, bg_b, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (!px) continue;
    double max_bh = 0.0, peak_dx = 0.0, h_55 = 0.0;
    double max_gh = 0.0, grey_peak_dx = 0.0, grey_h55 = 0.0;
    for (int i = 0; i <= 18; i++) {
      int x_l = 51 * 3 + i;
      int cnt = 0;
      for (int ypx = 21 * 3; ypx < 59 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, x_l, ypx);
        if ((int)c[2] - (int)c[0] > 100) cnt++;
      }
      double hpt = (double)cnt / 3.0;
      double dx_l = ((double)i + 0.5) / 3.0;
      if (hpt > max_bh) { max_bh = hpt; peak_dx = dx_l; }
      if (i == 16) h_55 = hpt;
    }
    uint8_t *bg_ref = W_PX(px, AW3, 80 * 3, 25 * 3);
    double ref_y = 0.2126 * bg_ref[0] + 0.7152 * bg_ref[1] + 0.0722 * bg_ref[2];
    for (int i = 0; i <= 18; i++) {
      int x_r = 109 * 3 - 1 - i;
      int cnt = 0;
      for (int ypx = 33 * 3; ypx < 47 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, x_r, ypx);
        double cy = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (is_light ? (cy < ref_y - 70.0) : (cy > ref_y + 20.0)) cnt++;
      }
      double hpt = (double)cnt / 3.0;
      double dx_r = ((double)i + 0.5) / 3.0;
      if (hpt > max_gh) { max_gh = hpt; grey_peak_dx = dx_r; }
      if (i == 16) grey_h55 = hpt;
    }
    uint8_t *c_l = W_PX(px, AW3, (int)(79.3 * 3), 40 * 3);
    uint8_t *c_r = W_PX(px, AW3, (int)(80.7 * 3), 40 * 3);
    uint8_t *c_top = W_PX(px, AW3, 60 * 3, 25 * 3);
    uint8_t *c_bot = W_PX(px, AW3, 60 * 3, 55 * 3);
    uint8_t *t0 = W_PX(px, AW3, 80 * 3, 21 * 3);
    uint8_t *t1 = W_PX(px, AW3, 80 * 3, 21 * 3 + 2);
    uint8_t *t2 = W_PX(px, AW3, 80 * 3, 23 * 3);
    uint8_t *t9 = W_PX(px, AW3, 80 * 3, 30 * 3);
    uint8_t *t24 = W_PX(px, AW3, 80 * 3, 45 * 3);
    double y0 = 0.2126 * t0[0] + 0.7152 * t0[1] + 0.0722 * t0[2];
    double y1 = 0.2126 * t1[0] + 0.7152 * t1[1] + 0.0722 * t1[2];
    double y2 = 0.2126 * t2[0] + 0.7152 * t2[1] + 0.0722 * t2[2];
    double y9 = 0.2126 * t9[0] + 0.7152 * t9[1] + 0.0722 * t9[2];
    double y24 = 0.2126 * t24[0] + 0.7152 * t24[1] + 0.0722 * t24[2];
    printf("win_gpu: v8_slider(%s) blue_peak=%.2f@dx=%.2f blue_h55=%.2f grey_peak=%.2f@dx=%.2f grey_h55=%.2f prof5=(%.0f,%.0f,%.0f,%.0f,%.0f)\n",
           is_light ? "light" : "dark", max_bh, peak_dx, h_55, max_gh, grey_peak_dx, grey_h55, y0, y1, y2, y9, y24);
    CHECK(max_bh >= 9.5 && max_bh <= 12.5);
    CHECK(peak_dx >= 0.33 && peak_dx <= 1.50);
    CHECK(h_55 >= 5.6 && h_55 <= 6.4);
    CHECK(max_gh >= 9.5 && max_gh <= 12.5);
    CHECK(grey_peak_dx >= 0.33 && grey_peak_dx <= 1.50);
    CHECK(grey_h55 >= 5.6 && grey_h55 <= 6.4);
    CHECK((int)c_l[2] - (int)c_l[0] > 100 && (int)c_r[2] - (int)c_r[0] < 20);
    CHECK((int)c_top[2] - (int)c_top[0] < 20 && (int)c_bot[2] - (int)c_bot[0] < 20);
    CHECK(y1 > y0 && y2 > y9 && y9 < y24);
    free(px);
  }

  // V8a2: Horizontal-stripe vertical monotonicity (zero folding)
  {
    double st[42 * MB_INST];
    fill_p0_rect(st, 0, 0, VW, VH, 0, 0.0, 0.0, 0.0, 1.0, 0);
    for (int i = 0; i < 40; i++) {
      double v = (i - 12.0) / 16.0;
      if (v < 0.0) v = 0.0;
      if (v > 1.0) v = 1.0;
      fill_p0_rect(st + (i + 1) * MB_INST, 0, 20 + i, VW, 1, 0, 1.0 - v, 0.0, v, 1.0, 0);
    }
    fill_p0_rect(st + 41 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, 0.0, -52.0);
    st[41 * MB_INST + 4] = 19.0; st[41 * MB_INST + 6] = 1.0; st[41 * MB_INST + 7] = -16.0;
    st[41 * MB_INST + 12] = 1.0; st[41 * MB_INST + 13] = 9.0; st[41 * MB_INST + 15] = 1.0; st[41 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(st, 42, 0.0, 0.0, 0.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      int xpx = (int)(51.85 * 3);
      int prev = -1000, mono_ok = 1;
      for (int ypx = 36 * 3; ypx <= 44 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, xpx, ypx);
        int cur = (int)c[2] - (int)c[0];
        if (prev > -999 && cur < prev - 6) mono_ok = 0;
        prev = cur;
      }
      CHECK(mono_ok);
      free(px);
    }
  }

  // V8b: 124x48pt dropRole=0 magnifier unaffected + Role 0 real zoom (1.18) contact-edge push
  {
    double mg[3 * MB_INST];
    fill_p0_rect(mg, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(mg + MB_INST, 0, 37, VW, 6, 0, 0.0, 136.0 / 255.0, 1.0, 1.0, 0);
    fill_p0_rect(mg + 2 * MB_INST, 18, 16, 124, 48, 6, 1.0, 1.0, 1.0, 0.0, -53.0);
    mg[2 * MB_INST + 4] = 24.0; mg[2 * MB_INST + 6] = 1.0; mg[2 * MB_INST + 7] = 0.0;
    mg[2 * MB_INST + 12] = 1.0; mg[2 * MB_INST + 13] = 8.0; mg[2 * MB_INST + 15] = 1.0; mg[2 * MB_INST + 21] = 3.0;
    uint8_t *px = render_rgba_pixels_of(mg, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      int cnt = 0;
      for (int ypx = 16 * 3; ypx < 64 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, 19 * 3, ypx);
        if ((int)c[2] - (int)c[0] > 100) cnt++;
      }
      printf("win_gpu: v8_magnifier_role0 h(1.0)=%.2f\n", (double)cnt / 3.0);
      CHECK((double)cnt / 3.0 < 7.0);
      free(px);
    }
  }
  {
    double zm[3 * MB_INST];
    fill_p0_rect(zm, 0, 0, VW, VH, 0, 1.0, 0.0, 0.0, 1.0, 0);
    fill_p0_rect(zm + MB_INST, 0, 0, 55.2, VH, 0, 0.0, 1.0, 0.0, 1.0, 0);
    fill_p0_rect(zm + 2 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, 0.0, -59.0);
    zm[2 * MB_INST + 4] = 19.0; zm[2 * MB_INST + 6] = 1.0; zm[2 * MB_INST + 7] = -0.18;
    zm[2 * MB_INST + 12] = 1.0; zm[2 * MB_INST + 13] = 8.0; zm[2 * MB_INST + 15] = 1.0; zm[2 * MB_INST + 21] = 8.0;
    uint8_t *px = render_rgba_pixels_of(zm, 3, 1.0, 0.0, 0.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *edge = W_PX(px, AW3, 51 * 3, 40 * 3);
      printf("win_gpu: v8_role0_zoom118_contact rgb=(%u,%u,%u)\n", edge[0], edge[1], edge[2]);
      CHECK((int)edge[1] > (int)edge[0] + 40);
      free(px);
    }
  }

  // V9a: Switch ON @ 3x
  {
    double sw[3 * MB_INST];
    fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(sw + MB_INST, 40, 26, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
    sw[MB_INST + 4] = 14.0;
    fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -54.0);
    sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
    sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *r0 = W_PX(px, AW3, 80 * 3, 21 * 3 + 0);
      uint8_t *r1 = W_PX(px, AW3, 80 * 3, 21 * 3 + 1);
      uint8_t *r2 = W_PX(px, AW3, 80 * 3, 21 * 3 + 2);
      int gr0 = (int)r0[1] - (int)r0[0], gr1 = (int)r1[1] - (int)r1[0], gr2 = (int)r2[1] - (int)r2[0];
      int core_px = 0, first_core_y = -1;
      for (int ypx = 21 * 3 + 2; ypx < 59 * 3; ypx++) {
        uint8_t *c = W_PX(px, AW3, 80 * 3, ypx);
        if ((int)c[1] - (int)c[0] > 60) {
          if (first_core_y < 0) first_core_y = ypx;
          core_px++;
        }
      }
      double moat_top_pt = first_core_y >= 0 ? (double)(first_core_y - (21 * 3 + 2)) / 3.0 : 0.0;
      uint8_t *tip = W_PX(px, AW3, (int)(111.5 * 3), 40 * 3);
      int tip_gr = (int)tip[1] - (int)tip[0];
      printf("win_gpu: v9_switch_on_3x tir=(%d,%d,%d) core=%.2f moat_top=%.2f tip_gr=%d\n",
             gr0, gr1, gr2, (double)core_px / 3.0, moat_top_pt, tip_gr);
      CHECK(gr0 < 15 && gr1 > 60 && gr2 < 15);
      CHECK((double)core_px / 3.0 >= 20.0 && (double)core_px / 3.0 <= 22.5);
      CHECK(moat_top_pt >= 6.5);
      CHECK(tip_gr < 15);
      free(px);
    }
  }

  // V9b: Switch OFF @ 3x + right-cap inward horizontal profile
  {
    double sw[4 * MB_INST];
    fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(sw + MB_INST, 40, 26, 63, 28, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 1.0, 0);
    sw[MB_INST + 4] = 14.0;
    fill_p0_rect(sw + 2 * MB_INST, 85.0, 26.0, 2.0, 28.0, 0, 0.0, 136.0 / 255.0, 1.0, 1.0, 0);
    fill_p0_rect(sw + 3 * MB_INST, 30.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -55.0);
    sw[3 * MB_INST + 4] = 19.2; sw[3 * MB_INST + 6] = 1.0; sw[3 * MB_INST + 7] = -32.0;
    sw[3 * MB_INST + 12] = 1.0; sw[3 * MB_INST + 13] = 9.0; sw[3 * MB_INST + 15] = 1.0; sw[3 * MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sw, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *core_c = W_PX(px, AW3, 60 * 3, 40 * 3);
      uint8_t *moat_c = W_PX(px, AW3, 60 * 3, 25 * 3);
      uint8_t *h0 = W_PX(px, AW3, 60 * 3, 21 * 3);
      uint8_t *rm = W_PX(px, AW3, 60 * 3, 21 * 3 + 2);
      uint8_t *rcap = W_PX(px, AW3, (int)(88.6 * 3), 40 * 3);
      uint8_t *rtir = W_PX(px, AW3, (int)(89.3 * 3), 40 * 3);
      int rcap_br = (int)rcap[2] - (int)rcap[0];
      int rtir_br = (int)rtir[2] - (int)rtir[0];
      printf("win_gpu: v9_switch_off_3x core=%u moat=%u rim=%u h0=%u rcap_br=%d rtir_br=%d\n",
             core_c[0], moat_c[0], rm[0], h0[0], rcap_br, rtir_br);
      CHECK(core_c[0] > moat_c[0] + 15 && rm[0] > h0[0]);
      CHECK(rcap_br < 20 && rtir_br > 80);
      free(px);
    }
  }

  // V9b2: Switch half-press p = 0.5 / 0.6 / 1.0
  {
    double ps[3] = {0.5, 0.6, 1.0};
    int red_rows[3] = {0, 0, 0};
    for (int pi = 0; pi < 3; pi++) {
      double p = ps[pi];
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 40, 20, 80, 7, 0, 1.0, 0.0, 0.0, 1.0, 0);
      fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-60 - pi));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 12] = p; sw[2 * MB_INST + 13] = 9.0 * p; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0 * p;
      uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
      CHECK(px != NULL);
      if (px) {
        for (int ypx = 27 * 3; ypx < 38 * 3; ypx++) {
          uint8_t *c = W_PX(px, AW3, 80 * 3, ypx);
          if ((int)c[0] - (int)c[2] > 80) red_rows[pi]++;
        }
        free(px);
      }
    }
    printf("win_gpu: v9_switch_half_press red_shift_px=(p0.5:%d, p0.6:%d, p1.0:%d)\n",
           red_rows[0], red_rows[1], red_rows[2]);
    CHECK(red_rows[0] >= 4 && red_rows[1] >= red_rows[0] && red_rows[2] > red_rows[1]);
  }

  // V9c: Light Segmented Prism @ 3x (top/bot cyan, left/right amber, dark-stroke text ROI chroma-0 invariance)
  {
    double sg[4 * MB_INST];
    fill_p0_rect(sg, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 1.0, 0);
    fill_p0_rect(sg + MB_INST, 60.0, 34.0, 4.0, 12.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 1.0, 0);
    fill_p0_rect(sg + 2 * MB_INST, 78.0, 36.0, 22.0, 3.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 1.0, 0);
    fill_p0_rect(sg + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -56.0);
    sg[3 * MB_INST + 4] = 22.5; sg[3 * MB_INST + 6] = 1.0; sg[3 * MB_INST + 7] = -48.0;
    sg[3 * MB_INST + 12] = 1.0; sg[3 * MB_INST + 13] = 9.0; sg[3 * MB_INST + 15] = 1.0;
    sg[3 * MB_INST + 21] = 9.0; sg[3 * MB_INST + 22] = 0.04;
    uint8_t *px = render_rgba_pixels_of(sg, 4, 1.0, 1.0, 1.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *top = W_PX(px, AW3, 80 * 3, (int)(18.4 * 3));
      uint8_t *bot = W_PX(px, AW3, 80 * 3, (int)(61.6 * 3));
      uint8_t *lft = W_PX(px, AW3, (int)(25.9 * 3), 40 * 3);
      uint8_t *rgt = W_PX(px, AW3, (int)(134.1 * 3), 40 * 3);
      printf("win_gpu: v9_seg_light top B-R=%d bot B-R=%d lft R-B=%d rgt R-B=%d\n",
             (int)top[2] - (int)top[0], (int)bot[2] - (int)bot[0],
             (int)lft[0] - (int)lft[2], (int)rgt[0] - (int)rgt[2]);
      CHECK((int)top[2] - (int)top[0] >= 10);
      CHECK((int)bot[2] - (int)bot[0] >= 10);
      CHECK((int)lft[0] - (int)lft[2] >= 20);
      CHECK((int)rgt[0] - (int)rgt[2] >= 20);
      sg[3 * MB_INST + 20] = -561.0;
      sg[3 * MB_INST + 22] = 0.0;
      uint8_t *px0 = render_rgba_pixels_of(sg, 4, 1.0, 1.0, 1.0, 3.0, AW3, AH3);
      CHECK(px0 != NULL);
      if (px0) {
        int text_max_diff = 0;
        for (int py = 32 * 3; py <= 48 * 3; py++) {
          for (int px_i = 55 * 3; px_i <= 105 * 3; px_i++) {
            uint8_t *a = W_PX(px, AW3, px_i, py);
            uint8_t *b = W_PX(px0, AW3, px_i, py);
            for (int ch = 0; ch < 3; ch++) {
              int df = abs((int)a[ch] - (int)b[ch]);
              if (df > text_max_diff) text_max_diff = df;
            }
          }
        }
        printf("win_gpu: v9_seg_text_roi_diff=%d\n", text_max_diff);
        CHECK(text_max_diff == 0);
        free(px0);
      }
      free(px);
    }
  }

  // V9e: Switch uniform green center + blue-track swap + OFF r9->r4.5 + 5-level press
  {
    double sg[2 * MB_INST];
    fill_p0_rect(sg, 0, 0, VW, VH, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
    fill_p0_rect(sg + MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -562.0);
    sg[MB_INST + 4] = 19.2; sg[MB_INST + 6] = 1.0; sg[MB_INST + 7] = -32.0;
    sg[MB_INST + 12] = 1.0; sg[MB_INST + 13] = 9.0; sg[MB_INST + 15] = 1.0; sg[MB_INST + 21] = 9.0;
    uint8_t *px = render_rgba_pixels_of(sg, 2, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px != NULL);
    if (px) {
      uint8_t *c = W_PX(px, AW3, (int)lround(82.5 * 3), (int)lround(40.2 * 3));
      printf("win_gpu: v9_switch_green_ctr rgb=(%u,%u,%u) exp=(57,218,97)\n", c[0], c[1], c[2]);
      CHECK(abs((int)c[0] - 57) <= 2 && abs((int)c[1] - 218) <= 2 && abs((int)c[2] - 97) <= 2);
      free(px);
    }
    double sb[3 * MB_INST];
    fill_p0_rect(sb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(sb + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 0.0, 122.0 / 255.0, 1.0, 1.0, 0);
    sb[MB_INST + 4] = 14.0;
    sb[MB_INST + 36] = 14.0; sb[MB_INST + 37] = 14.0; sb[MB_INST + 38] = 14.0; sb[MB_INST + 39] = 14.0;
    fill_p0_rect(sb + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, -5621.0);
    sb[2 * MB_INST + 4] = 19.2; sb[2 * MB_INST + 6] = 1.0; sb[2 * MB_INST + 7] = -32.0;
    sb[2 * MB_INST + 12] = 1.0; sb[2 * MB_INST + 13] = 9.0; sb[2 * MB_INST + 15] = 1.0; sb[2 * MB_INST + 21] = 9.0;
    uint8_t *pxb = render_rgba_pixels_of(sb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(pxb != NULL);
    if (pxb) {
      uint8_t *cb = W_PX(pxb, AW3, 80 * 3, 21 * 3 + 1);
      printf("win_gpu: v9_switch_blue_caustic rgb=(%u,%u,%u) B-R=%d\n", cb[0], cb[1], cb[2], (int)cb[2] - (int)cb[0]);
      CHECK((int)cb[2] - (int)cb[0] >= 100 && cb[2] > cb[1]);
      free(pxb);
    }
    int off_moat[2] = {0, 0};
    double refs[2] = {9.0, 4.5};
    for (int ri = 0; ri < 2; ri++) {
      double so[3 * MB_INST];
      fill_p0_rect(so, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(so + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 1.0, 0);
      so[MB_INST + 4] = 14.0;
      so[MB_INST + 36] = 14.0; so[MB_INST + 37] = 14.0; so[MB_INST + 38] = 14.0; so[MB_INST + 39] = 14.0;
      fill_p0_rect(so + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-5622 - ri));
      so[2 * MB_INST + 4] = 19.2; so[2 * MB_INST + 6] = 1.0; so[2 * MB_INST + 7] = -32.0;
      so[2 * MB_INST + 12] = 1.0; so[2 * MB_INST + 13] = 9.0; so[2 * MB_INST + 15] = 1.0; so[2 * MB_INST + 21] = refs[ri];
      uint8_t *pxo = render_rgba_pixels_of(so, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
      CHECK(pxo != NULL);
      if (pxo) {
        int best = 0, cur = 0;
        for (int py = 21 * 3 + 2; py < 40 * 3; py++) {
          uint8_t *c0 = W_PX(pxo, AW3, 80 * 3, py);
          if (c0[0] < 95) { cur++; if (cur > best) best = cur; } else cur = 0;
        }
        off_moat[ri] = best;
        free(pxo);
      }
    }
    printf("win_gpu: v9_switch_off_moat r9=%dpx r4.5=%dpx\n", off_moat[0], off_moat[1]);
    CHECK(off_moat[0] > off_moat[1] && off_moat[1] >= 1);
    double ps[5] = {0.0, 0.25, 0.50, 0.75, 1.0};
    int areas[5] = {0, 0, 0, 0, 0};
    uint8_t *px_rest = NULL;
    for (int pi = 0; pi < 5; pi++) {
      double p = ps[pi];
      double sc5[4 * MB_INST];
      fill_p0_rect(sc5, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sc5 + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
      sc5[MB_INST + 4] = 14.0;
      sc5[MB_INST + 36] = 14.0; sc5[MB_INST + 37] = 14.0; sc5[MB_INST + 38] = 14.0; sc5[MB_INST + 39] = 14.0;
      double cw = 37.0 * (1.0 + 0.60 * p), ch = 24.0 * (1.0 + 0.60 * p);
      double cx0 = 82.5 - cw * 0.5, cy0 = 40.0 - ch * 0.5;
      double cap_a = 1.0 - 1.8 * p;
      if (cap_a < 0.0) cap_a = 0.0;
      if (cap_a > 1.0) cap_a = 1.0;
      fill_p0_rect(sc5 + 2 * MB_INST, cx0, cy0, cw, ch, 0, 1.0, 1.0, 1.0, cap_a, 0);
      sc5[2 * MB_INST + 4] = ch * 0.5;
      sc5[2 * MB_INST + 36] = ch * 0.5; sc5[2 * MB_INST + 37] = ch * 0.5;
      sc5[2 * MB_INST + 38] = ch * 0.5; sc5[2 * MB_INST + 39] = ch * 0.5;
      int ninst = 3;
      if (p > 0.001) {
        fill_p0_rect(sc5 + 3 * MB_INST, cx0, cy0, cw, ch, 6, 1.0, 1.0, 1.0, 0.0, (double)(-5625 - pi));
        sc5[3 * MB_INST + 4] = ch * 0.5; sc5[3 * MB_INST + 6] = 1.0; sc5[3 * MB_INST + 7] = -32.0;
        sc5[3 * MB_INST + 12] = p; sc5[3 * MB_INST + 13] = 9.0 * p;
        sc5[3 * MB_INST + 15] = p; sc5[3 * MB_INST + 21] = 9.0 * p;
        ninst = 4;
      }
      uint8_t *px5 = render_rgba_pixels_of(sc5, ninst, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
      CHECK(px5 != NULL);
      if (px5) {
        if (pi == 0) {
          px_rest = px5;
          areas[0] = 0;
        } else if (px_rest) {
          int cnt = 0;
          for (int py = 21 * 3; py <= 59 * 3; py += 2) {
            for (int px_i = 53 * 3; px_i <= 112 * 3; px_i += 2) {
              uint8_t *c0 = W_PX(px5, AW3, px_i, py);
              uint8_t *r0 = W_PX(px_rest, AW3, px_i, py);
              int d = abs((int)c0[0] - (int)r0[0]) + abs((int)c0[1] - (int)r0[1]) + abs((int)c0[2] - (int)r0[2]);
              if (d >= 30) cnt++;
            }
          }
          areas[pi] = cnt;
          free(px5);
        } else {
          free(px5);
        }
      }
    }
    free(px_rest);
    printf("win_gpu: v9_switch_5press_delta_area=(%d,%d,%d,%d,%d)\n", areas[0], areas[1], areas[2], areas[3], areas[4]);
    CHECK(areas[0] < areas[1] && areas[1] < areas[2] && areas[2] < areas[3] && areas[3] < areas[4]);
  }

  // V9f: Role 4 Tab icon bevel gate (FIXED refract=9.0, Role 4 -64; icon at x_right-6.7pt vs empty; |y-cy|=0.42*h diff==0)
  {
    double tb[4 * MB_INST];
    fill_p0_rect(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(tb + MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -563.0);
    tb[MB_INST + 4] = 22.5; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = -64.0;
    tb[MB_INST + 12] = 1.0; tb[MB_INST + 13] = 9.0; tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 9.0;
    uint8_t *px_empty = render_rgba_pixels_of(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    fill_p0_rect(tb + MB_INST, 127.3, 35.0, 2.0, 10.0, 0, 1.0, 0.55, 0.0, 1.0, 0);
    fill_p0_rect(tb + 2 * MB_INST, 117.0, 56.0, 2.0, 6.0, 0, 1.0, 0.55, 0.0, 1.0, 0);
    fill_p0_rect(tb + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, 0.0, -564.0);
    tb[3 * MB_INST + 4] = 22.5; tb[3 * MB_INST + 6] = 1.0; tb[3 * MB_INST + 7] = -64.0;
    tb[3 * MB_INST + 12] = 1.0; tb[3 * MB_INST + 13] = 9.0; tb[3 * MB_INST + 15] = 1.0; tb[3 * MB_INST + 21] = 9.0;
    uint8_t *px_icon = render_rgba_pixels_of(tb, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, AW3, AH3);
    CHECK(px_empty != NULL && px_icon != NULL);
    if (px_empty && px_icon) {
      uint8_t *a_mid = W_PX(px_empty, AW3, 400, 120);
      uint8_t *b_mid = W_PX(px_icon, AW3, 400, 120);
      int mid_delta = abs((int)b_mid[0] - (int)a_mid[0]) + abs((int)b_mid[1] - (int)a_mid[1]);
      uint8_t *a_out = W_PX(px_empty, AW3, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      uint8_t *b_out = W_PX(px_icon, AW3, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      int out_diff = 0;
      for (int ch = 0; ch < 3; ch++) {
        int df = abs((int)b_out[ch] - (int)a_out[ch]);
        if (df > out_diff) out_diff = df;
      }
      printf("win_gpu: v9_tab_icon_bevel mid_delta=%d out_diff=%d\n", mid_delta, out_diff);
      CHECK(mid_delta >= 40 && out_diff == 0);
    }
    free(px_empty);
    free(px_icon);
  }

  // V9g: Role 4 Tab bevelGate outer falloff regression (no un-refracted ghost at inward=10pt)
  {
    double tg[3 * MB_INST];
    fill_p0_rect(tg, 0, 0, VW, VH, 0, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 1.0, 0);
    fill_p0_rect(tg + MB_INST, 41.5, 8.0, 2.0, 64.0, 0, 90.0 / 255.0, 90.0 / 255.0, 90.0 / 255.0, 1.0, 0);
    fill_p0_rect(tg + 2 * MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, 0.0, -565.0);
    tg[2 * MB_INST + 4] = 31.75; tg[2 * MB_INST + 6] = 1.0; tg[2 * MB_INST + 7] = -64.0;
    tg[2 * MB_INST + 12] = 1.0; tg[2 * MB_INST + 13] = 9.0; tg[2 * MB_INST + 15] = 1.0; tg[2 * MB_INST + 21] = 9.0;
    uint8_t *pxg = render_rgba_pixels_of(tg, 3, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 3.0, AW3, AH3);
    CHECK(pxg != NULL);
    if (pxg) {
      uint8_t *co = W_PX(pxg, AW3, 127, 120);
      double l_orig = 0.2126 * co[0] + 0.7152 * co[1] + 0.0722 * co[2];
      double min_l = 1e9;
      for (int px_i = 132; px_i <= 136; px_i++) {
        uint8_t *cr = W_PX(pxg, AW3, px_i, 120);
        double lr = 0.2126 * cr[0] + 0.7152 * cr[1] + 0.0722 * cr[2];
        if (lr < min_l) min_l = lr;
      }
      printf("win_gpu: v9_tab_no_ghost orig_L=%.1f refr_min_L=%.1f\n", l_orig, min_l);
      CHECK(l_orig > 220.0 && min_l < 170.0);
      free(pxg);
    }
  }

  // V9a2: Switch ON @ 2x phase-shifted integrated green mass
  {
    const int AW2 = VW * 2, AH2 = VH * 2;
    for (int ph = 0; ph < 2; ph++) {
      double yoff = ph * 0.25;
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 40, 26 + yoff, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
      sw[MB_INST + 4] = 14.0;
      fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0 + yoff, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-57 - ph));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
      uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 2.0, AW2, AH2);
      CHECK(px != NULL);
      if (px) {
        int gsum = 0;
        for (int dy = 0; dy < 3; dy++) {
          uint8_t *c = W_PX(px, AW2, 80 * 2, 21 * 2 + dy);
          int d = (int)c[1] - (int)c[0];
          if (d > 0) gsum += d;
        }
        printf("win_gpu: v9_switch_on_2x phase=%d green_mass=%d\n", ph, gsum);
        CHECK(gsum > 40);
        free(px);
      }
    }
  }

  // V10: Regular Glass Light Parabolic AA (@2x, R=24pt)
  {
    const int AW2 = VW * 2, AH2 = VH * 2;
    double rg[2 * MB_INST];
    fill_p0_rect(rg, 0, 0, VW, VH, 0, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 1.0, 0);
    fill_p0_rect(rg + MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, 0.40, -70.0);
    rg[MB_INST + 4] = 24.0; rg[MB_INST + 6] = 1.0; rg[MB_INST + 7] = 0.0;
    rg[MB_INST + 12] = 0.6; rg[MB_INST + 13] = 14.0; rg[MB_INST + 15] = 1.0; rg[MB_INST + 21] = 20.0;
    uint8_t *px = render_rgba_pixels_of(rg, 2, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 2.0, AW2, AH2);
    CHECK(px != NULL);
    if (px) {
      double mins[64];
      int n = 0;
      for (int py = 20 + 4; py <= 20 + 44; py++) {
        double rm = 1e9;
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          uint8_t *c = W_PX(px, AW2, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < rm) rm = L;
        }
        mins[n++] = rm;
      }
      double max_d2 = 0.0;
      for (int i = 1; i < n - 1; i++) {
        double d2 = fabs(mins[i - 1] - 2.0 * mins[i] + mins[i + 1]);
        if (d2 > max_d2) max_d2 = d2;
      }
      double side_lmin = 1e9;
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 2; xpx++) {
        uint8_t *c = W_PX(px, AW2, xpx, 40 * 2);
        double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (L < side_lmin) side_lmin = L;
      }
      printf("win_gpu: v10_reg_light_2x max_d2=%.2f side_lmin=%.2f\n", max_d2, side_lmin);
      CHECK(max_d2 <= 14.0);
      CHECK(side_lmin >= 212.0 && side_lmin <= 232.0);
      free(px);
    }
    double rgd[2 * MB_INST];
    fill_p0_rect(rgd, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
    fill_p0_rect(rgd + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 0x67 / 255.0, -71.0);
    rgd[MB_INST + 4] = 24.0; rgd[MB_INST + 6] = 1.0; rgd[MB_INST + 7] = 0.0;
    rgd[MB_INST + 12] = 0.6; rgd[MB_INST + 13] = 14.0; rgd[MB_INST + 15] = 1.0; rgd[MB_INST + 21] = 20.0;
    uint8_t *pxd = render_rgba_pixels_of(rgd, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 2.0, AW2, AH2);
    CHECK(pxd != NULL);
    if (pxd) {
      uint8_t *dc_mid = W_PX(pxd, AW2, 80 * 2, 40 * 2);
      uint8_t *dc_top = W_PX(pxd, AW2, 80 * 2, 10 * 2 + 1);
      uint8_t *dc_side = W_PX(pxd, AW2, 140 * 2 - 1, 40 * 2);
      double l_mid = 0.2126 * dc_mid[0] + 0.7152 * dc_mid[1] + 0.0722 * dc_mid[2];
      double l_top = 0.2126 * dc_top[0] + 0.7152 * dc_top[1] + 0.0722 * dc_top[2];
      double l_side = 0.2126 * dc_side[0] + 0.7152 * dc_side[1] + 0.0722 * dc_side[2];
      uint64_t dh = 14695981039346656037ULL;
      for (int py = 10 * 2; py <= 10 * 2 + 8; py++) {
        uint8_t *c = W_PX(pxd, AW2, 80 * 2, py);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 1; xpx++) {
        uint8_t *c = W_PX(pxd, AW2, xpx, 40 * 2);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int py = 10 * 2; py <= 10 * 2 + 48; py++) {
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          uint8_t *c = W_PX(pxd, AW2, xpx, py);
          for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
        }
      }
      printf("win_gpu: v10_reg_dark_2x top=%.1f mid=%.1f side=%.1f roi_fnv1a=0x%016llx\n", l_top, l_mid, l_side, (unsigned long long)dh);
      CHECK(dh == 0x80e02702612bc2bbULL);
      CHECK(l_top > l_mid + 5.0);
      CHECK(l_side >= l_mid - 6.0 && l_side <= l_mid + 20.0);
      free(pxd);
    }
  }

  // V11-AA & V11-Wall: Switch ON (Dark & Light, 3x & 2x, shadow-free)
  for (int is_light = 0; is_light <= 1; is_light++) {
    double bg = is_light ? 1.0 : 28.0 / 255.0;
    double bg_b = is_light ? 1.0 : 30.0 / 255.0;
    double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
    double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
    double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
    for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
      int sc = (sc_idx == 0) ? 3 : 2;
      int aw = 120 * sc, ah = 65 * sc;
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, 120, 65, 0, bg, bg, bg_b, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 18.5, 18.0, 63.0, 28.0, 0, tr_r, tr_g, tr_b, 1.0, 0);
      sw[MB_INST + 4] = 14.0;
      sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
      fill_p0_rect(sw + 2 * MB_INST, 31.58, 12.8, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-72 - is_light * 2 - sc_idx));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
      uint8_t *px = render_rgba_pixels_of(sw, 3, bg, bg, bg_b, (double)sc, aw, ah);
      CHECK(px != NULL);
      if (!px) continue;
      int y_lo = (int)ceil((32.0 - 0.52 * 19.2) * sc - 0.5);
      int y_hi = (int)floor((32.0 + 0.52 * 19.2) * sc - 0.5);
      int xl0 = (sc == 3) ? 89 : 58, xl1 = (sc == 3) ? 109 : 74;
      int xr0 = (sc == 3) ? 259 : 170, xr1 = (sc == 3) ? 281 : 188;
      double minL[128], minR[128];
      int n = 0;
      for (int py = y_lo; py <= y_hi; py++) {
        double ml = 1e9, mr = 1e9;
        for (int xpx = xl0; xpx <= xl1; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < ml) ml = L;
        }
        for (int xpx = xr0; xpx <= xr1; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, py);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < mr) mr = L;
        }
        minL[n] = ml; minR[n] = mr; n++;
      }
      double d2L = 0.0, d2R = 0.0;
      for (int i = 1; i < n - 1; i++) {
        double a = fabs(minL[i - 1] - 2.0 * minL[i] + minL[i + 1]);
        double b = fabs(minR[i - 1] - 2.0 * minR[i] + minR[i + 1]);
        if (a > d2L) d2L = a;
        if (b > d2R) d2R = b;
      }
      double lim = (sc == 3) ? (is_light ? 12.0 : 10.0) : (is_light ? 14.0 : 12.0);
      printf("win_gpu: v11_aa(%s %dx [%d..%d]) L=%.2f R=%.2f (lim=%.1f)\n",
             is_light ? "light" : "dark", sc, y_lo, y_hi, d2L, d2R, lim);
      CHECK(d2L <= lim && d2R <= lim);
      if (sc == 3) {
        int cy_px = 32 * 3;
        int rx_min = 271;
        double r_minL = 1e9;
        for (int xpx = 268; xpx <= 272; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, cy_px);
          double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (L < r_minL) { r_minL = L; rx_min = xpx; }
        }
        uint8_t *rc0 = W_PX(px, aw, rx_min, cy_px);
        int r_gr = (int)rc0[1] - (int)rc0[0];
        double l1, l2, l3, l4;
        {
          uint8_t *c1 = W_PX(px, aw, rx_min - 1, cy_px);
          uint8_t *c2 = W_PX(px, aw, rx_min - 2, cy_px);
          uint8_t *c3 = W_PX(px, aw, rx_min - 3, cy_px);
          uint8_t *c4 = W_PX(px, aw, rx_min - 4, cy_px);
          l1 = 0.2126 * c1[0] + 0.7152 * c1[1] + 0.0722 * c1[2];
          l2 = 0.2126 * c2[0] + 0.7152 * c2[1] + 0.0722 * c2[2];
          l3 = 0.2126 * c3[0] + 0.7152 * c3[1] + 0.0722 * c3[2];
          l4 = 0.2126 * c4[0] + 0.7152 * c4[1] + 0.0722 * c4[2];
        }
        int r_mono = (l1 >= r_minL && l2 >= l1 && l3 >= l2 && l4 >= l3);
        int best_gr = -999, best_g = 0;
        for (int xpx = 94; xpx <= 98; xpx++) {
          uint8_t *c = W_PX(px, aw, xpx, cy_px);
          int gr = (int)c[1] - (int)c[0];
          if (gr > best_gr && c[1] >= 125 && c[1] <= 165) { best_gr = gr; best_g = c[1]; }
        }
        printf("win_gpu: v11_wall(%s 3x) r_minL=%.1f@x=%d r_gr=%d wall=(%.1f,%.1f,%.1f,%.1f) r_mono=%d l_emerald=(G=%d,G-R=%d)\n",
               is_light ? "light" : "dark", r_minL, rx_min, r_gr, l1, l2, l3, l4, r_mono, best_g, best_gr);
        if (!is_light) {
          CHECK(r_minL <= 14.0 && r_gr <= 12 && r_mono);
        } else {
          CHECK(r_minL >= 170.0 && r_minL <= 205.0 && r_mono && l4 >= 230.0);
        }
        CHECK(best_gr >= 90 && best_g >= 125 && best_g <= 165);
        {
          double prev_moat = -1.0;
          printf("win_gpu: v9_left_horn_3x(%s)", is_light ? "light" : "dark");
          for (int dx = 6; dx <= 20; dx += 2) {
            int pc = (int)lround((31.58 + dx) * 3.0);
            double dyc = sqrt(fmax(19.2 * 19.2 - fmax(19.2 - dx, 0.0) * fmax(19.2 - dx, 0.0), 0.0));
            int y0 = (int)lround((32.0 - dyc + 1.0) * 3.0);
            int y1 = (int)lround(32.0 * 3.0);
            int best = 0, cur = 0;
            for (int py = y0; py < y1; py++) {
              uint8_t *c = W_PX(px, aw, pc, py);
              if ((int)c[1] - (int)c[0] < 26) { cur++; if (cur > best) best = cur; } else cur = 0;
            }
            double mpt = best / 3.0;
            printf(" dx=%d:%.2f", dx, mpt);
            if (dx == 6 || dx == 8) CHECK(mpt == 0.0);
            if (dx == 10) CHECK(mpt >= 1.5 && mpt <= 4.5);
            if (dx >= 12 && prev_moat >= 0.0) CHECK(mpt >= prev_moat - 0.35 && mpt - prev_moat <= 3.5);
            if (dx == 20) CHECK(mpt >= 7.0);
            prev_moat = mpt;
          }
          printf("\n");
        }
      }
      free(px);
    }
  }

  // V11-Top: Registered 3x & 2x top-wall at 5.00pt & 5.20pt (Dark & Light)
  {
    double offs[2] = { 5.00, 5.20 };
    for (int is_light = 0; is_light <= 1; is_light++) {
      double bg = is_light ? 1.0 : 28.0 / 255.0;
      double bg_b = is_light ? 1.0 : 30.0 / 255.0;
      double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
      double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
      double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
      for (int oi = 0; oi < 2; oi++) {
        double off = offs[oi], th = 38.4 - 2.0 * off;
        for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
          int sc = (sc_idx == 0) ? 3 : 2;
          int aw = VW * sc, ah = VH * sc;
          double sw[3 * MB_INST];
          fill_p0_rect(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 1.0, 0);
          fill_p0_rect(sw + MB_INST, 40.0, 21.0 + off, 63.0, th, 0, tr_r, tr_g, tr_b, 1.0, 0);
          sw[MB_INST + 4] = th * 0.5;
          sw[MB_INST + 36] = th * 0.5; sw[MB_INST + 37] = th * 0.5; sw[MB_INST + 38] = th * 0.5; sw[MB_INST + 39] = th * 0.5;
          fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, 0.0, (double)(-80 - is_light * 4 - oi * 2 - sc_idx));
          sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
          sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0;
          uint8_t *px = render_rgba_pixels_of(sw, 3, bg, bg, bg_b, (double)sc, aw, ah);
          CHECK(px != NULL);
          if (!px) continue;
          uint8_t *r0 = W_PX(px, aw, 80 * sc, 21 * sc + 0);
          uint8_t *r1 = W_PX(px, aw, 80 * sc, 21 * sc + 1);
          uint8_t *r2 = W_PX(px, aw, 80 * sc, 21 * sc + 2);
          int gr0 = (int)r0[1] - (int)r0[0], gr1 = (int)r1[1] - (int)r1[0], gr2 = (int)r2[1] - (int)r2[0];
          double l0 = 0.2126 * r0[0] + 0.7152 * r0[1] + 0.0722 * r0[2];
          double l2 = 0.2126 * r2[0] + 0.7152 * r2[1] + 0.0722 * r2[2];
          printf("win_gpu: v11_top(%s %dx @%.2fpt) r0=(G-R=%d,L=%.0f) r1=(G-R=%d) r2=(G-R=%d,L=%.0f)\n",
                 is_light ? "light" : "dark", sc, off, gr0, l0, gr1, gr2, l2);
          if (sc == 3) {
            if (!is_light) {
              CHECK(gr0 < 15 && l0 <= 35.0 && gr1 >= 100 && gr2 < 15 && l2 >= 75.0);
            } else {
              CHECK(gr0 < 15 && l0 >= 180.0 && l0 <= 215.0 && gr1 >= 95 && gr2 < 15 && l2 >= 245.0);
            }
          } else {
            CHECK(gr1 >= 70 && gr2 < 15);
          }
          free(px);
        }
      }
    }
  }
  // V9h: Switch ON held glassFrost C0 continuity (0 -> eps, 0.108->0.110 veil, 0.127->0.129 blur, 0.60 frosted)
  {
    static const double frosts[8] = { 0.0, 0.0001, 0.00011, 0.108, 0.110, 0.127, 0.129, 0.60 };
    int aw = VW * 3, ah = VH * 3;
    uint8_t *px0 = NULL, *px_prev = NULL;
    int max_d_eps = 0, max_d_veil = 0, max_d_blur = 0;
    int c0_r = 0, c0_g = 0, c60_r = 0, c60_g = 0;
    for (int fi = 0; fi < 8; fi++) {
      double fr = frosts[fi];
      double alpha = 0.0, slot7 = -32.0, refr = 9.0;
      if (fr > 0.0001) {
        double a_frac = 0.94 * fr;
        alpha = round(a_frac * 255.0) / 255.0;
        double bl = (a_frac <= 0.12) ? 0.0 : 14.0 * ((a_frac - 0.12) / 0.88) * 0.5;
        slot7 = (bl <= 0.0) ? -32.0 : bl;
        refr = 9.0 * (1.0 - 0.55 * fr);
      }
      double sw[3 * MB_INST];
      fill_p0_rect(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 1.0, 0);
      fill_p0_rect(sw + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 1.0, 0);
      sw[MB_INST + 4] = 14.0;
      sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
      fill_p0_rect(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, alpha, (double)(-90 - fi));
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = slot7;
      sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0; sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = refr;
      uint8_t *px = render_rgba_pixels_of(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 3.0, aw, ah);
      CHECK(px != NULL);
      if (!px) continue;
      if (fi == 0) {
        px0 = px;
        uint8_t *c = W_PX(px, aw, 82 * 3, 40 * 3);
        c0_r = c[0]; c0_g = c[1];
      } else {
        if (fi == 2 && px0) {
          for (int py = 21 * 3; py <= 59 * 3; py++) {
            for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
              uint8_t *a = W_PX(px0, aw, xpx, py);
              uint8_t *b = W_PX(px, aw, xpx, py);
              for (int ch = 0; ch < 3; ch++) {
                int d = abs((int)a[ch] - (int)b[ch]);
                if (d > max_d_eps) max_d_eps = d;
              }
            }
          }
        } else if (fi == 3 || fi == 5) {
          free(px_prev);
          px_prev = px;
          px = NULL;
        } else if ((fi == 4 || fi == 6) && px_prev) {
          int md = 0;
          for (int py = 21 * 3; py <= 59 * 3; py++) {
            for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
              uint8_t *a = W_PX(px_prev, aw, xpx, py);
              uint8_t *b = W_PX(px, aw, xpx, py);
              for (int ch = 0; ch < 3; ch++) {
                int d = abs((int)a[ch] - (int)b[ch]);
                if (d > md) md = d;
              }
            }
          }
          if (fi == 4) max_d_veil = md; else max_d_blur = md;
        } else if (fi == 7) {
          uint8_t *c = W_PX(px, aw, 82 * 3, 40 * 3);
          c60_r = c[0]; c60_g = c[1];
        }
        free(px);
      }
    }
    free(px0);
    free(px_prev);
    printf("win_gpu: v9_switch_frost_continuity max_d_eps=%d max_d_veil=%d max_d_blur=%d ctr0=(%d,%d) ctr60=(%d,%d)\n",
           max_d_eps, max_d_veil, max_d_blur, c0_r, c0_g, c60_r, c60_g);
    CHECK(max_d_eps <= 2);
    CHECK(max_d_veil <= 10);
    CHECK(max_d_blur <= 10);
    CHECK(c60_r > c0_r + 25 && (c60_g - c60_r) < (c0_g - c0_r) - 20);
  }
  #undef W_PX
}

int main(void) {
  // 1. Initial values before any frame.
  CHECK(mb_host_gpu_ms() == -1.0);
  CHECK(mb_host_frames_dropped() == 0);

  // 2. Pure dropped-frame boundary logic.
  test_dropped_step_logic();

  // 3. D3D11 timestamp query ring on WARP offscreen device.
  mb_render_init_offscreen(128.0, 128.0, 1.0);
  CHECK(dev != NULL && ctx != NULL && rtv != NULL);
  if (!dev || !ctx || !rtv) return 1;

  static double inst[32 * MB_INST];
  fill_rect_instances(inst, 32);

  for (int i = 0; i < 8; i++) {
    CHECK(submit(inst, 32, 1.0, 1.0, 1.0) == 1);
    ctx->Flush();
  }
  // Poll until WARP finishes queued work (bounded spin with Sleep(1) only in test harness after Flush).
  for (int tries = 0; tries < 50; tries++) {
    gpu_q_poll();
    int any_in_flight = 0;
    for (int i = 0; i < MB_GPU_Q_SLOTS; i++) any_in_flight |= gpu_q[i].in_flight;
    if (!any_in_flight) break;
    Sleep(1);
  }
  if (gpu_q_ok) {
    int any_in_flight = 0;
    for (int i = 0; i < MB_GPU_Q_SLOTS; i++) any_in_flight |= gpu_q[i].in_flight;
    CHECK(any_in_flight == 0);
    // On WARP, timestamp queries normally return >= 0.0 (unless Disjoint=TRUE, in which case -1.0 without crash).
    double gms = mb_host_gpu_ms();
    CHECK(gms >= 0.0 || gms == -1.0);
    printf("win_gpu: warp gpu_ms=%.3f\n", gms);
  } else {
    CHECK(mb_host_gpu_ms() == -1.0);
    printf("win_gpu: timestamp queries unsupported on adapter (graceful fallback)\n");
  }

  // 4. gpu_q_free() cleans up and next submit() re-initializes cleanly.
  gpu_q_free();
  for (int i = 0; i < MB_GPU_Q_SLOTS; i++) {
    CHECK(gpu_q[i].disjoint == NULL && gpu_q[i].ts_begin == NULL && gpu_q[i].ts_end == NULL);
  }
  CHECK(submit(inst, 16, 1.0, 1.0, 1.0) == 1);
  ctx->Flush();
  gpu_q_free();

  // 5. P0 Regular Liquid Glass optics 5+2 numerical vector readback on D3D11 WARP production shader.
  test_p0_liquid_glass_vectors();

  // 6. Commit 2 V8/V9 2D Multi-Pixel ROI gates on D3D11 WARP production shader.
  test_v8_v9_droplet_roi_gates();

  if (failed) return 1;
  printf("win_gpu: ok\n");
  return 0;
}
