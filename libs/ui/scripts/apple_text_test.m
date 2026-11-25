// src/host/apple_text.m's tests, on Core Text itself: a glyph drawn at each of its four quarter-pixel phases (text.mbt
// glyph_col_sub) has its ink that far right of where it is drawn at none; a line moved across a tenth of a pixel at a
// time keeps the room between its letters as it was, where whole pixels alone (as glyphs were put before the phases)
// made it grow and shrink by a pixel; digits of words said to be one width (style.mbt style_tabular) are, in the
// system's face and in a face given by its file (the first argument, as an app gives Inter: its tnum); and an ellipsis
// that cuts Latin words in a CJK face (ui's shape_widths: the piece with it shaped narrow, style_proportional) leaves
// the letters before it as wide as they were; the glyphs of a page drawn ahead on the queues at every phase as they
// are drawn on the frames' thread, the phases after their first a phase of every glyph in turn.
//   cc -Wall -fobjc-arc -I src/host -I "$MOON_HOME/include" scripts/apple_text_test.m -framework Foundation \
//     -framework AppKit -framework CoreText -framework CoreGraphics -framework ImageIO -o out/apple_text_test &&
//     out/apple_text_test [face.ttf]
#include <stdio.h>
#import <AppKit/AppKit.h>
#import "apple_text.m"

// (what apple_text.m asks of the rest of the host: the Mac's system face, as mac_app.m gives it; an atlas and a
// snapshot it is not asked for here)
CTFontRef mb_platform_font(double size, int weight, int mono) {
  NSFontWeight w = weight >= 700 ? NSFontWeightBold
                   : weight >= 600 ? NSFontWeightSemibold
                   : weight >= 500 ? NSFontWeightMedium
                                   : NSFontWeightRegular;
  NSFont *f = mono ? [NSFont monospacedSystemFontOfSize:size weight:w] : [NSFont systemFontOfSize:size weight:w];
  return (CTFontRef)CFBridgingRetain(f);
}
void mb_atlas_upload(int color, int x, int y, int w, int h, const void *px) {
  (void)color, (void)x, (void)y, (void)w, (void)h, (void)px;
}
void mb_host_request_frame(void) {}
int mb_render_snapshot(const char *path) {
  (void)path;
  return 0;
}
// (a string MoonBit's runtime makes, mb_string_from_ns's: not asked for here, no runtime linked)
moonbit_string_t moonbit_make_string_raw(int32_t n) {
  (void)n;
  return NULL;
}

static int failed;

#define CHECK(c, ...)                                                   \
  do {                                                                  \
    if (!(c)) {                                                         \
      fprintf(stderr, "%s:%d: failed: %s: ", __FILE__, __LINE__, #c);   \
      fprintf(stderr, __VA_ARGS__);                                     \
      fprintf(stderr, "\n");                                            \
      failed = 1;                                                       \
    }                                                                   \
  } while (0)

// `s` shaped as mb_host_shape shapes it: its clusters (start, length, advance, key), how many
static int shape(NSString *s, double size, int weight, int style, double *out, int cap) {
  unichar buf[512];
  NSUInteger n = s.length < 512 ? s.length : 512;
  [s getCharacters:buf range:NSMakeRange(0, n)];
  return shape_line((moonbit_string_t)buf, (int32_t)n, size, weight, style, out, cap);
}

static double width_of(NSString *s, double size, int style) {
  double out[4 * 128];
  int k = shape(s, size, 400, style, out, 128);
  double w = 0;
  for (int i = 0; i < k; i++) w += out[i * 4 + 2];
  return w;
}

// text.mbt glyph_col_sub, the same numbers
static void col_sub(double tx, double *col, int *sub) {
  double qf = floor(tx * 4.0 + 0.5);
  double c = floor((qf + 2.0) * 0.25);
  int r = (int)(qf - c * 4.0);
  *col = c;
  *sub = r == 1 ? 1 : r == -2 ? 2 : r == -1 ? 3 : 0;
}

// Where the ink of glyph `full_key` drawn at text_scale is across (its cover's centre), in pixels from the column its
// quad is put on (its own offset's pixels and the centre in its picture); NAN where it draws nothing.
static double ink_centre(int full_key) {
  double out[8];
  mb_host_glyph(full_key, out);
  MBDrawn *d = held;
  if (!d || !d.px || d.color) return NAN;
  double sum = 0, at = 0;
  for (int y = 0; y < d.ph; y++)
    for (int x = 0; x < d.pw; x++) {
      double a = d.px[(size_t)y * d.pw + x];
      sum += a;
      at += a * (x + 0.5);
    }
  if (sum <= 0) return NAN;
  return round(out[4] * text_scale) + at / sum;
}

// The key of the one cluster `c` in the face of `style`.
static int key_of(NSString *c, double size, int style) {
  double out[4 * 8];
  int k = shape(c, size, 400, style, out, 8);
  return k > 0 ? (int)out[3] : -1;
}

// Face `face` set in the family installed here named `family` (mb_host_face_add_family's way, from an NSString).
static int face_family(int face, NSString *family) {
  NSDictionary *attrs = @{(id)kCTFontFamilyNameAttribute : family};
  CTFontDescriptorRef base = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
  CFArrayRef ds = CTFontDescriptorCreateMatchingFontDescriptors(base, NULL);
  CFRelease(base);
  if (!ds) return 0;
  NSMutableArray *descs = [NSMutableArray new];
  NSMutableArray<NSNumber *> *weights = [NSMutableArray new];
  for (CFIndex i = 0; i < CFArrayGetCount(ds); i++) {
    CTFontDescriptorRef d = (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, i);
    NSDictionary *traits = (__bridge_transfer NSDictionary *)CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute);
    if ([traits[(id)kCTFontSymbolicTrait] unsignedIntValue] & kCTFontItalicTrait) continue;
    [descs addObject:(__bridge id)d];
    [weights addObject:@(css_weight([traits[(id)kCTFontWeightTrait] doubleValue]))];
  }
  CFRelease(ds);
  if (descs.count == 0) return 0;
  face_descs[face] = descs;
  face_weights[face] = weights;
  face_changed(face);
  return 1;
}

// Face `face` from a font file (mb_host_face_add's way, from a C path): every weight of it (0: a variable file).
static int face_file(int face, const char *path) {
  NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
  CFArrayRef ds = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
  if (!ds || CFArrayGetCount(ds) == 0) {
    if (ds) CFRelease(ds);
    return 0;
  }
  face_descs[face] = [NSMutableArray arrayWithObject:(__bridge id)CFArrayGetValueAtIndex(ds, 0)];
  face_weights[face] = [NSMutableArray arrayWithObject:@0];
  CFRelease(ds);
  face_changed(face);
  return 1;
}

static void face_none(int face) {
  [face_descs[face] removeAllObjects];
  [face_weights[face] removeAllObjects];
  face_changed(face);
}

// Digits one width in the face set now (style_tabular, 32), and not without it where `proportional` (the face's own
// digits are not one width).
static void tabular(const char *face, BOOL proportional) {
  NSArray *pairs = @[ @[ @"1111", @"8888" ], @[ @"0:01", @"0:48" ], @[ @"11:11", @"40:08" ] ];
  for (NSArray *p in pairs) {
    for (double size = 11; size <= 17; size += 2) {
      double a = width_of(p[0], size, 32), b = width_of(p[1], size, 32);
      printf("tnum %s %g: %s %.4f %s %.4f\n", face, size, [p[0] UTF8String], a, [p[1] UTF8String], b);
      CHECK(fabs(a - b) < 1e-6, "%s at %g: \"%s\" %.4f, \"%s\" %.4f with tabular digits", face, size, [p[0] UTF8String], a,
            [p[1] UTF8String], b);
    }
  }
  if (proportional) {
    double a = width_of(@"1111", 15, 0), b = width_of(@"8888", 15, 0);
    printf("tnum %s off: 1111 %.4f 8888 %.4f\n", face, a, b);
    CHECK(a < b - 0.5, "%s: \"1111\" %.4f not narrower than \"8888\" %.4f without tabular digits", face, a, b);
  }
}

// Each of a few glyphs drawn at each phase: its ink that far right of where it is at phase 0. Core Text's coverage of a
// thin stem is not its area to the byte (a hairline "l" at 15 moved 0.082 for a half pixel's 0.5): each within a tenth
// of a pixel, and all of them within three hundredths on average.
static void phases(void) {
  NSArray *cs = @[ @"l", @"I", @"H", @"o", @"n", @"1", @"中", @"字" ];
  double sum = 0, worst = 0;
  int n = 0;
  for (NSString *c in cs) {
    for (double size = 13; size <= 15; size += 2) {
      int key = key_of(c, size, 0);
      CHECK(key >= 0, "no key for %s", c.UTF8String);
      if (key < 0) continue;
      double c0 = ink_centre(key);
      for (int s = 1; s < 4; s++) {
        double cs_ = ink_centre(key | (s << 26));
        double moved = cs_ - c0, off = fabs(moved - sub_dx(s));
        printf("phase %s %g sub %d: %+.4f (want %+.2f)\n", c.UTF8String, size, s, moved, sub_dx(s));
        CHECK(off <= 0.1, "%s at %g, phase %d: ink moved %+.4f px, not %+.2f", c.UTF8String, size, s, moved, sub_dx(s));
        sum += off;
        n++;
        if (off > worst) worst = off;
      }
    }
  }
  printf("phases: %d off by %.4f px on average, %.4f at most\n", n, sum / n, worst);
  CHECK(sum / n <= 0.03, "phases off by %.4f px on average", sum / n);
}

// A line moved right a tenth of a pixel at a time (0.05 pt at 2): how far apart each two letters' ink is on the screen,
// most less least over the moves, with the phases (now) and with whole pixels alone (before them: each glyph at its
// pen rounded, drawn at none). Said, and held to a third of before's at most (a quarter were Core Text's coverage the
// area to the byte: phases).
static double spread(NSString *line, double size, BOOL phased) {
  double out[4 * 128];
  int k = shape(line, size, 400, 0, out, 128);
  double most = 0;
  double *lo = calloc(k, sizeof(double)), *hi = calloc(k, sizeof(double));
  for (int i = 0; i < k; i++) lo[i] = 1e9, hi[i] = -1e9;
  for (int m = 0; m < 40; m++) {
    double pen = 10.0 + m * 0.05;
    double prev = NAN;
    int prev_i = -1;
    for (int i = 0; i < k; i++) {
      int key = (int)out[i * 4 + 3];
      double x = pen;
      pen += out[i * 4 + 2];
      if (key < 0) continue;
      double tx = x * text_scale, col;
      int sub;
      if (phased) {
        col_sub(tx, &col, &sub);
      } else {
        col = round(tx);
        sub = 0;
      }
      double at = col + ink_centre(key | (sub << 26));
      if (isnan(at)) continue;
      if (!isnan(prev)) {
        double gap = at - prev;
        if (gap < lo[prev_i]) lo[prev_i] = gap;
        if (gap > hi[prev_i]) hi[prev_i] = gap;
      }
      prev = at;
      prev_i = i;
    }
  }
  for (int i = 0; i < k; i++)
    if (hi[i] >= lo[i] && hi[i] - lo[i] > most) most = hi[i] - lo[i];
  free(lo);
  free(hi);
  return most;
}

static void moving(void) {
  NSArray *lines = @[ @"Rendering text spacing", @"文字渲染 status 11s", @"Tick apps · Chat sidebar" ];
  for (NSString *l in lines) {
    double before = spread(l, 13, NO), now = spread(l, 13, YES);
    printf("moving \"%s\": letters' gaps vary by %.4f px with whole pixels alone, %.4f px with the phases (%.1fx)\n",
           l.UTF8String, before, now, now > 0 ? before / now : 0);
    CHECK(now <= 0.32, "\"%s\": gaps vary by %.4f px with the phases", l.UTF8String, now);
    CHECK(now * 3.0 <= before, "\"%s\": %.4f px with the phases against %.4f px before", l.UTF8String, now, before);
  }
}

// The letters of "Hello" in "中文 Hello world" (shaped whole) and in "Hello…" (the piece an ellipsis that cut it is in,
// shaped narrow: ui's shape_widths), each as wide.
static void cut_cjk(NSString *family) {
  if (!face_family(1, family)) {
    printf("cut %s: not installed here\n", family.UTF8String);
    return;
  }
  for (double size = 13; size <= 15; size += 2) {
    double whole[4 * 64], piece[4 * 64], cut[4 * 64];
    int kw = shape(@"中文 Hello world", size, 400, 0, whole, 64);
    int kp = shape(@"Hello…", size, 400, 64, piece, 64);
    int kc = shape(@"中文 Hello…", size, 400, 0, cut, 64);
    CHECK(kw >= 8 && kp >= 6 && kc >= 9, "%s: clusters %d %d %d", family.UTF8String, kw, kp, kc);
    if (kw < 8 || kp < 6 || kc < 9) continue;
    double most = 0;
    for (int i = 0; i < 5; i++) {
      double a = whole[(3 + i) * 4 + 2], b = piece[i * 4 + 2], c = cut[(3 + i) * 4 + 2];
      printf("cut %s %g: %c whole %.4f, narrow piece %.4f (%+.4f), cut whole %.4f (%+.4f)\n", family.UTF8String, size,
             "Hello"[i], a, b, b - a, c, c - a);
      if (fabs(b - a) > most) most = fabs(b - a);
    }
    printf("cut %s %g: ellipsis %.4f in the narrow piece, %.4f whole\n", family.UTF8String, size, piece[5 * 4 + 2],
           cut[8 * 4 + 2]);
    CHECK(most < 1e-6, "%s at %g: a letter of \"Hello\" %.4f wider or narrower cut by an ellipsis", family.UTF8String,
          size, most);
  }
  face_none(1);
}

// The rest of glyphs' phases in turn (ahead_rests): one more of every glyph before a third of any, each glyph's count
// of them all the same.
static void rests_in_turn(void) {
  NSMutableArray<MBAhead *> *asked = [NSMutableArray new];
  uint8_t wants[] = {SUB_ALL, SUB_ALL, 0x6, SUB_ALL, 0x3};
  uint8_t firsts[] = {0x1, 0x2, 0x0, SUB_ALL, 0x1};
  for (int i = 0; i < 5; i++) {
    MBAhead *a = [MBAhead new];
    a.key = i;
    a.want = wants[i];
    a.first = firsts[i];
    [asked addObject:a];
  }
  NSMutableString *got = [NSMutableString new];
  for (MBAhead *a in ahead_rests(asked)) [got appendFormat:@"%d", a.key];
  printf("rests in turn: %s\n", got.UTF8String);
  // (0 and 1 three each, 2 two, 3 none, 4 one)
  CHECK([got isEqualToString:@"0124" @"012" @"01"], "rests in the order %s", got.UTF8String);
}

// A page of glyphs drawn ahead on the queues at once (mb_host_glyphs_ahead, their first phase where their keys put
// them, the rest after): each phase of each taken drawn there, as the frames' thread draws it, to the byte.
static void ahead_page(void) {
  NSString *page = @"文字渲染横向推入页面每个字形的四分之一像素相位Rendering every glyph's phases ahead 0123456789";
  int sizes[] = {13, 15, 17};
  int keys[3 * 128], n = 0;
  NSMutableSet<NSNumber *> *seen = [NSMutableSet new];
  for (int si = 0; si < 3; si++) {
    double out[4 * 128];
    int k = shape(page, sizes[si], 400, 0, out, 128);
    for (int i = 0; i < k && n < 3 * 128; i++) {
      int key = (int)out[i * 4 + 3];
      // (each once, and none drawn by the tests before)
      if (key < 0 || entries[key].subs_queued || [seen containsObject:@(key)]) continue;
      [seen addObject:@(key)];
      keys[n++] = key | ((i % SUB_COUNT) << 26);
    }
  }
  CHECK(n > 100, "only %d glyphs to draw ahead", n);
  mb_host_glyphs_ahead(keys, n);
  // (both queues serial, each item of theirs a dispatch_apply over all it was handed: done when a block after it is)
  dispatch_sync(ahead_q, ^{
                });
  dispatch_sync(ahead_rest_q, ^{
                });
  int ahead = 0, same = 0;
  for (int i = 0; i < n; i++) {
    int key = key_base(keys[i]);
    glyph_entry *e = &entries[key];
    for (int s = 0; s < SUB_COUNT; s++) {
      MBDrawn *d = drawn_ahead(key, s);
      if (!d) continue;
      ahead++;
      MBDrawn *r =
          draw_cluster(texts[key], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(s), text_scale);
      BOOL eq = d.pw == r.pw && d.ph == r.ph && d.color == r.color && CGRectEqualToRect(d.b, r.b) &&
                (!d.px || !r.px ? d.px == r.px : memcmp(d.px, r.px, (size_t)d.pw * d.ph * (d.color ? 4 : 1)) == 0);
      if (eq) same++;
      CHECK(eq, "glyph %d phase %d drawn ahead not as drawn here", key, s);
    }
  }
  printf("ahead page: %d glyphs, %d of their %d phases drawn ahead, %d as drawn here\n", n, ahead, n * SUB_COUNT, same);
  CHECK(ahead == n * SUB_COUNT, "%d of %d phases drawn ahead", ahead, n * SUB_COUNT);
  int left = 0;
  for (int i = 0; i < n; i++) left += ahead_of[@(key_base(keys[i]))] != nil;
  CHECK(left == 0, "%d glyphs still asked ahead, all their phases taken", left);
}

static void drain_ahead_queues(void) {
  dispatch_sync(ahead_q, ^{
                });
  dispatch_sync(ahead_rest_q, ^{
                });
}

static BOOL drawn_eq(MBDrawn *d, MBDrawn *r) {
  if (!d || !r) return NO;
  return d.pw == r.pw && d.ph == r.ph && d.color == r.color && CGRectEqualToRect(d.b, r.b) &&
         (!d.px || !r.px ? d.px == r.px : memcmp(d.px, r.px, (size_t)d.pw * d.ph * (d.color ? 4 : 1)) == 0);
}

// Re-requesting glyphs after eviction/consumption, active single-phase re-request, same-batch double-phase re-request,
// old MBAhead new-batch double-phase with duplicate key, and full-queue continuation for already-active entries.
static void ahead_rewarm(void) {
  ahead_ensure();
  drain_ahead_queues();

  // 1. Idle eviction/consumption re-request: after all 4 phases taken (ahead_of == nil), re-request phase 1 alone.
  {
    int k = key_of(@"重", 19, 0);
    CHECK(k >= 0, "rewarm 1: no key");
    int32_t init[1] = {k};
    mb_host_glyphs_ahead(init, 1);
    drain_ahead_queues();
    for (int s = 0; s < SUB_COUNT; s++) {
      MBDrawn *d = drawn_ahead(k, s);
      CHECK(d != nil, "rewarm 1: initial phase %d missing", s);
    }
    CHECK(ahead_of[@(k)] == nil, "rewarm 1: ahead_of not cleared after taking all 4 phases");
    CHECK(entries[k].subs_queued == SUB_ALL, "rewarm 1: subs_queued=%u", entries[k].subs_queued);

    int32_t req[1] = {k | (1 << 26)};
    mb_host_glyphs_ahead(req, 1);
    drain_ahead_queues();
    glyph_entry *e = &entries[k];
    MBDrawn *got1 = drawn_ahead(k, 1);
    MBDrawn *ref1 =
        draw_cluster(texts[k], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(1), text_scale);
    CHECK(drawn_eq(got1, ref1), "rewarm 1: phase 1 not drawn or not byte-identical");
    CHECK(drawn_ahead(k, 0) == nil && drawn_ahead(k, 2) == nil && drawn_ahead(k, 3) == nil,
          "rewarm 1: unexpected extra phases drawn");
    CHECK(ahead_of[@(k)] == nil, "rewarm 1: ahead_of still set after consuming phase 1");
  }

  // 2. Active single-phase consumed re-request: take phase 0 only, keep same MBAhead pointer, re-request phase 0.
  {
    int k = key_of(@"热", 19, 0);
    CHECK(k >= 0, "rewarm 2: no key");
    int32_t init[1] = {k};
    mb_host_glyphs_ahead(init, 1);
    drain_ahead_queues();
    CHECK(drawn_ahead(k, 0) != nil, "rewarm 2: initial phase 0 missing");
    MBAhead *kept = ahead_of[@(k)];
    CHECK(kept != nil, "rewarm 2: ahead_of nil while phases 1..3 remain");

    int32_t req[1] = {k | (0 << 26)};
    mb_host_glyphs_ahead(req, 1);
    drain_ahead_queues();
    CHECK(ahead_of[@(k)] == kept, "rewarm 2: ahead_of replaced instead of reusing same MBAhead");
    glyph_entry *e = &entries[k];
    MBDrawn *got0 = drawn_ahead(k, 0);
    MBDrawn *ref0 =
        draw_cluster(texts[k], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(0), text_scale);
    CHECK(drawn_eq(got0, ref0), "rewarm 2: re-warmed phase 0 not byte-identical");
    for (int s = 1; s < SUB_COUNT; s++) {
      CHECK(drawn_ahead(k, s) != nil, "rewarm 2: remaining phase %d lost", s);
    }
    CHECK(ahead_of[@(k)] == nil, "rewarm 2: ahead_of not cleared after draining all phases");
  }

  // 3. Same-batch double-phase re-request: subs_queued = 0b0011, batch asks phase 0 and phase 1 together.
  {
    int k = key_of(@"双", 19, 0);
    CHECK(k >= 0, "rewarm 3: no key");
    entries[k].subs_queued = 0x3;
    int32_t req[2] = {k | (0 << 26), k | (1 << 26)};
    mb_host_glyphs_ahead(req, 2);
    drain_ahead_queues();
    glyph_entry *e = &entries[k];
    for (int s = 0; s < 2; s++) {
      MBDrawn *got = drawn_ahead(k, s);
      MBDrawn *ref =
          draw_cluster(texts[k], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(s), text_scale);
      CHECK(drawn_eq(got, ref), "rewarm 3: phase %d not byte-identical", s);
    }
    for (int s = 2; s < SUB_COUNT; s++) {
      CHECK(drawn_ahead(k, s) != nil, "rewarm 3: unqueued phase %d missing", s);
    }
    CHECK(ahead_of[@(k)] == nil, "rewarm 3: ahead_of not cleared");
  }

  // 4. Old MBAhead new-batch double-phase with duplicate key: phases 2..3 remain, batch asks [0, 1, 0].
  {
    int k = key_of(@"复", 19, 0);
    CHECK(k >= 0, "rewarm 4: no key");
    int32_t init[1] = {k};
    mb_host_glyphs_ahead(init, 1);
    drain_ahead_queues();
    CHECK(drawn_ahead(k, 0) != nil && drawn_ahead(k, 1) != nil, "rewarm 4: initial phases 0..1 missing");
    MBAhead *old_a = ahead_of[@(k)];
    CHECK(old_a != nil, "rewarm 4: ahead_of nil while phases 2..3 remain");

    int32_t req[3] = {k | (0 << 26), k | (1 << 26), k | (0 << 26)};
    mb_host_glyphs_ahead(req, 3);
    drain_ahead_queues();
    CHECK(ahead_of[@(k)] == old_a, "rewarm 4: ahead_of pointer changed");
    glyph_entry *e = &entries[k];
    for (int s = 0; s < 2; s++) {
      MBDrawn *got = drawn_ahead(k, s);
      MBDrawn *ref =
          draw_cluster(texts[k], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(s), text_scale);
      CHECK(drawn_eq(got, ref), "rewarm 4: phase %d not byte-identical", s);
    }
    for (int s = 2; s < SUB_COUNT; s++) {
      CHECK(drawn_ahead(k, s) != nil, "rewarm 4: phase %d lost", s);
    }
    CHECK(ahead_of[@(k)] == nil, "rewarm 4: ahead_of not cleared");
  }

  // 5. Full queue does not break early: later already-active entry still re-warms when an earlier new entry cannot fit.
  {
    int k_active = key_of(@"满", 19, 0);
    int k_new = key_of(@"新", 19, 0);
    CHECK(k_active >= 0 && k_new >= 0, "rewarm 5: no keys");
    int32_t init[1] = {k_active};
    mb_host_glyphs_ahead(init, 1);
    drain_ahead_queues();
    CHECK(drawn_ahead(k_active, 0) != nil, "rewarm 5: initial phase 0 missing");
    MBAhead *active_a = ahead_of[@(k_active)];
    CHECK(active_a != nil, "rewarm 5: active entry missing");

    // Pin front of ahead_order as drawing so drop_oldest_drawn() returns NO, and pad to AHEAD_MOST.
    NSMutableArray<MBAhead *> *dummies = [NSMutableArray new];
    MBAhead *blocker = [MBAhead new];
    blocker.key = -100;
    blocker.drawing = 1;
    [ahead_order insertObject:blocker atIndex:0];
    [dummies addObject:blocker];
    while ((int)ahead_order.count < AHEAD_MOST) {
      MBAhead *d = [MBAhead new];
      d.key = -100 - (int)dummies.count;
      [ahead_order addObject:d];
      [dummies addObject:d];
    }

    int32_t req[2] = {k_new | (0 << 26), k_active | (0 << 26)};
    mb_host_glyphs_ahead(req, 2);
    drain_ahead_queues();
    CHECK(ahead_of[@(k_new)] == nil, "rewarm 5: new key unexpectedly inserted at full capacity");
    glyph_entry *e = &entries[k_active];
    MBDrawn *got0 = drawn_ahead(k_active, 0);
    MBDrawn *ref0 =
        draw_cluster(texts[k_active], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(0), text_scale);
    CHECK(drawn_eq(got0, ref0), "rewarm 5: active entry after full-queue miss did not re-warm phase 0");
    for (int s = 1; s < SUB_COUNT; s++) CHECK(drawn_ahead(k_active, s) != nil, "rewarm 5: phase %d lost", s);
    blocker.drawing = 0;
    for (MBAhead *d in dummies) [ahead_order removeObject:d];
    CHECK(ahead_order.count == 0, "rewarm 5: ahead_order not clean (%lu)", (unsigned long)ahead_order.count);
  }
  printf("ahead_rewarm: ok\n");
}

// The keys forgotten only where MoonBit reads the generation (keys_sweep): the faces changed in a frame keep them
// through it (a key made before still draws), and the next read forgets them, the generation moved on, what was asked
// ahead let go, a key made before drawing nothing, one made after drawing as before; and past KEYS_MOST of them, the
// same.
static void keys_bounded(void) {
  // (what the tests before changed of the faces forgotten as a frame would start)
  mb_host_atlas_generation();
  int k = key_of(@"a", 14, 0);
  CHECK(k >= 0, "no key for a");
  int g = mb_host_atlas_generation();
  CHECK(mb_host_atlas_generation() == g, "the generation moved with nothing changed");
  CHECK(n_entries > 0, "no keys kept");
  double out[8];
  mb_host_glyph(k, out);
  CHECK(out[2] > 0, "a not drawn");
  int32_t ask[1] = {k};
  mb_host_glyphs_ahead(ask, 1);
  faces_changed();
  // (in the frame the faces changed in: what it shaped still draws)
  CHECK(n_entries > k, "keys forgotten as the faces changed, in the frame");
  mb_host_glyph(k, out);
  CHECK(out[2] > 0, "a not drawn in the frame the faces changed in");
  int g2 = mb_host_atlas_generation();
  CHECK(g2 > g, "the generation not moved on");
  CHECK(n_entries == 0 && keys.count == 0 && texts.count == 0 && n_bmp == 0, "keys kept: %d", n_entries);
  CHECK(ahead_order.count == 0 && ahead_of.count == 0, "%lu still asked ahead", (unsigned long)ahead_order.count);
  CHECK(mb_host_atlas_generation() == g2, "the generation moved again");
  mb_host_glyph(k + 5, out);
  CHECK(out[2] == 0 && out[3] == 0, "a key made before drew");
  int k2 = key_of(@"a", 14, 0);
  CHECK(k2 == 0, "the first key after %d", k2);
  mb_host_glyph(k2, out);
  CHECK(out[2] > 0, "a not drawn after");
  // past KEYS_MOST: forgotten as the generation is next read, not before
  for (int i = 0; n_entries <= KEYS_MOST; i++) intern(@"b", 10 + i * 0.001, 400, 0);
  CHECK(n_entries == KEYS_MOST + 1, "%d keys", n_entries);
  int g3 = mb_host_atlas_generation();
  CHECK(g3 > g2 && n_entries == 0, "%d keys kept past the most, generation %d", n_entries, g3);
}

// Reference implementation of shape_line (unoptimized Core Text baseline: per-cluster
// rangeOfComposedCharacterSequenceAtIndex, CTLineGetOffsetForStringIndex, and intern_at) used to verify
// zero-difference parity for shape_line across 50+ diverse strings, fonts, and styles.
static double ref_offset_at(CTLineRef line, NSString *s, NSUInteger len, NSUInteger i) {
  while (i < len && takes_no_room([s characterAtIndex:i])) i++;
  return CTLineGetOffsetForStringIndex(line, (CFIndex)i, NULL);
}

static int32_t shape_line_ref(const unichar *text, int32_t len, double size, int32_t weight, int32_t style,
                              double *out, int32_t cap) {
  NSString *s = [[NSString alloc] initWithCharacters:text length:(NSUInteger)len];
  CTFontRef f = font_for(size, weight, style);
  CTLineRef line = make_line(s, f, style);
  uint8_t *from = calloc((size_t)len + 1, 1);
  int any_rtl = 0;
  double *glyph_adv = calloc((size_t)len + 1, sizeof(double));
  double *glyph_x = malloc(sizeof(double) * ((size_t)len + 1));
  for (int32_t j = 0; j <= len; j++) glyph_x[j] = NAN;
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
    CTRunRef run = CFArrayGetValueAtIndex(runs, r);
    CFIndex gc = CTRunGetGlyphCount(run);
    CFIndex *idx = malloc(sizeof(CFIndex) * (size_t)(gc > 0 ? gc : 1));
    CGPoint *pos = malloc(sizeof(CGPoint) * (size_t)(gc > 0 ? gc : 1));
    CTRunGetStringIndices(run, CFRangeMake(0, 0), idx);
    CTRunGetPositions(run, CFRangeMake(0, 0), pos);
    double w = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
    if (CTRunGetStatus(run) & kCTRunStatusRightToLeft) any_rtl = 1;
    for (CFIndex g = 0; g < gc; g++) {
      if (idx[g] < 0 || idx[g] >= len) continue;
      from[idx[g]] = 1;
      if (isnan(glyph_x[idx[g]]) || pos[g].x < glyph_x[idx[g]]) glyph_x[idx[g]] = pos[g].x;
      double next = g + 1 < gc ? pos[g + 1].x : pos[0].x + w;
      glyph_adv[idx[g]] += next - pos[g].x;
    }
    free(idx);
    free(pos);
  }
  int32_t k = 0;
  NSUInteger i = 0;
  double x0 = ref_offset_at(line, s, (NSUInteger)len, 0);
  while (i < (NSUInteger)len && k < cap) {
    NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:i];
    unichar c = [s characterAtIndex:r.location];
    if (r.location != i) x0 = ref_offset_at(line, s, (NSUInteger)len, r.location);
    double start_x = x0;
    double x1 = ref_offset_at(line, s, (NSUInteger)len, r.location + r.length);
    double adv = x1 - x0;
    x0 = x1;
    if (any_rtl) {
      adv = 0;
      for (NSUInteger j = r.location; j < r.location + r.length; j++) adv += glyph_adv[j];
    }
    int key;
    if (c == '\n') {
      adv = 0;
      key = -1;
    } else if (c == ' ' || c == '\t') {
      key = -1;
    } else {
      int drawn = 0;
      for (NSUInteger j = r.location; j < r.location + r.length; j++) drawn |= from[j];
      double gx = NAN;
      for (NSUInteger j = r.location; j < r.location + r.length; j++)
        if (!isnan(glyph_x[j]) && (isnan(gx) || glyph_x[j] < gx)) gx = glyph_x[j];
      double dx = any_rtl || isnan(gx) ? 0 : gx - start_x;
      if (fabs(dx) < 0.01) dx = 0;
      BOOL after_wide = r.location > 0 && [s characterAtIndex:r.location - 1] >= 0x2E80;
      if (!drawn && k > 0)
        key = -2;
      else if (r.length == 1 && c < 128 && (dx == 0 || !after_wide))
        key = intern([s substringWithRange:r], size, weight, style);
      else
        key = intern_at([s substringWithRange:r], size, weight, style, dx);
    }
    out[k * 4] = r.location;
    out[k * 4 + 1] = r.length;
    out[k * 4 + 2] = adv < 0 ? 0 : adv;
    out[k * 4 + 3] = key;
    k++;
    i = r.location + r.length;
  }
  free(from);
  free(glyph_adv);
  free(glyph_x);
  CFRelease(line);
  return k;
}

static void shape_parity(void) {
  NSArray<NSString *> *corpus = @[
    @"",
    @"a",
    @" ",
    @"\n",
    @"\t",
    @"Hello, world!",
    @"AVATAR WAVE To The Office official offline difficult",
    @"fi fl ffi ffl ff fj",
    @"0123456789 1111 8888 0:01 40:08",
    @"The quick brown fox jumps over the lazy dog.",
    @"const x = foo(bar, 123); // comment: a->b != c",
    @"https://example.com/path/to/file.m?a=1&b=2#L123",
    @"纯中文段落测试，不包含任何英文字符与数字。",
    @"汉字连续排版测量性能基准测试中文汉字简体繁体漢字",
    @"你是Owner，我在macOS 27上测试中英混排自动间距！",
    @"中文English中文123中文ABC中文",
    @"你好World世界Hello测试Test2026年11月22日",
    @"「（中文括号挤压测试）」，《书名号》【方括号】！？：；、。",
    @"“引号”‘单引号’——破折号……省略号·中点",
    @"（测试）、「测试」、『测试』、【测试】、《测试》",
    @"ＡＢＣ１２３！＠＃￥％……＆＊（）",
    @"日本語のひらがなとカタカナと漢字の混在テストです。",
    @"いろはにほへとちりぬるを カタカナ・ヴ・ヵ・ヶ",
    @"한국어 테스트입니다. 한글과 English 123 혼용.",
    @"完成任务 ✅ 下一步 → 延迟 ≤ 16ms 🎉 汉字缓存命中测试",
    @"👩🏽‍💻 👪 ❤️ 🏳️‍🌈 👍🏻 🧑‍🤝‍🧑",
    @"emoji💡中间穿插中文and English🚀",
    @"e\u0301 cafe\u0301 a\u0308 o\u0302 n\u0303",
    @"Z\u0300\u0301\u0302\u0303 combining stack",
    @"中文\u0301组合音标测试",
    @"zero\u200Bwidth\u200Cjoiner\u200Dword\u2060bom\uFEFFend",
    @"trailing zero width\u200B",
    @"\u200Bleading zero width",
    @"@[mention\u200B]\u200B",
    @"العربية مرحبا بالعالم",
    @"שלום עולם 123",
    @"Mixed العربية and English and 中文 together",
    @"RTL שלום + LTR hello + 数字 42",
    @"line1\nline2\n\nline4",
    @"col1\tcol2\tcol3\t中文\t123",
    @"CRLF\r\nline\r\nend",
    @"¥100 §1 20° ±0.5 · × ÷ – — ‘a’ “b” • … ‰ ′ ″ € ℃",
    @"αβγδε ΑΒΓΔΕ π ≈ 3.14159 ∑ ∫ √ ∞ ≠ ≤ ≥",
    @"Кириллица привет мир 12345",
    @"Tiếng Việt có dấu phức tạp hơn",
    @"ภาษาไทยทดสอบการตัดคำ",
    @"हिन्दी देवनागरी परीक्षण",
    @"fail ail hover ver AV To We",
    @"Hello…",
    @"中文 Hello…",
    @"真机 PostHog ui_hang 显示 tree words measured 是当前双端最大的 CPU 卡顿源。",
    @"perf(mbui): reduce Apple & Android text shaping hotpath overhead (500 rounds).",
    @"# Heading\n## 二级标题\n- 列表项 1: `code_span` 与 **粗体**",
    @"   leading and trailing spaces   ",
    @"\t\t\n\n  "
  ];
  int styles[] = {0, 1, 2, 4, 8, 32, 64};
  int weights[] = {400, 700};
  int checked = 0;
  double got[4 * 512], want[4 * 512];
  for (int si = 0; si < (int)(sizeof(styles) / sizeof(styles[0])); si++) {
    for (int wi = 0; wi < (int)(sizeof(weights) / sizeof(weights[0])); wi++) {
      int st = styles[si], wt = weights[wi];
      for (NSString *s in corpus) {
        unichar buf[512];
        NSUInteger n = s.length < 512 ? s.length : 512;
        [s getCharacters:buf range:NSMakeRange(0, n)];
        int32_t k_ref = shape_line_ref(buf, (int32_t)n, 15.0, wt, st, want, 512);
        int32_t k_got = shape_line((moonbit_string_t)buf, (int32_t)n, 15.0, wt, st, got, 512);
        CHECK(k_got == k_ref, "cluster count mismatch (%d != %d) style=%d weight=%d in \"%s\"", k_got, k_ref, st, wt,
              s.UTF8String);
        if (k_got != k_ref) continue;
        for (int32_t c = 0; c < k_ref; c++) {
          CHECK(got[c * 4] == want[c * 4] && got[c * 4 + 1] == want[c * 4 + 1],
                "range mismatch at %d style=%d weight=%d in \"%s\"", c, st, wt, s.UTF8String);
          double derr = fabs(got[c * 4 + 2] - want[c * 4 + 2]);
          CHECK(derr < 1e-6, "adv mismatch at %d (%.6f != %.6f, err=%.6f) style=%d weight=%d in \"%s\"", c,
                got[c * 4 + 2], want[c * 4 + 2], derr, st, wt, s.UTF8String);
          int gk = (int)got[c * 4 + 3], wk = (int)want[c * 4 + 3];
          if (gk != wk) {
            BOOL same_entry = gk >= 0 && wk >= 0 && [texts[gk] isEqualToString:texts[wk]]
                              && fabs(entries[gk].dx - entries[wk].dx) < 1e-6;
            CHECK(same_entry, "key mismatch at %d (%d != %d) style=%d weight=%d in \"%s\"", c, gk, wk, st, wt,
                  s.UTF8String);
          }
        }
        checked++;
      }
    }
  }
  printf("shape_parity: %d cases matched reference (< 1e-6)\n", checked);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    text_scale = 2.0;
    tabular("system", NO);
    if (argc > 1) {
      CHECK(face_file(1, argv[1]), "no face in %s", argv[1]);
      tabular(argv[1], YES);
      face_none(1);
    }
    phases();
    moving();
    cut_cjk(@"PingFang SC");
    cut_cjk(@"Hiragino Sans");
    rests_in_turn();
    ahead_page();
    ahead_rewarm();
    shape_parity();
    keys_bounded();
    // Preview slot (face >= 7) mutations must not bump atlas_generation or invalidate primary slot 1 glyph keys
    {
      CHECK(face_family(1, @"Helvetica"), "set slot 1 to Helvetica");
      mb_host_atlas_generation();
      int g0 = mb_host_atlas_generation();
      int k1 = key_of(@"字", 14, 0);
      CHECK(k1 >= 0, "no key for primary slot 1");
      double out[8] = {0};
      mb_host_glyph(k1, out);
      CHECK(out[2] > 0, "primary slot 1 key did not draw before preview");
      int style7 = 7 << 8;
      CHECK(face_family(7, @"Menlo"), "set preview slot 7 to Menlo");
      int k7a = key_of(@"A", 14, style7);
      CHECK(k7a >= 0, "no key for preview slot 7 (Menlo)");
      mb_host_face_clear(7);
      CHECK(face_family(7, @"PingFang SC"), "set preview slot 7 to PingFang SC");
      int k7b = key_of(@"A", 14, style7);
      CHECK(k7b >= 0 && k7b != k7a, "preview slot 7 key collided across family change: %d vs %d", k7a, k7b);
      CHECK(mb_host_atlas_generation() == g0, "preview slot 7 bumped atlas_generation: %d -> %d", g0, mb_host_atlas_generation());
      double out2[8] = {0};
      mb_host_glyph(k1, out2);
      CHECK(out2[2] > 0 && out2[2] == out[2] && out2[3] == out[3], "primary slot 1 key invalidated after preview slot 7 mutations");
      mb_host_face_clear(7);
      face_none(1);
    }
    // style_serif (4) | style_words (16) must stay serif (face_id == 0) even when face_text (slot 2) is registered
    CTFontDescriptorRef serif_test_desc = CTFontDescriptorCreateWithNameAndSize(CFSTR("Menlo"), 15.0);
    CHECK(serif_test_desc != NULL, "create Menlo descriptor");
    if (serif_test_desc) {
      face_descs[2] = [NSMutableArray arrayWithObject:(__bridge_transfer id)serif_test_desc];
      CHECK(face_id(4 | 16) == 0, "style_serif | style_words must exempt reader serif from face_text");
      CHECK(face_id(16) == 2, "style_words without style_serif still uses face_text");
      mb_host_face_clear(2);
    }
  }
  if (failed) return 1;
  printf("apple_text_test: ok\n");
  return 0;
}
