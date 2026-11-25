// src/host/win_text.cpp unit tests on Windows:
//   cl.exe -nologo -EHsc -W3 -WX -D_CRT_SECURE_NO_WARNINGS -Isrc/host scripts/win_text_test.cpp \
//     -Foout/text/ -Feout/text/win_text_test.exe \
//     -link dwrite.lib d2d1.lib windowscodecs.lib user32.lib ole32.lib
//   out/text/win_text_test.exe
// Verifies:
// 1. fine_cover_from_sum / fine_downsample_nogrow matches original float rounding for all 0..4080 sums.
// 2. draw_fine with grow <= 0 allocates no float buffers, and with grow > 0 reuses Target::fine_a / fine_g.
// 3. drawn_ahead never blocks when drawing_mask has the requested phase set; marks skip_mask and worker frees safely.
// 4. mb_host_glyphs_ahead and rasterize preheat only 1 phase on first sight, and enqueue remaining phases only on a 2nd
//    distinct subpixel phase.
#define MB_NO_MOONBIT_H 1
#define MB_WIN_AHEAD_NO_THREADS 1
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef wchar_t *moonbit_string_t;
typedef uint8_t *moonbit_bytes_t;
static int32_t test_bytes_len = 0;
static int32_t test_doubles_len = 0;
static int32_t Moonbit_array_length(moonbit_string_t s) { return s ? (int32_t)wcslen(s) : 0; }
static int32_t Moonbit_array_length(moonbit_bytes_t) { return test_bytes_len; }
static int32_t Moonbit_array_length(double *) { return test_doubles_len; }
static moonbit_string_t moonbit_make_string_raw(int32_t len) {
  return (moonbit_string_t)calloc((size_t)(len > 0 ? len + 1 : 1), sizeof(wchar_t));
}

extern "C" {
int mb_atlas_size = 4096;
void mb_atlas_upload(int, int, int, int, const void *) {}
int mb_render_snapshot(const wchar_t *) { return 0; }
void mb_host_request_frame(void) {}
void mb_app_call(void (*fn)(void *), void *arg) { if (fn) fn(arg); }
}

#include "win_text.cpp"

static int failed = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static void test_fine_math_and_reuse(void) {
  // 1. Exhaustive 0..4080 equivalence between fine_cover_from_sum and original float formula.
  for (int sum = 0; sum <= 255 * FINE * FINE; sum++) {
    uint8_t got = fine_cover_from_sum(sum);
    float fsum = (float)sum / 255.0f;
    int fc = (int)(fsum * (255.0f / (FINE * FINE)) + 0.5f);
    uint8_t want = (uint8_t)(fc > 255 ? 255 : fc);
    CHECK(got == want);
  }

  // 2. fine_downsample_nogrow direct check on synthetic 4x4 fine BGRA blocks for all 0..4080 sums.
  uint8_t src[FINE * FINE * 4];
  uint8_t px[4];
  for (int sum = 0; sum <= 255 * FINE * FINE; sum++) {
    int rem = sum;
    for (int i = 0; i < FINE * FINE; i++) {
      int cover = rem > 255 ? 255 : rem;
      rem -= cover;
      uint8_t g = (uint8_t)(255 - cover);
      src[i * 4 + 0] = g;
      src[i * 4 + 1] = g;
      src[i * 4 + 2] = g;
      src[i * 4 + 3] = 255;
    }
    fine_downsample_nogrow(src, FINE * 4, 1, 1, px);
    uint8_t want = fine_cover_from_sum(sum);
    CHECK(px[0] == want && px[1] == want && px[2] == want && px[3] == want);
  }

  // 3. Real DirectWrite draw_fine with grow == 0 (no float buffers allocated) and grow > 0 (reused buffers).
  init();
  CHECK(dw != NULL && d2d != NULL && wic != NULL);
  if (!dw || !d2d || !wic) return;
  text_scale = 2.0;
  wchar_t sH[] = L"H";
  int k = mb_host_text_key(sH, 16.0, 400, 0);
  CHECK(k >= 0);
  IDWriteTextLayout *l = main_layout_for(k);
  CHECK(l != NULL);
  ClusterBounds cb = {};
  measure_bounds(l, 400, &cb);
  int pw = 24, ph = 32;
  uint8_t *out = (uint8_t *)calloc((size_t)pw * ph, 4);
  CHECK(main_target.fine_a == NULL && main_target.fine_g == NULL && main_target.fine_cap == 0);
  CHECK(draw_fine(l, 2.0, cb.x0, cb.y0, 0.0, pw, ph, 0.0, &main_target, out));
  CHECK(main_target.fine_a == NULL && main_target.fine_g == NULL && main_target.fine_cap == 0);
  int nonzero = 0;
  for (int i = 0; i < pw * ph; i++) {
    if (out[i * 4 + 3] > 0) nonzero++;
  }
  CHECK(nonzero > 0);

  // Now with grow > 0: allocates once, then reuses the exact same pointers for same/smaller dimensions.
  CHECK(draw_fine(l, 2.0, cb.x0, cb.y0, 0.0, pw, ph, 0.5, &main_target, out));
  float *pa = main_target.fine_a;
  float *pg = main_target.fine_g;
  size_t pcap = main_target.fine_cap;
  CHECK(pa != NULL && pg != NULL && pcap >= (size_t)(pw * FINE) * (size_t)(ph * FINE));
  CHECK(draw_fine(l, 2.0, cb.x0, cb.y0, 0.0, pw - 2, ph - 2, 0.5, &main_target, out));
  CHECK(main_target.fine_a == pa && main_target.fine_g == pg && main_target.fine_cap == pcap);
  free(out);
}

static void drain_ahead_queues_test(void) {
  for (;;) {
    Ahead *a = NULL;
    bool free_it = false;
    EnterCriticalSection(&ahead_lock);
    if (ahead_first.n > 0) {
      a = queue_pop(&ahead_first);
      free_it = ahead_unref(a);
    } else if (ahead_rest.n > 0) {
      a = queue_pop(&ahead_rest);
      free_it = ahead_unref(a);
    }
    LeaveCriticalSection(&ahead_lock);
    if (!a) break;
    if (free_it) ahead_free(a);
  }
}

static void test_ahead_single_phase_and_nonblocking(void) {
  ahead_forget();
  text_scale = 2.0;
  wchar_t sA[] = L"A";
  int k1 = mb_host_text_key(sA, 16.0, 400, 0);
  CHECK(k1 >= 0);

  // 1. First mb_host_glyphs_ahead queues ONLY the requested phase (sub = 0), nothing in ahead_rest.
  int32_t keys1[1] = {k1 | (0 << 26)};
  mb_host_glyphs_ahead(keys1, 1);
  CHECK(entries[k1].subs_queued == 0x01);
  Ahead *a1 = k1 < ahead_of_cap ? ahead_of[k1] : NULL;
  CHECK(a1 != NULL);
  if (!a1) return;
  CHECK(a1->want_mask == 0x01);
  CHECK(a1->first_mask == 0x01);
  CHECK(ahead_first.n == 1);
  CHECK(ahead_rest.n == 0);

  // 2. Requesting the same phase again still does NOT enqueue phases 1..3.
  mb_host_glyphs_ahead(keys1, 1);
  CHECK(entries[k1].subs_queued == 0x01);
  CHECK(a1->want_mask == 0x01);
  CHECK(ahead_rest.n == 0);

  // 3. Requesting a 2nd distinct phase (sub = 2) enqueues remaining phases {1, 2, 3}, with sub = 2 in first_mask.
  int32_t keys2[1] = {k1 | (2 << 26)};
  mb_host_glyphs_ahead(keys2, 1);
  CHECK(entries[k1].subs_queued == 0x0F);
  CHECK(a1->want_mask == 0x0F);
  CHECK(a1->first_mask == (uint8_t)((1 << 0) | (1 << 2)));
  CHECK(ahead_first.n == 2);
  CHECK(ahead_rest.n == 1);

  // 4. drawn_ahead when drawing_mask has bit 0 set: MUST return false immediately (no block!), mark skip_mask |= 1.
  EnterCriticalSection(&ahead_lock);
  a1->want_mask &= (uint8_t)~0x01;
  a1->first_mask &= (uint8_t)~0x01;
  a1->drawing_mask |= 0x01;
  LeaveCriticalSection(&ahead_lock);

  Drawn d = {};
  CHECK(!drawn_ahead(k1, 0, &d));
  CHECK(d.px == NULL);
  CHECK(ahead_of[k1] == a1);
  EnterCriticalSection(&ahead_lock);
  CHECK((a1->skip_mask & 0x01) != 0);
  CHECK((a1->drawing_mask & 0x01) != 0);
  LeaveCriticalSection(&ahead_lock);

  // Simulate worker finishing phase 0: must discard and free d.px without setting have_mask.
  Drawn worker_d = {};
  worker_d.pw = 4;
  worker_d.ph = 4;
  worker_d.px = (uint8_t *)malloc(4 * 4 * 4);
  ahead_finish_phase(a1, 0, true, worker_d);
  EnterCriticalSection(&ahead_lock);
  CHECK((a1->drawing_mask & 0x01) == 0);
  CHECK((a1->skip_mask & 0x01) == 0);
  CHECK((a1->have_mask & 0x01) == 0);
  CHECK(a1->drawn[0].px == NULL);
  LeaveCriticalSection(&ahead_lock);

  // 5. rasterize() on a fresh glyph at phase 1: draws phase 1 and does NOT enqueue other phases.
  int rest_before = ahead_rest.n;
  wchar_t sB[] = L"B";
  int k2 = mb_host_text_key(sB, 16.0, 400, 0);
  CHECK(k2 >= 0);
  rasterize(k2 | (1 << 26));
  CHECK(entries[k2].subs_queued == (1 << 1));
  CHECK(k2 >= ahead_of_cap || ahead_of[k2] == NULL);
  CHECK(ahead_rest.n == rest_before);

  // 6. rasterize() on the same glyph at a 2nd distinct phase (phase 3): enqueues remaining {0, 2} into ahead_rest.
  rasterize(k2 | (3 << 26));
  CHECK(entries[k2].subs_queued == 0x0F);
  Ahead *a2 = k2 < ahead_of_cap ? ahead_of[k2] : NULL;
  CHECK(a2 != NULL);
  if (a2) {
    CHECK(a2->want_mask == (uint8_t)((1 << 0) | (1 << 2)));
    CHECK(a2->first_mask == 0);
  }
  CHECK(ahead_rest.n == rest_before + 1);

  ahead_forget();
  drain_ahead_queues_test();
  free(held_px);
  held_px = NULL;
  held_key = -1;
}

// Reference probe that unconditionally runs TranslateColorGlyphRun + HasVariations (pre-Perf-43 behavior).
struct RefColorProbe : public IDWriteTextRenderer {
  int color = 0;
  int static_weight = 0;
  STDMETHOD(QueryInterface)(REFIID iid, void **o) override {
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IDWritePixelSnapping) ||
        iid == __uuidof(IDWriteTextRenderer)) {
      *o = this;
      return S_OK;
    }
    *o = NULL;
    return E_NOINTERFACE;
  }
  STDMETHOD_(ULONG, AddRef)() override { return 1; }
  STDMETHOD_(ULONG, Release)() override { return 1; }
  STDMETHOD(IsPixelSnappingDisabled)(void *, BOOL *d) override {
    *d = TRUE;
    return S_OK;
  }
  STDMETHOD(GetCurrentTransform)(void *, DWRITE_MATRIX *m) override {
    *m = {1, 0, 0, 1, 0, 0};
    return S_OK;
  }
  STDMETHOD(GetPixelsPerDip)(void *, FLOAT *p) override {
    *p = 1;
    return S_OK;
  }
  STDMETHOD(DrawGlyphRun)(void *, FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode, DWRITE_GLYPH_RUN const *run,
                          DWRITE_GLYPH_RUN_DESCRIPTION const *desc, IUnknown *) override {
    IDWriteColorGlyphRunEnumerator *runs = NULL;
    if (SUCCEEDED(dw->TranslateColorGlyphRun(x, y, run, desc, mode, NULL, 0, &runs))) {
      color = 1;
      runs->Release();
    }
    IDWriteFontFace5 *f5 = NULL;
    if (run->fontFace && SUCCEEDED(run->fontFace->QueryInterface(__uuidof(IDWriteFontFace5), (void **)&f5))) {
      if (!f5->HasVariations()) {
        int w = (int)f5->GetWeight();
        if (static_weight == 0 || w < static_weight) static_weight = w;
      }
      f5->Release();
    }
    return S_OK;
  }
  STDMETHOD(DrawUnderline)(void *, FLOAT, FLOAT, DWRITE_UNDERLINE const *, IUnknown *) override { return S_OK; }
  STDMETHOD(DrawStrikethrough)(void *, FLOAT, FLOAT, DWRITE_STRIKETHROUGH const *, IUnknown *) override { return S_OK; }
  STDMETHOD(DrawInlineObject)(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override {
    return S_OK;
  }
};

static void target_release_test(Target *t) {
  if (t->white) t->white->Release();
  if (t->black) t->black->Release();
  if (t->rt) t->rt->Release();
  if (t->bitmap) t->bitmap->Release();
  if (t->fine_black) t->fine_black->Release();
  if (t->fine_rt) t->fine_rt->Release();
  if (t->fine_bitmap) t->fine_bitmap->Release();
  free(t->fine_a);
  free(t->fine_g);
  *t = {};
}

static void test_color_probe_and_weight(void) {
  if (!dw || !d2d || !wic) return;
  const WCHAR s_ascii[] = {L'A', 0};
  const WCHAR s_cjk[] = {0x4E2D, 0};
  const WCHAR s_emoji[] = {0xD83D, 0xDE00, 0};
  const WCHAR *samples[3] = {s_ascii, s_cjk, s_emoji};
  const int lens[3] = {1, 1, 2};
  const int weights[3] = {400, 500, 700};
  for (int si = 0; si < 3; si++) {
    for (int wi = 0; wi < 3; wi++) {
      int w = weights[wi];
      IDWriteTextLayout *l1 = make_layout(samples[si], lens[si], 16.0, w, 0);
      IDWriteTextLayout *l2 = make_layout(samples[si], lens[si], 16.0, w, 0);
      CHECK(l1 != NULL && l2 != NULL);
      if (!l1 || !l2) {
        if (l1) l1->Release();
        if (l2) l2->Release();
        continue;
      }
      ClusterBounds cb = {};
      measure_bounds(l1, w, &cb);
      RefColorProbe ref;
      l2->Draw(NULL, &ref, 0, 0);
      CHECK(cb.valid);
      CHECK(cb.color == ref.color);
      if (w > 400 && w < 700) {
        CHECK(cb.static_weight == ref.static_weight);
      } else {
        CHECK(cb.static_weight == 0);
      }
      ClusterBounds ref_cb = cb;
      ref_cb.static_weight = ref.static_weight;
      CHECK(grown_fine(&cb, 16.0, w, 2.0) == grown_fine(&ref_cb, 16.0, w, 2.0));
      l1->Release();
      l2->Release();
    }
  }
}

static void test_lazy_target_and_failure_zero(void) {
  if (!dw || !d2d || !wic) return;
  text_scale = 2.0;
  const WCHAR sM[] = {L'M', 0};
  IDWriteTextLayout *l = make_layout(sM, 1, 16.0, 400, 0);
  CHECK(l != NULL);
  if (!l) return;
  ClusterBounds cb = {};
  measure_bounds(l, 400, &cb);

  // 1. draw_fine path (mono && !ct && size * sc >= 15.0) must NOT initialize t.rt or t.bitmap.
  Target t = {};
  t.d2d = d2d;
  t.wic = wic;
  Drawn d = {};
  draw_cluster(l, &cb, 2.0, 0.0, 16.0, 400, &t, &d);
  CHECK(d.px != NULL && d.pw > 0 && d.ph > 0);
  CHECK(t.rt == NULL && t.bitmap == NULL);
  CHECK(t.fine_rt != NULL);
  CHECK(d.bounds.valid && d.bounds.box_w == cb.box_w && d.bounds.box_h == cb.box_h);
  free(d.px);
  target_release_test(&t);

  // 2. Forced target_ensure failure on non-fine path (size * sc < 15.0, t.d2d == NULL) must zero *d completely.
  Target t_fail = {};
  t_fail.d2d = NULL;
  t_fail.wic = wic;
  Drawn d_fail = {};
  draw_cluster(l, &cb, 1.0, 0.0, 10.0, 400, &t_fail, &d_fail);
  CHECK(d_fail.w == 0.0 && d_fail.h == 0.0 && d_fail.ox == 0.0 && d_fail.oy == 0.0);
  CHECK(d_fail.pw == 0 && d_fail.ph == 0 && d_fail.px == NULL && d_fail.color == 0);
  CHECK(!d_fail.bounds.valid);
  target_release_test(&t_fail);

  // 3. Forced draw_fine failure falling back to target_ensure failure (t.d2d == NULL) must also zero *d completely.
  Target t_fail2 = {};
  t_fail2.d2d = NULL;
  t_fail2.wic = wic;
  Drawn d_fail2 = {};
  draw_cluster(l, &cb, 2.0, 0.0, 16.0, 400, &t_fail2, &d_fail2);
  CHECK(d_fail2.w == 0.0 && d_fail2.h == 0.0 && d_fail2.ox == 0.0 && d_fail2.oy == 0.0);
  CHECK(d_fail2.pw == 0 && d_fail2.ph == 0 && d_fail2.px == NULL && d_fail2.color == 0);
  CHECK(!d_fail2.bounds.valid);
  target_release_test(&t_fail2);
  l->Release();
}

static void test_cross_phase_bounds_reuse(void) {
  if (!dw || !d2d || !wic) return;
  ahead_forget();
  text_scale = 2.0;
  wchar_t sR[] = L"R";
  int k = mb_host_text_key(sR, 16.0, 500, 0);
  CHECK(k >= 0);
  if (k < 0) return;

  // 1. Worker finishes phase 0 and produces Drawn::bounds; rasterize() backfills entries[k].bounds from d.bounds.
  entries[k].bounds = {};
  entries[k].subs_queued = 0;
  int32_t keys0[1] = {k | (0 << 26)};
  mb_host_glyphs_ahead(keys0, 1);
  Ahead *a = k < ahead_of_cap ? ahead_of[k] : NULL;
  CHECK(a != NULL);
  if (!a) return;
  CHECK(!a->bounds.valid);
  IDWriteTextLayout *wl = layout_with(a->text, a->len, a->format, a->typography);
  CHECK(wl != NULL);
  if (!wl) return;
  ClusterBounds wcb = a->bounds;
  measure_bounds(wl, a->weight, &wcb);
  CHECK(wcb.valid && wcb.box_w > 0.0 && wcb.box_h > 0.0);
  Target wt = {};
  wt.d2d = d2d;
  wt.wic = wic;
  Drawn wd = {};
  draw_cluster(wl, &wcb, a->scale, sub_dx(0) / a->scale, a->size, a->weight, &wt, &wd);
  CHECK(wd.px != NULL && wd.bounds.valid);
  EnterCriticalSection(&ahead_lock);
  a->want_mask &= (uint8_t)~0x01;
  a->first_mask &= (uint8_t)~0x01;
  a->drawing_mask |= 0x01;
  LeaveCriticalSection(&ahead_lock);
  ahead_finish_phase(a, 0, true, wd);
  wl->Release();

  CHECK(!entries[k].bounds.valid);
  rasterize(k | (0 << 26));
  CHECK(entries[k].bounds.valid);
  CHECK(entries[k].bounds.box_w == wcb.box_w && entries[k].bounds.box_h == wcb.box_h);
  CHECK(entries[k].bounds.x0 == wcb.x0 && entries[k].bounds.y0 == wcb.y0);
  CHECK(entries[k].bounds.x1 == wcb.x1 && entries[k].bounds.y1 == wcb.y1);
  CHECK(entries[k].bounds.base == wcb.base && entries[k].bounds.static_weight == wcb.static_weight);

  // 2. Next ahead_enqueue_one copies valid e->bounds into a2->bounds by value.
  int32_t keys1[1] = {k | (1 << 26)};
  mb_host_glyphs_ahead(keys1, 1);
  Ahead *a2 = k < ahead_of_cap ? ahead_of[k] : NULL;
  CHECK(a2 != NULL);
  if (a2) {
    CHECK(a2->bounds.valid);
    CHECK(a2->bounds.box_w == wcb.box_w && a2->bounds.box_h == wcb.box_h);
  }

  // 3. All 4 subpixel phases produce byte-identical RGBA and geometry when reusing ClusterBounds + SetMaxWidth/Height.
  Target t_ref = {};
  t_ref.d2d = d2d;
  t_ref.wic = wic;
  for (int s = 0; s < SUB_COUNT; s++) {
    IDWriteTextLayout *l_ref = layout_with(entries[k].len ? pool + entries[k].off : L"", entries[k].len,
                                           format_for(entries[k].size, entries[k].weight, entries[k].style),
                                           typography_for(entries[k].style));
    IDWriteTextLayout *l_reuse = layout_with(entries[k].len ? pool + entries[k].off : L"", entries[k].len,
                                             format_for(entries[k].size, entries[k].weight, entries[k].style),
                                             typography_for(entries[k].style));
    CHECK(l_ref != NULL && l_reuse != NULL);
    if (!l_ref || !l_reuse) {
      if (l_ref) l_ref->Release();
      if (l_reuse) l_reuse->Release();
      continue;
    }
    ClusterBounds cb_ref = {};
    measure_bounds(l_ref, entries[k].weight, &cb_ref);
    ClusterBounds cb_reuse = entries[k].bounds;
    measure_bounds(l_reuse, entries[k].weight, &cb_reuse);
    CHECK(l_reuse->GetMaxWidth() == (FLOAT)cb_reuse.box_w && l_reuse->GetMaxHeight() == (FLOAT)cb_reuse.box_h);
    Drawn d_ref = {}, d_reuse = {};
    draw_cluster(l_ref, &cb_ref, text_scale, sub_dx(s) / text_scale, entries[k].size, entries[k].weight, &t_ref, &d_ref);
    draw_cluster(l_reuse, &cb_reuse, text_scale, sub_dx(s) / text_scale, entries[k].size, entries[k].weight, &wt,
                 &d_reuse);
    CHECK(d_ref.pw == d_reuse.pw && d_ref.ph == d_reuse.ph);
    CHECK(d_ref.w == d_reuse.w && d_ref.h == d_reuse.h && d_ref.ox == d_reuse.ox && d_ref.oy == d_reuse.oy);
    CHECK(d_ref.color == d_reuse.color);
    CHECK(d_ref.px != NULL && d_reuse.px != NULL);
    if (d_ref.px && d_reuse.px && d_ref.pw == d_reuse.pw && d_ref.ph == d_reuse.ph) {
      CHECK(memcmp(d_ref.px, d_reuse.px, (size_t)d_ref.pw * (size_t)d_ref.ph * 4) == 0);
    }
    free(d_ref.px);
    free(d_reuse.px);
    l_ref->Release();
    l_reuse->Release();
  }
  target_release_test(&t_ref);
  target_release_test(&wt);
  ahead_forget();
  drain_ahead_queues_test();
  free(held_px);
  held_px = NULL;
  held_key = -1;
}

static void test_ahead_reenqueue_after_eviction(void) {
  ahead_forget();
  drain_ahead_queues_test();
  text_scale = 2.0;
  wchar_t sE[] = L"E";
  int k = mb_host_text_key(sE, 16.0, 400, 0);
  CHECK(k >= 0);
  if (k < 0) return;

  // 1. Enqueue phase 0, consume & free Ahead (ahead_of[k] == NULL), then re-request phase 0: must re-enqueue and keep subs_queued.
  int32_t k_sub0[1] = {k | (0 << 26)};
  mb_host_glyphs_ahead(k_sub0, 1);
  CHECK(entries[k].subs_queued == 0x01);
  Ahead *a = k < ahead_of_cap ? ahead_of[k] : NULL;
  CHECK(a != NULL);
  if (!a) return;
  Drawn wd = {};
  wd.pw = 2;
  wd.ph = 2;
  wd.px = (uint8_t *)calloc(2 * 2, 4);
  EnterCriticalSection(&ahead_lock);
  a->want_mask = 0;
  a->first_mask = 0;
  a->drawing_mask = 0x01;
  LeaveCriticalSection(&ahead_lock);
  CHECK(ahead_begin_phase(a, 0));
  ahead_finish_phase(a, 0, true, wd);
  Drawn taken = {};
  CHECK(drawn_ahead(k, 0, &taken));
  free(taken.px);
  CHECK(ahead_of[k] == NULL);
  CHECK(entries[k].subs_queued == 0x01);

  mb_host_glyphs_ahead(k_sub0, 1);
  Ahead *a2 = k < ahead_of_cap ? ahead_of[k] : NULL;
  CHECK(a2 != NULL);
  CHECK(entries[k].subs_queued == 0x01);
  if (a2) {
    CHECK(a2->want_mask == 0x01);
    CHECK(a2->first_mask == 0x01);
  }

  // 2. Same Ahead with multiple phases: take phase 0 while other phases remain, then re-request phase 0.
  int32_t k_sub2[1] = {k | (2 << 26)};
  mb_host_glyphs_ahead(k_sub2, 1);
  CHECK(entries[k].subs_queued == 0x0F);
  CHECK(ahead_of[k] == a2);
  if (a2) {
    Drawn wd0 = {};
    wd0.pw = 2;
    wd0.ph = 2;
    wd0.px = (uint8_t *)calloc(2 * 2, 4);
    EnterCriticalSection(&ahead_lock);
    a2->want_mask &= (uint8_t)~0x01;
    a2->first_mask &= (uint8_t)~0x01;
    a2->drawing_mask |= 0x01;
    LeaveCriticalSection(&ahead_lock);
    CHECK(ahead_begin_phase(a2, 0));
    ahead_finish_phase(a2, 0, true, wd0);
    Drawn t0 = {};
    CHECK(drawn_ahead(k, 0, &t0));
    free(t0.px);
    CHECK(ahead_of[k] == a2);
    CHECK((a2->want_mask & 0x01) == 0 && (a2->have_mask & 0x01) == 0);

    // Re-request phase 0 on the still-alive Ahead: bit 0 must be added back to want_mask & first_mask.
    mb_host_glyphs_ahead(k_sub0, 1);
    CHECK((a2->want_mask & 0x01) != 0);
    CHECK((a2->first_mask & 0x01) != 0);

    // 3a. Race Order 1: foreground marks skip_mask -> re-request clears skip_mask BEFORE worker calls ahead_begin_phase ->
    //     ahead_begin_phase returns true -> ahead_finish_phase retains bitmap in have_mask -> drawn_ahead retrieves it.
    EnterCriticalSection(&ahead_lock);
    a2->want_mask &= (uint8_t)~0x01;
    a2->first_mask &= (uint8_t)~0x01;
    a2->drawing_mask |= 0x01;
    LeaveCriticalSection(&ahead_lock);
    Drawn miss1 = {};
    CHECK(!drawn_ahead(k, 0, &miss1));
    EnterCriticalSection(&ahead_lock);
    CHECK((a2->drawing_mask & 0x01) != 0 && (a2->skip_mask & 0x01) != 0);
    LeaveCriticalSection(&ahead_lock);

    mb_host_glyphs_ahead(k_sub0, 1);
    EnterCriticalSection(&ahead_lock);
    CHECK((a2->skip_mask & 0x01) == 0 && (a2->drawing_mask & 0x01) != 0);
    LeaveCriticalSection(&ahead_lock);

    CHECK(ahead_begin_phase(a2, 0));
    Drawn wd_keep1 = {};
    wd_keep1.pw = 3;
    wd_keep1.ph = 3;
    wd_keep1.px = (uint8_t *)malloc(3 * 3 * 4);
    memset(wd_keep1.px, 0x5A, 3 * 3 * 4);
    ahead_finish_phase(a2, 0, true, wd_keep1);
    EnterCriticalSection(&ahead_lock);
    CHECK((a2->have_mask & 0x01) != 0);
    LeaveCriticalSection(&ahead_lock);
    Drawn got1 = {};
    CHECK(drawn_ahead(k, 0, &got1));
    CHECK(got1.pw == 3 && got1.ph == 3 && got1.px != NULL && got1.px[0] == 0x5A);
    free(got1.px);

    // 3b. Race Order 2: foreground marks skip_mask -> worker calls ahead_begin_phase first (returns false and atomically
    //     clears drawing_mask & skip_mask) -> re-request re-adds bit 0 to want_mask & first_mask -> next worker claims
    //     bit 0, ahead_begin_phase returns true, ahead_finish_phase stores bitmap -> drawn_ahead retrieves it.
    mb_host_glyphs_ahead(k_sub0, 1);
    EnterCriticalSection(&ahead_lock);
    a2->want_mask &= (uint8_t)~0x01;
    a2->first_mask &= (uint8_t)~0x01;
    a2->drawing_mask |= 0x01;
    LeaveCriticalSection(&ahead_lock);
    Drawn miss2 = {};
    CHECK(!drawn_ahead(k, 0, &miss2));
    EnterCriticalSection(&ahead_lock);
    CHECK((a2->drawing_mask & 0x01) != 0 && (a2->skip_mask & 0x01) != 0);
    LeaveCriticalSection(&ahead_lock);

    CHECK(!ahead_begin_phase(a2, 0));
    EnterCriticalSection(&ahead_lock);
    CHECK((a2->drawing_mask & 0x01) == 0 && (a2->skip_mask & 0x01) == 0);
    LeaveCriticalSection(&ahead_lock);

    mb_host_glyphs_ahead(k_sub0, 1);
    EnterCriticalSection(&ahead_lock);
    CHECK((a2->want_mask & 0x01) != 0 && (a2->first_mask & 0x01) != 0);
    a2->want_mask &= (uint8_t)~0x01;
    a2->first_mask &= (uint8_t)~0x01;
    a2->drawing_mask |= 0x01;
    LeaveCriticalSection(&ahead_lock);

    CHECK(ahead_begin_phase(a2, 0));
    Drawn wd_keep2 = {};
    wd_keep2.pw = 4;
    wd_keep2.ph = 4;
    wd_keep2.px = (uint8_t *)malloc(4 * 4 * 4);
    memset(wd_keep2.px, 0xA5, 4 * 4 * 4);
    ahead_finish_phase(a2, 0, true, wd_keep2);
    Drawn got2 = {};
    CHECK(drawn_ahead(k, 0, &got2));
    CHECK(got2.pw == 4 && got2.ph == 4 && got2.px != NULL && got2.px[0] == 0xA5);
    free(got2.px);
  }

  // 4. After ahead_forget(), re-requesting phase 0 starts cleanly again.
  ahead_forget();
  drain_ahead_queues_test();
  CHECK(entries[k].subs_queued == 0);
  mb_host_glyphs_ahead(k_sub0, 1);
  CHECK(entries[k].subs_queued == 0x01);
  CHECK(ahead_of[k] != NULL && ahead_of[k]->want_mask == 0x01 && ahead_of[k]->first_mask == 0x01);

  ahead_forget();
  drain_ahead_queues_test();
}

int main(void) {
  test_fine_math_and_reuse();
  test_ahead_single_phase_and_nonblocking();
  test_ahead_reenqueue_after_eviction();
  test_color_probe_and_weight();
  test_lazy_target_and_failure_zero();
  test_cross_phase_bounds_reuse();
  if (failed) return 1;
  printf("win_text: ok\n");
  return 0;
}
