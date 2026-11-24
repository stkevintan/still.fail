// src/host/gles_render.h's tests on the window's way (not mbui-render's offscreen one: Android's surface, Linux's
// window), in OpenGL ES 3 on EGL's surfaceless platform (Mesa's llvmpipe where there is no GPU), a framebuffer of the
// test's own standing for the surface (target_fb): a frame drawn whole goes straight onto it, no canvas made; one said
// to differ in parts is drawn into the canvas and shown, the surface then the same to the byte as the frame drawn
// whole; the blur under glass kept while what is under it is the same, made again once it is not, never kept while a
// picture under it had no texture yet; a group the host keeps drawn out to the float the app's own instance would be;
// a frame handed over from another thread (frame_mail.h) taken only to read back leaving the next drawn whole; three
// groups of glass on one screen each keeping its own blur, made again only for the one something moved under.
//   cc -Wall -Wno-unused-function -I src/host -I "$MOON_HOME/include" scripts/gles_render_test.c
//     $(pkg-config --cflags --libs epoxy zlib) -lm -o out/gles_render_test && out/gles_render_test
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>
#include "moonbit.h"
#include "corner_sl.h"

#define LOG(...) (fprintf(stderr, "gles_render_test: " __VA_ARGS__), fputc('\n', stderr))
#define MB_STREAM_TEX 4194304
#define MB_VIEW_TEX 8388608

// picture 1's texture: none (not decoded yet) till a test makes one
static GLuint picture_one;
static GLuint image_tex(int id) { return id == 1 ? picture_one : 0; }
static void view_parts_in(int tid, int32_t start, int32_t end) { (void)tid, (void)start, (void)end; }

// A draw that samples the texture it draws into (a sampler of the program's, active, on a unit that holds the
// framebuffer's colour attachment): a feedback loop. WebGL2 and strict GLES 3 drivers refuse it
// (GL_INVALID_OPERATION, the draw dropped); llvmpipe draws it all the same, so the test looks for it itself.
static int feedback_loops;
static void feedback_seen(void) {
  GLint fb = 0, type = 0, tex = 0, p = 0, n = 0, unit_was = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fb);
  if (!fb) return;
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
  if (type != GL_TEXTURE) return;
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &tex);
  glGetIntegerv(GL_CURRENT_PROGRAM, &p);
  if (!p || !tex) return;
  glGetProgramiv(p, GL_ACTIVE_UNIFORMS, &n);
  glGetIntegerv(GL_ACTIVE_TEXTURE, &unit_was);
  for (GLint i = 0; i < n; i++) {
    char name[64];
    GLint size = 0, unit = 0, bound = 0;
    GLenum utype = 0;
    glGetActiveUniform(p, (GLuint)i, sizeof name, NULL, &size, &utype, name);
    if (utype != GL_SAMPLER_2D) continue;
    glGetUniformiv(p, glGetUniformLocation(p, name), &unit);
    glActiveTexture(GL_TEXTURE0 + unit);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
    if (bound == tex) {
      if (!feedback_loops) fprintf(stderr, "gles_render_test: feedback loop: %s on unit %d samples texture %d drawn into\n", name, unit, tex);
      feedback_loops++;
    }
  }
  glActiveTexture((GLenum)unit_was);
}
static int vbo_uploads;
static int instanced_draws;
static int instanced_total;
static int program_binds;
static void checked_buffer_data(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
  if (target == GL_ARRAY_BUFFER) vbo_uploads++;
  epoxy_glBufferData(target, size, data, usage);
}
static void checked_use_program(GLuint p) {
  program_binds++;
  epoxy_glUseProgram(p);
}
static void checked_draw_arrays(GLenum mode, GLint first, GLsizei count) {
  feedback_seen();
  epoxy_glDrawArrays(mode, first, count);
}
static void checked_draw_arrays_instanced(GLenum mode, GLint first, GLsizei count, GLsizei n) {
  feedback_seen();
  instanced_draws++;
  instanced_total += n;
  epoxy_glDrawArraysInstanced(mode, first, count, n);
}
#undef glBufferData
#define glBufferData checked_buffer_data
#undef glUseProgram
#define glUseProgram checked_use_program
#undef glDrawArrays
#define glDrawArrays checked_draw_arrays
#undef glDrawArraysInstanced
#define glDrawArraysInstanced checked_draw_arrays_instanced

// Programs made ahead (gles_render.h gl_progs_ahead): the host's thread stood in for by this one, in its own context,
// called by the test where a host would start it
#define MB_PROGS_AHEAD 1
#include "gles_render.h"
#include "frame_mail.h"

static unsigned ahead_started, ahead_started_gen;
static void progs_ahead_start(unsigned gen) {
  ahead_started++;
  ahead_started_gen = gen;
}

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

// the surface: 100 × 75 points, 2 pixels a point
#define W 100
#define H 75
#define S 2

// An instance: a rect at x, y, w × h of colour (r, g, b), kind `kind`, image `tid`, its clip the window's.
static void rect_at(double *d, double x, double y, double w, double h, int kind, double r, double g, double b,
                    double tid) {
  memset(d, 0, MB_INST * sizeof(double));
  d[0] = x;
  d[1] = y;
  d[2] = w;
  d[3] = h;
  d[5] = kind;
  d[8] = r;
  d[9] = g;
  d[10] = b;
  d[11] = 1;
  d[18] = W;
  d[19] = H;
  d[20] = tid;
}

// What framebuffer `fb` holds (fb_w × fb_h, RGBA): the caller frees it.
static unsigned char *pixels_of_fb(GLuint fb) {
  unsigned char *px = malloc((size_t)fb_w * fb_h * 4);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fb);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, fb_w, fb_h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  return px;
}

// The surface the same to the byte as the frame kept drawn whole again (draw_kept_read, as drawn_pixels reads it).
// (the blurs kept by glass shown again there as they are: surface_as_fresh makes them anew)
static int surface_as_whole(GLuint surface) {
  unsigned char *shown = pixels_of_fb(surface);
  draw_kept_read();
  unsigned char *whole = pixels_of_fb(read_fb);
  glBindFramebuffer(GL_FRAMEBUFFER, surface);
  int same = memcmp(shown, whole, (size_t)fb_w * fb_h * 4) == 0;
  free(shown);
  free(whole);
  return same;
}

// The surface the same to the byte as the frame kept drawn whole again with no blur kept, each made anew.
static int surface_as_fresh(GLuint surface) {
  glass_forget();
  return surface_as_whole(surface);
}

// A frame handed over from the thread that makes it (frame_mail.h: Android's app thread), what it says differs a
// part x, y, w × h of it.
static void hand(const double *inst, int32_t count, double x, double y, double w, double h) {
  // (said as it is painted, before it is presented: mb_host_render_dirty)
  fm_said(x, y, w, h);
  float *f = fm_present(gl_frame_floats(count), count, 0.1, 0.2, 0.3, W, H, S);
  mb_groups_floats(f, inst, count);
  CHECK(fm_publish());
}

// The frame handed over taken (Android's Native.take): to be drawn (and drawn, Native.draw), or only read back.
static void take(int shown) {
  handed_frame got;
  CHECK(fm_take(&got));
  fm_keep(&got, shown);
  if (shown) gl_present_kept(kept_count, kept_r, kept_g, kept_b);
}

// A progressive frosted glass (kind 5) across the window from y0 to y1, faded out over 8 points towards its foot
// (`to_foot`) or its top, its capture `tid`.
static void progressive_at(double *d, double y0, double y1, int to_foot, double tid) {
  rect_at(d, 0, y0, W, y1 - y0, 5, 0.96, 0.96, 0.96, tid);
  d[6] = 1.1;
  d[7] = 4.0;
  d[11] = 0.35;
  d[15] = 1.0;
  d[22] = -1.0;
  if (to_foot) {
    d[54] = y1;
    d[55] = 8.0;
  } else {
    d[52] = y0;
    d[53] = 8.0;
  }
}

// A foreground lens (kind 8) 40 points square at x, y over one child, a 16-point square of (r, g, b) at its middle.
static void lens_at(double *d, double x, double y, double r, double g, double b) {
  rect_at(d, x, y, 40, 40, 8, 1.0, 1.0, 1.0, 0);
  d[4] = 10;
  d[7] = 2.0;
  d[11] = 1.0;
  d[12] = 1.0;
  d[13] = 8.0;
  d[14] = 6.0;
  d[15] = 1.0;
  d[36] = d[37] = d[38] = d[39] = 10;
  rect_at(d + MB_INST, x + 12, y + 12, 16, 16, 0, r, g, b, 0);
}

// The texture unit `unit` holds (2D).
static GLuint bound_on(GLenum unit) {
  GLint was = 0, t = 0;
  glGetIntegerv(GL_ACTIVE_TEXTURE, &was);
  glActiveTexture(unit);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
  glActiveTexture((GLenum)was);
  return (GLuint)t;
}

// A level the blurs or the lenses draw into left on a unit of the post program's after a frame.
static int level_left_bound(void) {
  for (int u = 1; u <= 3; u++) {
    GLuint t = bound_on(GL_TEXTURE0 + u);
    if (!t) continue;
    if (t == lens_lv[0].t || t == lens_lv[1].t) return 1;
    if (u != 2)
      for (int j = 0; j < 5; j++)
        if (t == lv[j].t) return 1;
  }
  return 0;
}

// Pixel rows from `py` (pixels from the window's top) to its foot the same to the byte in two readings.
static int foot_same(const unsigned char *a, const unsigned char *b, int py) {
  return memcmp(a, b, (size_t)(fb_h - py) * fb_w * 4) == 0;
}

// The luminance (0..1) at x, y points in a reading.
static double luma_at(const unsigned char *px, double x, double y) {
  const unsigned char *p = px + ((fb_h - 1 - (int)(y * S)) * fb_w + (int)(x * S)) * 4;
  return (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255.0;
}

int main(void) {
  EGLDisplay d = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, NULL, NULL)) {
    LOG("no EGL display (surfaceless)");
    return 1;
  }
  eglBindAPI(EGL_OPENGL_ES_API);
  static const EGLint want[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
  EGLConfig cfg = NULL;
  EGLint n = 0;
  eglChooseConfig(d, want, &cfg, 1, &n);
  static const EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
  EGLContext ctx = eglCreateContext(d, n > 0 ? cfg : EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs);
  if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
    LOG("no OpenGL ES 3 context");
    return 1;
  }
  gl_setup();
  // the surface: a framebuffer of the test's, drawn into as the window's is (offscreen 0)
  fb_w = W * S;
  fb_h = H * S;
  cur_w = W;
  cur_h = H;
  cur_scale = S;
  GLuint surface_tex, surface;
  glGenTextures(1, &surface_tex);
  glBindTexture(GL_TEXTURE_2D, surface_tex);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
  glGenFramebuffers(1, &surface);
  glBindFramebuffer(GL_FRAMEBUFFER, surface);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, surface_tex, 0);
  CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
  target_fb = surface;
  CHECK(offscreen == 0);

  // Perf-35 / Perf-37: lazy shader compilation, compact program groups, scissor glClear partial-redraw ground.
  {
    CHECK(progs[MB_PROG_FROSTED].p == 0 && progs[MB_PROG_LIQUID_MERGED].p == 0 &&
          progs[MB_PROG_LIQUID_SINGLE].p == 0 && progs[MB_PROG_LENS].p == 0 &&
          post == 0 && ad_prog == 0);

    // Seed a 4x4 glyph cell in atlas (unit 0) and a temporary 2x2 RGBA image for kind 4 and kind 9.
    static const unsigned char glyph_px[16] = {
        255, 255, 255, 255, 255, 200, 200, 255, 255, 200, 200, 255, 255, 255, 255, 255};
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, atlas);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RED, GL_UNSIGNED_BYTE, glyph_px);

    static const unsigned char img_px[16] = {
        220, 40, 60, 255, 40, 210, 80, 255, 50, 90, 230, 255, 240, 220, 40, 255};
    glGenTextures(1, &picture_one);
    glBindTexture(GL_TEXTURE_2D, picture_one);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, img_px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    double ng[4 * MB_INST];
    // 0: kind 0 rect
    rect_at(ng, 6, 8, 22, 18, 0, 0.85, 0.25, 0.15, 0);
    ng[36] = ng[37] = ng[38] = ng[39] = 4.0;
    // 1: kind 4 image
    rect_at(ng + 1 * MB_INST, 34, 8, 24, 18, 4, 1.0, 1.0, 1.0, 1);
    ng[1 * MB_INST + 12] = 0.0; ng[1 * MB_INST + 13] = 0.0;
    ng[1 * MB_INST + 14] = 1.0; ng[1 * MB_INST + 15] = 1.0;
    // 2: kind 1 glyph
    rect_at(ng + 2 * MB_INST, 66, 10, 16, 16, 1, 0.12, 0.22, 0.88, 0);
    ng[2 * MB_INST + 12] = 0.0; ng[2 * MB_INST + 13] = 0.0;
    ng[2 * MB_INST + 14] = 4.0; ng[2 * MB_INST + 15] = 4.0;
    // 3: kind 9 native view picture
    rect_at(ng + 3 * MB_INST, 12, 36, 40, 24, 9, 1.0, 1.0, 1.0, 1);
    ng[3 * MB_INST + 12] = 0.0; ng[3 * MB_INST + 13] = 0.0;
    ng[3 * MB_INST + 14] = 1.0; ng[3 * MB_INST + 15] = 1.0;
    ng[3 * MB_INST + 36] = ng[3 * MB_INST + 37] = ng[3 * MB_INST + 38] = ng[3 * MB_INST + 39] = 6.0;

    for (int oo = 0; oo <= 1; oo++) {
      over_other = oo;
      // Whole-screen draw
      ng[0] = 6;
      gl_present(ng, 4, 0.12, 0.22, 0.32);
      CHECK(surface_as_whole(surface));
      // Prime canvas with dirty rect, then trigger partial redraw (cut_on == 1)
      ng[0] = 8;
      mb_host_render_dirty(4, 6, 28, 22);
      gl_present(ng, 4, 0.12, 0.22, 0.32);
      CHECK(canvas_ok == 1);
      CHECK(surface_as_whole(surface));
      ng[0] = 10;
      ng[3 * MB_INST + 0] = 16;
      mb_host_render_dirty(6, 6, 30, 22);
      mb_host_render_dirty(10, 34, 48, 28);
      gl_present(ng, 4, 0.12, 0.22, 0.32);
      CHECK(canvas_ok == 1);
      CHECK(surface_as_whole(surface));
    }

    CHECK(progs[MB_PROG_FROSTED].p == 0 && progs[MB_PROG_LIQUID_MERGED].p == 0 &&
          progs[MB_PROG_LIQUID_SINGLE].p == 0 && progs[MB_PROG_LENS].p == 0 &&
          post == 0 && ad_prog == 0);
    CHECK(progs[MB_PROG_UI].p != 0);

    // Restore clean state for subsequent tests (which assert canvas_fb == 0 and picture_one == 0).
    over_other = 0;
    glDeleteTextures(1, &picture_one);
    picture_one = 0;
    if (canvas_fb) {
      glDeleteFramebuffers(1, &canvas_fb);
      glDeleteTextures(1, &canvas_tex);
      canvas_lost();
    }
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
  }

  // A frame drawn whole goes straight onto the surface: no canvas made, none holding a frame.
  double two[2 * MB_INST];
  rect_at(two, 10, 10, 20, 20, 0, 0.9, 0.2, 0.1, 0);
  rect_at(two + MB_INST, 60, 40, 20, 20, 0, 0.1, 0.8, 0.3, 0);
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_fb == 0);
  CHECK(canvas_ok == 0);
  CHECK(surface_as_whole(surface));

  // One said to differ in a part: the canvas made, drawn whole into it first (it held no frame), then shown; the next
  // drawn in its parts alone. The surface each time the same to the byte as the frame drawn whole.
  two[0] = 12;
  mb_host_render_dirty(8, 8, 26, 24);
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_fb != 0);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));
  two[0] = 14;
  two[MB_INST + 1] = 44;
  mb_host_render_dirty(10, 8, 26, 24);
  mb_host_render_dirty(58, 38, 24, 28);
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));
  // (and one whole again after: straight onto the surface, the canvas left holding no frame)
  two[0] = 16;
  gl_present(two, 2, 0.1, 0.2, 0.3);
  CHECK(canvas_ok == 0);
  CHECK(surface_as_whole(surface));

  // Frames handed over from another thread (frame_mail.h, Android's two), drawn in their parts as they say. One taken
  // only to read back (Android's glSync, the app waiting on a pixel of it) is never on the surface: what it said differs
  // is not what the next drawn goes by, nor is anything left of it there, and the canvas no longer holds the frame
  // before. So the next drawn, which says only its own part, is drawn whole into the canvas: the surface then is what it
  // is drawn whole, the part the one read back changed too. So too where the one read back is drawn again first
  // (Native.redraw: a native view's picture changed).
  hand(two, 2, 10, 8, 30, 30);
  take(1);
  CHECK(surface_as_whole(surface));
  two[MB_INST + 1] = 46;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));
  two[0] = 20;
  hand(two, 2, 10, 8, 32, 24);
  take(0);
  draw_kept_read();
  glBindFramebuffer(GL_FRAMEBUFFER, surface);
  CHECK(canvas_ok == 0);
  CHECK(dirty_told == 0 && dirty_whole == 0 && dirty_n == 0);
  two[MB_INST + 1] = 40;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(surface_as_whole(surface));
  two[0] = 24;
  hand(two, 2, 18, 8, 28, 24);
  take(0);
  draw_kept_read();
  draw_kept();
  CHECK(dirty_told == 0);
  two[MB_INST + 1] = 44;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(surface_as_whole(surface));
  // (and the canvas holds the frame again: the one after drawn in its parts alone, the same)
  two[MB_INST + 1] = 42;
  hand(two, 2, 58, 38, 24, 30);
  take(1);
  CHECK(canvas_ok == 1);
  CHECK(surface_as_whole(surface));

  // The blur under glass kept while what is drawn under it is the same: what is over it changing makes none again;
  // what is under it changing does.
  double g3[3 * MB_INST];
  rect_at(g3, 10, 10, 60, 40, 0, 0.9, 0.1, 0.1, 0);
  rect_at(g3 + MB_INST, 20, 20, 40, 30, 5, 1, 1, 1, -2);
  g3[MB_INST + 7] = 6;
  g3[MB_INST + 11] = 0.5;
  rect_at(g3 + 2 * MB_INST, 80, 60, 10, 10, 0, 0.1, 0.1, 0.9, 0);
  int made = blurs_made;
  gl_present(g3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(kept_ok == 1);
  g3[2 * MB_INST + 0] = 84;  // over the glass: moved
  gl_present(g3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(kept_ok == 1);
  g3[0] = 12;  // under it: moved
  gl_present(g3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 2);
  CHECK(kept_ok == 1);

  // A picture under it with no texture yet (drawn without it): that blur is not kept as what is under it; once the
  // picture has its texture, it is made and kept.
  double p3[3 * MB_INST];
  memcpy(p3, g3, sizeof p3);
  rect_at(p3, 10, 10, 60, 40, 4, 1, 1, 1, 1);
  p3[12] = 0;
  p3[13] = 0;
  p3[14] = 1;
  p3[15] = 1;
  gl_present(p3, 3, 0.1, 0.2, 0.3);
  CHECK(kept_ok == 0);
  CHECK(pictures_missing == 1);
  static const unsigned char px[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
  glGenTextures(1, &picture_one);
  glBindTexture(GL_TEXTURE_2D, picture_one);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  made = blurs_made;
  p3[2 * MB_INST + 0] = 86;
  gl_present(p3, 3, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(kept_ok == 1);
  CHECK(pictures_missing == 0);

  // Three groups of glass on one screen (frosted at the top, liquid in the middle, frosted at the foot, each with
  // something of its own under it, a caret over all): each keeps its own blur. A frame where only what is over them
  // moves makes none; one where something moves under the middle one alone makes that one's again, the others kept.
  // The surface each time the same to the byte as the frame drawn whole with every blur made anew.
  double s3[8 * MB_INST];
  rect_at(s3, 0, 0, W, H, 0, 0.95, 0.95, 0.9, 0);
  rect_at(s3 + 1 * MB_INST, 8, 4, 26, 8, 0, 0.9, 0.1, 0.1, 0);
  rect_at(s3 + 2 * MB_INST, 5, 2, 36, 10, 5, 1, 1, 1, -2);
  s3[2 * MB_INST + 7] = 2;
  s3[2 * MB_INST + 11] = 0.5;
  rect_at(s3 + 3 * MB_INST, 62, 32, 20, 8, 0, 0.1, 0.7, 0.2, 0);
  rect_at(s3 + 4 * MB_INST, 60, 30, 30, 12, 6, 1, 1, 1, -3);
  s3[4 * MB_INST + 4] = 6;
  s3[4 * MB_INST + 7] = 2;
  s3[4 * MB_INST + 11] = 0.3;
  s3[4 * MB_INST + 21] = 2;
  s3[4 * MB_INST + 23] = 1;
  rect_at(s3 + 5 * MB_INST, 10, 60, 25, 6, 0, 0.2, 0.2, 0.9, 0);
  rect_at(s3 + 6 * MB_INST, 5, 57, 40, 12, 5, 1, 1, 1, -4);
  s3[6 * MB_INST + 7] = 2;
  s3[6 * MB_INST + 11] = 0.5;
  rect_at(s3 + 7 * MB_INST, 90, 65, 2, 6, 0, 0, 0, 0, 0);
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  LOG("three groups, first frame: %d blurs", blurs_made - made);
  CHECK(blurs_made == made + 3);
  CHECK(surface_as_fresh(surface));
  for (int i = 0; i < 3; i++) {
    s3[7 * MB_INST + 1] = 62 + i;  // the caret: moved
    made = blurs_made;
    gl_present(s3, 8, 0.1, 0.2, 0.3);
    LOG("three groups, the caret moved: %d blurs", blurs_made - made);
    CHECK(blurs_made == made);
    CHECK(kept_ok == 1);
    CHECK(surface_as_fresh(surface));
  }
  s3[3 * MB_INST + 0] = 64;  // under the liquid glass alone: moved
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  LOG("three groups, what is under the middle one moved: %d blurs", blurs_made - made);
  CHECK(blurs_made == made + 1);
  CHECK(surface_as_fresh(surface));
  s3[7 * MB_INST + 1] = 60;
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made);
  CHECK(surface_as_fresh(surface));
  s3[1 * MB_INST + 0] = 9;  // under the top one: moved, that one's alone made again
  made = blurs_made;
  gl_present(s3, 8, 0.1, 0.2, 0.3);
  CHECK(blurs_made == made + 1);
  CHECK(surface_as_fresh(surface));

  // Fourteen independent glass groups of mixed sizes and blur radii on one screen: all 14 stay cached when only the
  // top-level caret moves (blurs_made delta == 0) and match a fresh render byte-for-byte.
  {
    double g14[16 * MB_INST];
    static const double blurs[4] = {1.0, 3.0, 7.0, 16.0};
    rect_at(g14, 0, 0, W, H, 0, 0.92, 0.90, 0.88, 0);
    for (int i = 0; i < 14; i++) {
      int col = i % 7, row = i / 7;
      double gx = 2 + col * 13;
      double gy = 2 + row * 32;
      double gw = 8 + i;
      double gh = 6 + i;
      double *d = g14 + (i + 1) * MB_INST;
      rect_at(d, gx, gy, gw, gh, 5, 1, 1, 1, -(101 + i));
      d[7] = blurs[i % 4];
      d[11] = 0.4;
    }
    rect_at(g14 + 15 * MB_INST, 92, 66, 2, 6, 0, 0, 0, 0, 0);
    glass_free();
    made = blurs_made;
    gl_present(g14, 16, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 14);
    CHECK(surface_as_whole(surface));
    g14[15 * MB_INST + 0] = 94;  // only top-level caret moves
    made = blurs_made;
    gl_present(g14, 16, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made);
    CHECK(kept_ok == 1);
    CHECK(surface_as_fresh(surface));
  }

  // What drawing holds beyond its frames given back: the trim lets go of glass's textures and the read back's
  // framebuffer; glass's textures go once MB_GLASS_IDLE frames in a row drew none. Each made again as it is next
  // needed, the surface then the same to the byte as the frame drawn whole.
  {
    double g1[2 * MB_INST];
    rect_at(g1, 10, 10, 40, 20, 0, 0.9, 0.1, 0.1, 0);
    rect_at(g1 + MB_INST, 5, 5, 50, 25, 6, 1, 1, 1, -5);
    g1[MB_INST + 4] = 6;
    g1[MB_INST + 7] = 2;
    g1[MB_INST + 11] = 0.3;
    g1[MB_INST + 21] = 2;
    g1[MB_INST + 23] = 1;
    glass_forget();
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(lv[0].t != 0 && lv_w > 0);
    CHECK(slots[0].bt != 0);
    CHECK(surface_as_fresh(surface));
    // the same capture frosted (kind 5), kept in the same slot
    g1[MB_INST + 5] = 5;
    g1[0] = 11;
    glass_forget();
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(slots[0].bt != 0);
    CHECK(surface_as_fresh(surface));

    CHECK(read_fb != 0);
    mb_render_trim();
    CHECK(read_fb == 0 && read_tex == 0);
    CHECK(lv[0].t == 0 && lv[4].t == 0 && lv_w == 0 && lv_h == 0);
    for (int i = 0; i < MB_GLASS_SLOTS; i++) CHECK(slots[i].bt == 0 && slots[i].under == NULL);
    g1[0] = 12;
    made = blurs_made;
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 1);
    CHECK(lv[0].t != 0);
    CHECK(surface_as_fresh(surface));

    // frames with no glass: glass's textures kept till the MB_GLASS_IDLE-th, then let go
    double plain[MB_INST];
    rect_at(plain, 10, 10, 40, 20, 0, 0.9, 0.1, 0.1, 0);
    for (int i = 1; i <= MB_GLASS_IDLE; i++) {
      plain[0] = 10 + i % 20;
      gl_present(plain, 1, 0.1, 0.2, 0.3);
      if (i == MB_GLASS_IDLE - 1) CHECK(lv[0].t != 0 && slots[0].bt != 0);
    }
    CHECK(lv[0].t == 0 && lv_w == 0);
    for (int i = 0; i < MB_GLASS_SLOTS; i++) CHECK(slots[i].bt == 0);
    g1[0] = 13;
    made = blurs_made;
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 1);
    CHECK(surface_as_fresh(surface));
    // a frame with glass among those without keeps them: the count starts again
    for (int i = 1; i < MB_GLASS_IDLE; i++) {
      plain[0] = 10 + i % 20;
      gl_present(plain, 1, 0.1, 0.2, 0.3);
    }
    g1[0] = 14;
    gl_present(g1, 2, 0.1, 0.2, 0.3);
    for (int i = 1; i < MB_GLASS_IDLE; i++) {
      plain[0] = 10 + i % 20;
      gl_present(plain, 1, 0.1, 0.2, 0.3);
    }
    CHECK(lv[0].t != 0);
  }

  // Unmerged liquid glass (kind 6, a[23] <= 0):
  // (1) single shape with merge=0 (tight quad + direct sd_rr) matches merge=1e-7 (merged_liquid + sd_group, same float32 quad bounds) byte-for-byte;
  // (2) two unmerged liquid shapes separated by a shadow (kind 2) sharing one capture make only 1 blur and preserve each
  //     instance's own spot, matching separate captures byte-for-byte at k == 0.
  {
    double eq[2 * MB_INST];
    rect_at(eq, 0, 0, W, H, 0, 0.85, 0.30, 0.20, 0);
    rect_at(eq + MB_INST, 18, 22, 54, 24, 6, 1, 1, 1, -9);
    eq[MB_INST + 4] = 12;
    eq[MB_INST + 6] = 1;
    eq[MB_INST + 7] = 2;
    eq[MB_INST + 11] = 0.25;
    eq[MB_INST + 12] = 0.8;
    eq[MB_INST + 13] = 8;
    eq[MB_INST + 14] = 0;
    eq[MB_INST + 15] = 1;
    eq[MB_INST + 21] = 4;
    eq[MB_INST + 22] = 0.2;
    eq[MB_INST + 23] = 0;
    glass_forget();
    gl_present(eq, 2, 0.1, 0.2, 0.3);
    unsigned char *px_single = pixels_of_fb(surface);

    eq[MB_INST + 23] = 1e-7;
    glass_forget();
    gl_present(eq, 2, 0.1, 0.2, 0.3);
    unsigned char *px_merged = pixels_of_fb(surface);
    CHECK(memcmp(px_single, px_merged, (size_t)fb_w * fb_h * 4) == 0);
    free(px_single);
    free(px_merged);

    double lq[5 * MB_INST];
    rect_at(lq, 0, 0, W, H, 0, 0.92, 0.90, 0.85, 0);
    rect_at(lq + 1 * MB_INST, 10, 46, 76, 18, 0, 0.85, 0.25, 0.20, 0);
    // left capsule (no spot, merge=0)
    rect_at(lq + 2 * MB_INST, 6, 48, 30, 14, 6, 1, 1, 1, -9);
    lq[2 * MB_INST + 4] = 7;
    lq[2 * MB_INST + 6] = 1;
    lq[2 * MB_INST + 7] = 1.5;  // sp = 3.0 -> k == 0
    lq[2 * MB_INST + 11] = 0.25;
    lq[2 * MB_INST + 12] = 0.8;
    lq[2 * MB_INST + 13] = 6;
    lq[2 * MB_INST + 14] = 0;
    lq[2 * MB_INST + 15] = 1;
    lq[2 * MB_INST + 21] = 2;
    lq[2 * MB_INST + 22] = 0;
    lq[2 * MB_INST + 23] = 0;
    // shadow between the two shapes (outside the right disc's capture box)
    rect_at(lq + 3 * MB_INST, 6, 48, 10, 6, 2, 0, 0, 0, 0);
    lq[3 * MB_INST + 7] = 1;
    lq[3 * MB_INST + 11] = 0.2;
    // right disc (with its own spot, merge=0, sharing capture -9)
    rect_at(lq + 4 * MB_INST, 68, 48, 18, 14, 6, 1, 1, 1, -9);
    lq[4 * MB_INST + 4] = 7;
    lq[4 * MB_INST + 6] = 1;
    lq[4 * MB_INST + 7] = 1.5;
    lq[4 * MB_INST + 11] = 0.25;
    lq[4 * MB_INST + 12] = 0.8;
    lq[4 * MB_INST + 13] = 6;
    lq[4 * MB_INST + 14] = 537.0 * 4096.0 + 528.0 + 1.0;
    lq[4 * MB_INST + 15] = 1;
    lq[4 * MB_INST + 21] = 2;
    lq[4 * MB_INST + 22] = 0;
    lq[4 * MB_INST + 23] = 0;

    glass_forget();
    made = blurs_made;
    gl_present(lq, 5, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 1);
    unsigned char *px_lq_shared = pixels_of_fb(surface);

    lq[2 * MB_INST + 20] = -10;
    lq[4 * MB_INST + 20] = -11;
    glass_forget();
    made = blurs_made;
    gl_present(lq, 5, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 2);
    unsigned char *px_lq_sep = pixels_of_fb(surface);
    CHECK(memcmp(px_lq_shared, px_lq_sep, (size_t)fb_w * fb_h * 4) == 0);
    free(px_lq_shared);
    free(px_lq_sep);
  }

  // Asymmetric 4-corner merged_liquid (rr = 14,14,0,0 sheet merged with pill) + Glass::clear() micro-veil vs pure lens:
  {
    double as[3 * MB_INST];
    rect_at(as, 0, 0, W, H, 0, 0.10, 0.12, 0.16, 0);
    rect_at(as + 1 * MB_INST, 10, 20, 48, 40, 6, 1, 1, 1, -12);
    as[1 * MB_INST + 4] = 14;
    as[1 * MB_INST + 6] = 1;
    as[1 * MB_INST + 7] = 1;
    as[1 * MB_INST + 11] = 0.25;
    as[1 * MB_INST + 12] = 0.55;
    as[1 * MB_INST + 13] = 8;
    as[1 * MB_INST + 15] = 1;
    as[1 * MB_INST + 21] = 6;
    as[1 * MB_INST + 22] = 0.18;
    as[1 * MB_INST + 23] = 8;
    as[1 * MB_INST + 36] = 14;
    as[1 * MB_INST + 37] = 14;
    as[1 * MB_INST + 38] = 0;
    as[1 * MB_INST + 39] = 0;
    rect_at(as + 2 * MB_INST, 62, 28, 20, 20, 6, 1, 1, 1, -12);
    as[2 * MB_INST + 4] = 10;
    as[2 * MB_INST + 6] = 1;
    as[2 * MB_INST + 7] = 1;
    as[2 * MB_INST + 11] = 0.25;
    as[2 * MB_INST + 12] = 0.55;
    as[2 * MB_INST + 13] = 8;
    as[2 * MB_INST + 15] = 1;
    as[2 * MB_INST + 21] = 6;
    as[2 * MB_INST + 22] = 0.18;
    as[2 * MB_INST + 23] = 8;
    as[2 * MB_INST + 36] = 10;
    as[2 * MB_INST + 37] = 10;
    as[2 * MB_INST + 38] = 10;
    as[2 * MB_INST + 39] = 10;

    glass_forget();
    gl_present(as, 3, 0.10, 0.12, 0.16);
    unsigned char *px_as = pixels_of_fb(surface);
    // RGBA8 bottom-up at scale 2
    unsigned char *bg_p = px_as + ((fb_h - 1 - 6) * fb_w + 6) * 4;
    unsigned char *tl_p = px_as + ((fb_h - 1 - 44) * fb_w + 24) * 4;  // (12, 22) outside top-left rounded corner (r=14)
    unsigned char *bl_p = px_as + ((fb_h - 1 - 116) * fb_w + 24) * 4; // (12, 58) inside bottom-left square corner (r=0)
    CHECK(abs((int)tl_p[0] - (int)bg_p[0]) <= 2 && abs((int)tl_p[1] - (int)bg_p[1]) <= 2);
    CHECK((int)bl_p[0] > (int)bg_p[0] + 40 && (int)bl_p[1] > (int)bg_p[1] + 40);
    free(px_as);

    double cl[3 * MB_INST];
    rect_at(cl, 0, 0, W, H, 0, 0.08, 0.08, 0.10, 0);
    rect_at(cl + 1 * MB_INST, 8, 15, 36, 40, 6, 1, 1, 1, -13);
    cl[1 * MB_INST + 4] = 10;
    cl[1 * MB_INST + 6] = 1;
    cl[1 * MB_INST + 7] = 0;
    cl[1 * MB_INST + 11] = 26.0 / 255.0;
    cl[1 * MB_INST + 12] = 0.6;
    cl[1 * MB_INST + 13] = 6;
    cl[1 * MB_INST + 15] = 1;
    cl[1 * MB_INST + 21] = 8;
    cl[1 * MB_INST + 22] = 0;
    cl[1 * MB_INST + 23] = 0;
    rect_at(cl + 2 * MB_INST, 56, 15, 36, 40, 6, 1, 1, 1, -14);
    cl[2 * MB_INST + 4] = 10;
    cl[2 * MB_INST + 6] = 1;
    cl[2 * MB_INST + 7] = 0;
    cl[2 * MB_INST + 11] = 0.0;
    cl[2 * MB_INST + 12] = 0.6;
    cl[2 * MB_INST + 13] = 6;
    cl[2 * MB_INST + 15] = 1;
    cl[2 * MB_INST + 21] = 8;
    cl[2 * MB_INST + 22] = 0;
    cl[2 * MB_INST + 23] = 0;

    glass_forget();
    gl_present(cl, 3, 0.08, 0.08, 0.10);
    unsigned char *px_cl = pixels_of_fb(surface);
    unsigned char *cl_bg = px_cl + ((fb_h - 1 - 6) * fb_w + 6) * 4;
    unsigned char *cl_veil = px_cl + ((fb_h - 1 - 70) * fb_w + 52) * 4;   // (26, 35) center of Glass::clear()
    unsigned char *cl_lens = px_cl + ((fb_h - 1 - 70) * fb_w + 148) * 4;  // (74, 35) center of pure clear optical lens
    CHECK((int)cl_veil[1] >= 44 && (int)cl_veil[1] <= 62);
    // Native iOS 27 ClearGlassView applies subtle dark-backdrop volumetric lift (~+12/255 at rim=0.6)
    // while staying clearly more transparent than Glass::clear() (cl_veil ~52/255).
    CHECK((int)cl_lens[1] >= (int)cl_bg[1] && (int)cl_lens[1] <= (int)cl_bg[1] + 18 && (int)cl_lens[1] + 10 < (int)cl_veil[1]);
    free(px_cl);

    // Wave 3A (1): clear-lens optical zoom (slot 7 = -(zoom - 1.0)) magnifies centered backdrop
    double zm[3 * MB_INST];
    rect_at(zm, 0, 0, W, H, 0, 0.05, 0.05, 0.08, 0);
    // Red square centered at (50, 35), half-width 8pt -> x in [42, 58]
    rect_at(zm + 1 * MB_INST, 42, 27, 16, 16, 0, 0.95, 0.10, 0.10, 0);
    // Clear liquid lens (10, 10, 80, 50), center (50, 35), refraction = 0
    rect_at(zm + 2 * MB_INST, 10, 10, 80, 50, 6, 1, 1, 1, -15);
    zm[2 * MB_INST + 4] = 12;
    zm[2 * MB_INST + 6] = 1;
    zm[2 * MB_INST + 7] = 0.0;  // zoom = 1.0
    zm[2 * MB_INST + 11] = 0.0;
    zm[2 * MB_INST + 12] = 0.0;
    zm[2 * MB_INST + 13] = 4;
    zm[2 * MB_INST + 15] = 1;
    zm[2 * MB_INST + 21] = 0;
    zm[2 * MB_INST + 22] = 0;
    zm[2 * MB_INST + 23] = 0;

    glass_forget();
    gl_present(zm, 3, 0.05, 0.05, 0.08);
    unsigned char *px_z1 = pixels_of_fb(surface);
    // Probe (59, 35) -> (118, 70) at 2x: outside [42, 58] at zoom=1.0 -> dark background
    unsigned char *z1_p = px_z1 + ((fb_h - 1 - 70) * fb_w + 118) * 4;
    CHECK((int)z1_p[0] < 40);
    free(px_z1);

    zm[2 * MB_INST + 7] = -0.25;  // zoom = 1.25 -> sampleBase.x = 50 + 9/1.25 = 57.2 (inside red square!)
    glass_forget();
    gl_present(zm, 3, 0.05, 0.05, 0.08);
    unsigned char *px_z2 = pixels_of_fb(surface);
    unsigned char *z2_p = px_z2 + ((fb_h - 1 - 70) * fb_w + 118) * 4;
    CHECK((int)z2_p[0] > 200);
    free(px_z2);

    // Wave 3A (2): global ambient light_angle rotates specular glint by 90 deg and restores bit-exact at 0.0
    double la_inst[2 * MB_INST];
    rect_at(la_inst, 0, 0, W, H, 0, 0.10, 0.10, 0.12, 0);
    rect_at(la_inst + 1 * MB_INST, 25, 10, 50, 50, 6, 0.12, 0.12, 0.12, -16);
    la_inst[1 * MB_INST + 4] = 12;
    la_inst[1 * MB_INST + 6] = 1;
    la_inst[1 * MB_INST + 7] = 1.0;
    la_inst[1 * MB_INST + 11] = 0.5;
    la_inst[1 * MB_INST + 12] = 1.0;
    la_inst[1 * MB_INST + 13] = 8;
    la_inst[1 * MB_INST + 15] = 1;
    la_inst[1 * MB_INST + 21] = 0;
    la_inst[1 * MB_INST + 22] = 0;
    la_inst[1 * MB_INST + 23] = 0;

    mb_host_glass_light_angle(0.0);
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la0 = pixels_of_fb(surface);
    // Top edge (50, 10.5) -> (100, 21); Left edge (25.5, 35) -> (51, 70)
    int top0 = (int)px_la0[((fb_h - 1 - 21) * fb_w + 100) * 4 + 1];
    int left0 = (int)px_la0[((fb_h - 1 - 70) * fb_w + 51) * 4 + 1];
    CHECK(top0 > left0 + 20);

    mb_host_glass_light_angle(1.5707963267948966);  // PI / 2
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la90 = pixels_of_fb(surface);
    int top90 = (int)px_la90[((fb_h - 1 - 21) * fb_w + 100) * 4 + 1];
    int left90 = (int)px_la90[((fb_h - 1 - 70) * fb_w + 51) * 4 + 1];
    int right90 = (int)px_la90[((fb_h - 1 - 70) * fb_w + 149) * 4 + 1];
    CHECK(left90 > top90 + 20);
    CHECK(right90 > top90 + 20);
    free(px_la90);

    mb_host_glass_light_angle(0.0);
    glass_forget();
    gl_present(la_inst, 2, 0.10, 0.10, 0.12);
    unsigned char *px_la0_again = pixels_of_fb(surface);
    CHECK(memcmp(px_la0, px_la0_again, (size_t)fb_w * (size_t)fb_h * 4) == 0);
    free(px_la0);
    free(px_la0_again);
  }

  // Neutral light liquid glass density (kind 6, !is_clear && !is_dark): alpha <= 0.41 keeps the 0.4032 baseline to the
  // byte (0xFDFCFD50 and 0xFDFCFD67 draw the same), while a dense veil (0xFDFCFDD9 ~ 0.851) emits its own alpha and
  // fades transmittance, lift and chroma to 0, so over black it is far brighter and over saturated blue it stays neutral.
  {
    double ld[2 * MB_INST];
    unsigned char *px_ld[5];
    // (alpha byte, backdrop r, g, b)
    static const double ld_case[5][4] = {
        {0x50, 0, 0, 0}, {0x67, 0, 0, 0}, {0xD9, 0, 0, 0}, {0xD9, 0.0, 0.4, 1.0}, {0xFF, 0.0, 0.4, 1.0}};
    for (int i = 0; i < 5; i++) {
      rect_at(ld, 0, 0, W, H, 0, ld_case[i][1], ld_case[i][2], ld_case[i][3], 0);
      rect_at(ld + MB_INST, 10, 10, 80, 50, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -17);
      ld[MB_INST + 4] = 12;
      ld[MB_INST + 6] = 1;
      ld[MB_INST + 7] = 1.0;
      ld[MB_INST + 11] = ld_case[i][0] / 255.0;
      ld[MB_INST + 12] = 0.0;
      ld[MB_INST + 13] = 4;
      ld[MB_INST + 15] = 1;
      ld[MB_INST + 21] = 0;
      ld[MB_INST + 22] = 0;
      ld[MB_INST + 23] = 0;
      glass_forget();
      gl_present(ld, 2, ld_case[i][1], ld_case[i][2], ld_case[i][3]);
      px_ld[i] = pixels_of_fb(surface);
    }
    // centre (50, 35) -> (100, 70) at 2x
    double ld_lum[5];
    for (int i = 0; i < 5; i++) {
      unsigned char *c = px_ld[i] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      ld_lum[i] = (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0;
      printf("gles_render: light glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n", (int)ld_case[i][0],
             ld_case[i][1], ld_case[i][2], ld_case[i][3], c[0], c[1], c[2], ld_lum[i]);
    }
    CHECK(memcmp(px_ld[0], px_ld[1], (size_t)fb_w * fb_h * 4) == 0);
    CHECK(ld_lum[1] >= 0.25 && ld_lum[1] <= 0.36);
    CHECK(ld_lum[2] >= 0.80 && ld_lum[2] > ld_lum[1] + 0.40);
    CHECK(px_ld[3][((fb_h - 1 - 70) * fb_w + 100) * 4 + 0] >= (int)(0.72 * 255.0 + 0.5));
    unsigned char *c_ff = px_ld[4] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
    CHECK(abs((int)c_ff[0] - 253) <= 4 && abs((int)c_ff[1] - 252) <= 4 && abs((int)c_ff[2] - 253) <= 4);
    for (int i = 0; i < 5; i++) free(px_ld[i]);
  }

  // Neutral dark liquid glass density (kind 6, is_dark): alpha <= 0.41 keeps the regular baseline to the byte
  // (0x20202050 and 0x20202067 draw the same), while dense veils (0x202020BF 75%, 0x202020D9 85%) fade
  // transmittance, lift and chroma toward 0, so over white they stay dark for white ink and over saturated blue
  // chroma is cleanly attenuated.
  {
    double dd[2 * MB_INST];
    unsigned char *px_dd[5];
    // (alpha byte, backdrop r, g, b)
    static const double dd_case[5][4] = {
        {0x50, 1, 1, 1}, {0x67, 1, 1, 1}, {0xBF, 1, 1, 1}, {0xD9, 1, 1, 1}, {0xD9, 0.0, 0.4, 1.0}};
    for (int i = 0; i < 5; i++) {
      rect_at(dd, 0, 0, W, H, 0, dd_case[i][1], dd_case[i][2], dd_case[i][3], 0);
      rect_at(dd + MB_INST, 10, 10, 80, 50, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -17);
      dd[MB_INST + 4] = 12;
      dd[MB_INST + 6] = 1;
      dd[MB_INST + 7] = 1.0;
      dd[MB_INST + 11] = dd_case[i][0] / 255.0;
      dd[MB_INST + 12] = 0.0;
      dd[MB_INST + 13] = 4;
      dd[MB_INST + 15] = 1;
      dd[MB_INST + 21] = 0;
      dd[MB_INST + 22] = 0;
      dd[MB_INST + 23] = 0;
      glass_forget();
      gl_present(dd, 2, dd_case[i][1], dd_case[i][2], dd_case[i][3]);
      px_dd[i] = pixels_of_fb(surface);
    }
    // centre (50, 35) -> (100, 70) at 2x
    double dd_lum[5];
    for (int i = 0; i < 5; i++) {
      unsigned char *c = px_dd[i] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      dd_lum[i] = (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255.0;
      printf("gles_render: dark glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n", (int)dd_case[i][0],
             dd_case[i][1], dd_case[i][2], dd_case[i][3], c[0], c[1], c[2], dd_lum[i]);
    }
    CHECK(memcmp(px_dd[0], px_dd[1], (size_t)fb_w * fb_h * 4) == 0);
    CHECK(dd_lum[1] >= 0.55 && dd_lum[1] <= 0.74);
    CHECK(dd_lum[2] <= 0.36 && dd_lum[2] <= dd_lum[1] - 0.25);
    CHECK(dd_lum[3] <= 0.30 && dd_lum[3] < dd_lum[2]);
    unsigned char *dd_blue = px_dd[4] + ((fb_h - 1 - 70) * fb_w + 100) * 4;
    CHECK(((double)dd_blue[2] - (double)dd_blue[0]) / 255.0 <= 0.28);
    for (int i = 0; i < 5; i++) free(px_dd[i]);
  }

  // Dedicated ONE_KIND=13 (unmerged liquid, merge=0) vs ONE_KIND=6 (merged liquid, merge=1e-7) with large flat
  // interior (inward >= 23), non-zero bevel/refraction/chroma/rim: must be byte-for-byte identical; and zero-copy
  // slot swap across frames + glass_free() must preserve identical pixels.
  {
    double lp[3 * MB_INST];
    rect_at(lp, 0, 0, W, H, 0, 0.12, 0.24, 0.48, 0);
    rect_at(lp + MB_INST, 20, 15, 60, 50, 0, 0.92, 0.35, 0.18, 0);
    rect_at(lp + 2 * MB_INST, 8, 6, 84, 68, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -18);
    lp[2 * MB_INST + 4] = 16;
    lp[2 * MB_INST + 6] = 1.0;
    lp[2 * MB_INST + 7] = 2.5;
    lp[2 * MB_INST + 11] = 0x67 / 255.0;
    lp[2 * MB_INST + 12] = 0.6;
    lp[2 * MB_INST + 13] = 14.0;
    lp[2 * MB_INST + 15] = 1.0;
    lp[2 * MB_INST + 21] = 18.0;
    lp[2 * MB_INST + 22] = 0.4;
    lp[2 * MB_INST + 23] = 0.0;
    glass_forget();
    gl_present(lp, 3, 0.12, 0.24, 0.48);
    unsigned char *px_single = pixels_of_fb(surface);

    lp[2 * MB_INST + 23] = 1e-7;
    glass_forget();
    gl_present(lp, 3, 0.12, 0.24, 0.48);
    unsigned char *px_merged = pixels_of_fb(surface);
    CHECK(progs[MB_PROG_FROSTED].p != 0 && progs[MB_PROG_LIQUID_MERGED].p != 0 && progs[MB_PROG_LIQUID_SINGLE].p != 0);
    CHECK(memcmp(px_single, px_merged, (size_t)fb_w * fb_h * 4) == 0);
    free(px_merged);

    lp[2 * MB_INST + 23] = 0.0;
    for (int step = 1; step <= 4; step++) {
      lp[MB_INST + 0] = 20 + step * 3;
      gl_present(lp, 3, 0.12, 0.24, 0.48);
    }
    glass_free();
    lp[MB_INST + 0] = 20;
    gl_present(lp, 3, 0.12, 0.24, 0.48);
    unsigned char *px_after_free = pixels_of_fb(surface);
    CHECK(memcmp(px_single, px_after_free, (size_t)fb_w * fb_h * 4) == 0);
    free(px_single);
    free(px_after_free);
  }

  // Wave 7: adaptive liquid glass (slot 14 = -1.0) + adaptive kind 10 neutral/chromatic ink:
  // 0: light glass over white (bg=1.0), 1: light glass over black (bg=0.0),
  // 2: light glass over a linear ~50% mid-tone (bg=0.72), 3: dark glass (0x20202067) over white (bg=1.0).
  {
    double ad[4 * MB_INST];
    // 4: light glass over Apple blue #007AFF -> dark ink flips white (sRGB luma 0.414 sat on the dark edge;
    //    the ink decision reads linear-ish luma c*c, 0.236, well inside the dark side)
    // 5: light glass over light gray #F5F5F7 -> stays light glass + dark ink
    struct { double bg, bg_g, bg_b; int dark_glass; double ink; } w7_cases[6] = {
      {1.0, 1.0, 1.0, 0, 0.11},
      {0.0, 0.0, 0.0, 0, 0.11},
      {0.72, 0.72, 0.72, 0, 0.11},
      {1.0, 1.0, 1.0, 1, 0.93},
      {0.0, 122.0 / 255.0, 1.0, 0, 0.11},
      {245.0 / 255.0, 245.0 / 255.0, 247.0 / 255.0, 0, 0.11},
    };
    for (int ci = 0; ci < 6; ci++) {
      double bg = w7_cases[ci].bg, bg_g = w7_cases[ci].bg_g, bg_b = w7_cases[ci].bg_b;
      int dg = w7_cases[ci].dark_glass;
      double ink = w7_cases[ci].ink;
      rect_at(ad, 0, 0, W, H, 0, bg, bg_g, bg_b, 0);
      rect_at(ad + MB_INST, 8, 6, 84, 68, 6,
              dg ? 32.0 / 255.0 : 253.0 / 255.0,
              dg ? 32.0 / 255.0 : 252.0 / 255.0,
              dg ? 32.0 / 255.0 : 253.0 / 255.0, -19);
      ad[MB_INST + 4] = 16;
      ad[MB_INST + 6] = 1.0;
      ad[MB_INST + 7] = 2.0;
      ad[MB_INST + 11] = 0x67 / 255.0;
      ad[MB_INST + 12] = 0.0;
      ad[MB_INST + 13] = 10.0;
      ad[MB_INST + 14] = -1.0;  // adaptive=true, no spot
      ad[MB_INST + 15] = 1.0;
      ad[MB_INST + 21] = 0.0;
      ad[MB_INST + 22] = 0.0;
      ad[MB_INST + 23] = 0.0;
      // Neutral line inside glass at y=28 (x=24..46)
      rect_at(ad + 2 * MB_INST, 20, 22, 30, 12, 10, ink, ink, ink, 0);
      ad[2 * MB_INST + 4] = 3.0;
      ad[2 * MB_INST + 12] = 0.1;
      ad[2 * MB_INST + 13] = 0.5;
      ad[2 * MB_INST + 14] = 0.9;
      ad[2 * MB_INST + 15] = 0.5;
      ad[2 * MB_INST + 21] = 50.0;
      ad[2 * MB_INST + 22] = 40.0;
      ad[2 * MB_INST + 23] = 34.0;
      // Chromatic accent line inside glass at y=52 (x=24..46)
      rect_at(ad + 3 * MB_INST, 20, 46, 30, 12, 10, 0.90, 0.30, 0.15, 0);
      ad[3 * MB_INST + 4] = 3.0;
      ad[3 * MB_INST + 12] = 0.1;
      ad[3 * MB_INST + 13] = 0.5;
      ad[3 * MB_INST + 14] = 0.9;
      ad[3 * MB_INST + 15] = 0.5;
      ad[3 * MB_INST + 21] = 50.0;
      ad[3 * MB_INST + 22] = 40.0;
      ad[3 * MB_INST + 23] = 34.0;
      glass_forget();
      gl_present(ad, 4, bg, bg_g, bg_b);
      unsigned char *px_ad = pixels_of_fb(surface);
      // Glass interior at (68, 40) -> (136, 80) at 2x (RGBA, y flipped)
      unsigned char *gp = px_ad + ((fb_h - 1 - 80) * fb_w + 136) * 4;
      double g_lum = (0.2126 * gp[0] + 0.7152 * gp[1] + 0.0722 * gp[2]) / 255.0;
      unsigned char *np = px_ad + ((fb_h - 1 - 56) * fb_w + 70) * 4;
      double n_lum = (0.2126 * np[0] + 0.7152 * np[1] + 0.0722 * np[2]) / 255.0;
      unsigned char *cp = px_ad + ((fb_h - 1 - 104) * fb_w + 70) * 4;
      printf("gles_render: wave7 case=%d bg=%.2f dg=%d glass=%.3f neutral_ink=%.3f chroma_rgb=%d,%d,%d\n",
             ci, bg, dg, g_lum, n_lum, cp[0], cp[1], cp[2]);
      if (ci == 0) {
        CHECK(g_lum > 0.75);
        CHECK(n_lum < 0.25);
      } else if (ci == 1) {
        CHECK(g_lum < 0.20);
        CHECK(n_lum > 0.80);
      } else if (ci == 2) {
        CHECK(g_lum > 0.55);
        CHECK(n_lum < 0.25);
      } else if (ci == 3) {
        CHECK(g_lum < 0.45);
        CHECK(n_lum > 0.85);
      } else if (ci == 4) {
        CHECK(n_lum > 0.70);
      } else {
        CHECK(g_lum > 0.75);
        CHECK(n_lum < 0.25);
      }
      CHECK((int)cp[0] > (int)cp[2] + 120);
      free(px_ad);
    }

    // Wave 7b: adaptive kind 0 translucent hover wash (pad.w < 0, 0x0000001C) inside adaptive=true light glass:
    // 0: white (bg=1.0) -> stays darkened; 1: black (bg=0.0) -> flips luminous white; 2: Apple blue #007AFF -> flips luminous white.
    {
      double ahov[3 * MB_INST];
      struct { double r, g, b; } hov_cases[3] = {
        {1.0, 1.0, 1.0},
        {0.0, 0.0, 0.0},
        {0.0, 122.0 / 255.0, 1.0},
      };
      for (int ci = 0; ci < 3; ci++) {
        double bg = hov_cases[ci].r, bg_g = hov_cases[ci].g, bg_b = hov_cases[ci].b;
        rect_at(ahov, 0, 0, W, H, 0, bg, bg_g, bg_b, 0);
        rect_at(ahov + MB_INST, 8, 6, 84, 68, 6,
                253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
        ahov[MB_INST + 4] = 16;
        ahov[MB_INST + 6] = 1.0;
        ahov[MB_INST + 7] = 2.0;
        ahov[MB_INST + 11] = 0x67 / 255.0;
        ahov[MB_INST + 12] = 0.0;
        ahov[MB_INST + 13] = 10.0;
        ahov[MB_INST + 14] = -1.0;
        ahov[MB_INST + 15] = 1.0;
        ahov[MB_INST + 21] = 0.0;
        ahov[MB_INST + 22] = 0.0;
        ahov[MB_INST + 23] = 0.0;
        // Adaptive kind 0 translucent dark hover disc (0x0000001C) on left half of glass
        rect_at(ahov + 2 * MB_INST, 16, 22, 32, 32, 0, 0.0, 0.0, 0.0, 0);
        ahov[2 * MB_INST + 4] = 16.0;
        ahov[2 * MB_INST + 11] = 0x1C / 255.0;
        ahov[2 * MB_INST + 21] = 50.0;
        ahov[2 * MB_INST + 22] = 40.0;
        ahov[2 * MB_INST + 23] = -34.0;
        glass_forget();
        gl_present(ahov, 3, bg, bg_g, bg_b);
        unsigned char *px_h = pixels_of_fb(surface);
        unsigned char *gp = px_h + ((fb_h - 1 - 80) * fb_w + 136) * 4;
        double g_lum = (0.2126 * gp[0] + 0.7152 * gp[1] + 0.0722 * gp[2]) / 255.0;
        unsigned char *hp = px_h + ((fb_h - 1 - 76) * fb_w + 64) * 4;
        double h_lum = (0.2126 * hp[0] + 0.7152 * hp[1] + 0.0722 * hp[2]) / 255.0;
        printf("gles_render: wave7b_hover case=%d glass=%.3f hover=%.3f delta=%+.3f\n",
               ci, g_lum, h_lum, h_lum - g_lum);
        if (ci == 0) {
          CHECK(h_lum < g_lum - 0.03);
        } else {
          CHECK(h_lum > g_lum + 0.08);
        }
        free(px_h);
      }
    }

    // Smooth fogging on adaptive flip: thin bright stripe over black is softened by dual-ring fog blur + higher darkDens
    double fg[3 * MB_INST];
    double fog_peaks[2] = {0.0, 0.0};
    for (int adaptive_on = 0; adaptive_on <= 1; adaptive_on++) {
      rect_at(fg, 0, 0, W, H, 0, 0.0, 0.0, 0.0, 0);
      // Place the thin 2pt white stripe at y=48 (off the 5-point luma sample cross at y=40 and y=40+/-17)
      rect_at(fg + MB_INST, 4, 47, 92, 2, 0, 1.0, 1.0, 1.0, 0);
      rect_at(fg + 2 * MB_INST, 8, 6, 84, 68, 6,
              adaptive_on ? 253.0 / 255.0 : 32.0 / 255.0,
              adaptive_on ? 252.0 / 255.0 : 32.0 / 255.0,
              adaptive_on ? 253.0 / 255.0 : 32.0 / 255.0, -20);
      fg[2 * MB_INST + 4] = 16;
      fg[2 * MB_INST + 6] = 1.0;
      fg[2 * MB_INST + 7] = 1.0;
      fg[2 * MB_INST + 11] = 0x67 / 255.0;
      fg[2 * MB_INST + 12] = 0.0;
      fg[2 * MB_INST + 13] = 10.0;
      fg[2 * MB_INST + 14] = adaptive_on ? -1.0 : 0.0;
      fg[2 * MB_INST + 15] = 1.0;
      fg[2 * MB_INST + 21] = 0.0;
      fg[2 * MB_INST + 22] = 0.0;
      fg[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(fg, 3, 0.0, 0.0, 0.0);
      unsigned char *px_fg = pixels_of_fb(surface);
      unsigned char *sp = px_fg + ((fb_h - 1 - 96) * fb_w + 100) * 4;  // (50, 48) on the bright 2pt stripe
      fog_peaks[adaptive_on] = (0.2126 * sp[0] + 0.7152 * sp[1] + 0.0722 * sp[2]) / 255.0;
      free(px_fg);
    }
    printf("gles_render: wave7 fog stripe peak plain_dark=%.3f adaptive_fog=%.3f\n",
           fog_peaks[0], fog_peaks[1]);
    CHECK(fog_peaks[1] < fog_peaks[0] - 0.08);
    CHECK(fog_peaks[1] <= 0.30);

    // Test A: wide 84x16pt adaptive capsule over deep navy #173255 with centered 16x10pt pure white "{less}" block
    // must resist ping-pong flipping (trimmed mean stays dark -> dark glass + white ink).
    double ta[4 * MB_INST];
    rect_at(ta, 0, 0, W, H, 0, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0, 0);
    rect_at(ta + MB_INST, 42, 31, 16, 10, 0, 1.0, 1.0, 1.0, 0);
    rect_at(ta + 2 * MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
    ta[2 * MB_INST + 4] = 8.0;
    ta[2 * MB_INST + 6] = 1.0;
    ta[2 * MB_INST + 7] = 2.0;
    ta[2 * MB_INST + 11] = 0x67 / 255.0;
    ta[2 * MB_INST + 12] = 0.0;
    ta[2 * MB_INST + 13] = 8.0;
    ta[2 * MB_INST + 14] = -1.0;
    ta[2 * MB_INST + 15] = 1.0;
    ta[2 * MB_INST + 21] = 0.0;
    ta[2 * MB_INST + 22] = 0.0;
    ta[2 * MB_INST + 23] = 0.0;
    rect_at(ta + 3 * MB_INST, 16, 30, 20, 12, 10, 0.11, 0.11, 0.11, 0);
    ta[3 * MB_INST + 4] = 3.0;
    ta[3 * MB_INST + 12] = 0.1;
    ta[3 * MB_INST + 13] = 0.5;
    ta[3 * MB_INST + 14] = 0.9;
    ta[3 * MB_INST + 15] = 0.5;
    ta[3 * MB_INST + 21] = 50.0;
    ta[3 * MB_INST + 22] = 36.0;
    ta[3 * MB_INST + 23] = 16.0;
    glass_forget();
    gl_present(ta, 4, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0);
    unsigned char *px_ta = pixels_of_fb(surface);
    unsigned char *ta_gp = px_ta + ((fb_h - 1 - 72) * fb_w + 148) * 4;  // (74, 36) glass over navy
    unsigned char *ta_np = px_ta + ((fb_h - 1 - 72) * fb_w + 52) * 4;   // (26, 36) neutral ink inside capsule
    double ta_g = (0.2126 * ta_gp[0] + 0.7152 * ta_gp[1] + 0.0722 * ta_gp[2]) / 255.0;
    double ta_n = (0.2126 * ta_np[0] + 0.7152 * ta_np[1] + 0.0722 * ta_np[2]) / 255.0;
    printf("gles_render: wave7 testA wide_less glass=%.3f ink=%.3f\n", ta_g, ta_n);
    CHECK(ta_g < 0.28);
    CHECK(ta_n > 0.80);
    free(px_ta);

    // Test B: cross-frame temporal smoothing + synchronized glass/ink + Schmitt hysteresis + auto-settle stop
    gl_set_fixed_dt(1.0 / 60.0);
    double tb[3 * MB_INST];
    rect_at(tb, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
    rect_at(tb + MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -22);
    tb[MB_INST + 4] = 8.0;
    tb[MB_INST + 6] = 1.0;
    tb[MB_INST + 7] = 2.0;
    tb[MB_INST + 11] = 0x67 / 255.0;
    tb[MB_INST + 12] = 0.0;
    tb[MB_INST + 13] = 8.0;
    tb[MB_INST + 14] = -1.0;
    tb[MB_INST + 15] = 1.0;
    tb[MB_INST + 21] = 0.0;
    tb[MB_INST + 22] = 0.0;
    tb[MB_INST + 23] = 0.0;
    rect_at(tb + 2 * MB_INST, 16, 30, 20, 12, 10, 0.11, 0.11, 0.11, 0);
    tb[2 * MB_INST + 4] = 3.0;
    tb[2 * MB_INST + 12] = 0.1;
    tb[2 * MB_INST + 13] = 0.5;
    tb[2 * MB_INST + 14] = 0.9;
    tb[2 * MB_INST + 15] = 0.5;
    tb[2 * MB_INST + 21] = 50.0;
    tb[2 * MB_INST + 22] = 36.0;
    tb[2 * MB_INST + 23] = 16.0;

    // Frame 0: pure white -> instant light state
    glass_forget();
    gl_present(tb, 3, 1.0, 1.0, 1.0);
    unsigned char *px_tb = pixels_of_fb(surface);
    double f0_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double f0_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB f0_white glass=%.3f ink=%.3f\n", f0_g, f0_n);
    CHECK(f0_g > 0.75);
    CHECK(f0_n < 0.25);

    // Frame 1: switch to deep navy #173255 -> smooth intermediate state
    tb[8] = 23.0 / 255.0; tb[9] = 50.0 / 255.0; tb[10] = 85.0 / 255.0;
    gl_present(tb, 3, tb[8], tb[9], tb[10]);
    px_tb = pixels_of_fb(surface);
    double f1_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double f1_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB f1_navy glass=%.3f ink=%.3f settling=%d\n", f1_g, f1_n, gl_adaptive_settling());
    CHECK(f1_g > 0.28 && f1_g < 0.72);
    CHECK(f1_n > 0.15 && f1_n < 0.75);
    CHECK(gl_adaptive_settling() == 1);

    // Step 25 more frames (~420ms): monotonic convergence to dark state
    double prev_g = f1_g, prev_n = f1_n;
    for (int s = 0; s < 25; s++) {
      gl_present(tb, 3, tb[8], tb[9], tb[10]);
      px_tb = pixels_of_fb(surface);
      double cg = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
      double cn = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
      free(px_tb);
      CHECK(cg <= prev_g + 0.015);
      CHECK(cn >= prev_n - 0.015);
      prev_g = cg;
      prev_n = cn;
    }
    printf("gles_render: wave7 testB f26_dark glass=%.3f ink=%.3f settling=%d\n", prev_g, prev_n, gl_adaptive_settling());
    CHECK(prev_g < 0.28);
    CHECK(prev_n > 0.85);

    // Schmitt hysteresis: bg=0.40 (in [0.36, 0.46]) for 25 frames stays dark
    tb[8] = 0.40; tb[9] = 0.40; tb[10] = 0.40;
    for (int s = 0; s < 25; s++) gl_present(tb, 3, 0.40, 0.40, 0.40);
    px_tb = pixels_of_fb(surface);
    double hyst_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double hyst_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB hyst_0.40 glass=%.3f ink=%.3f\n", hyst_g, hyst_n);
    CHECK(hyst_g < 0.40);
    CHECK(hyst_n > 0.80);

    // Return to bright bg=0.95: frame 1 intermediate, +26 frames settles back to light and stops settling
    tb[8] = 0.95; tb[9] = 0.95; tb[10] = 0.95;
    gl_present(tb, 3, 0.95, 0.95, 0.95);
    px_tb = pixels_of_fb(surface);
    double r1_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double r1_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB return_f1 glass=%.3f ink=%.3f\n", r1_g, r1_n);
    CHECK(r1_g > 0.30 && r1_g < 0.82);
    CHECK(r1_n > 0.20 && r1_n < 0.88);
    for (int s = 0; s < 26; s++) gl_present(tb, 3, 0.95, 0.95, 0.95);
    px_tb = pixels_of_fb(surface);
    double r_end_g = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 148) * 4 + 2]) / 255.0;
    double r_end_n = (0.2126 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 0] + 0.7152 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 1] + 0.0722 * px_tb[((fb_h - 1 - 72) * fb_w + 52) * 4 + 2]) / 255.0;
    free(px_tb);
    printf("gles_render: wave7 testB return_end glass=%.3f ink=%.3f settling=%d\n", r_end_g, r_end_n, gl_adaptive_settling());
    CHECK(r_end_g > 0.75);
    CHECK(r_end_n < 0.25);
    CHECK(gl_adaptive_settling() == 0);
    gl_set_fixed_dt(0.0);
    glass_forget();

    // Tests C, D, E on a 400x300 @ 1x surface so real-scale capsules (320x44pt large, 240x30pt small)
    // exercise the exact size gate (capHalf >= (140, 19)) and word-level sampling.
    {
      GLuint saved_fb = target_fb;
      int saved_fb_w = fb_w, saved_fb_h = fb_h;
      double saved_cur_w = cur_w, saved_cur_h = cur_h, saved_cur_scale = cur_scale;
      fb_w = 400; fb_h = 300; cur_w = 400; cur_h = 300; cur_scale = 1;
      GLuint big_tex = 0, big_fb = 0;
      glGenTextures(1, &big_tex);
      glBindTexture(GL_TEXTURE_2D, big_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &big_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
      CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
      target_fb = big_fb;

      unsigned char solid_glyph[16 * 16];
      memset(solid_glyph, 255, sizeof(solid_glyph));
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, atlas);
      glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 16, 16, 16, 16, GL_RED, GL_UNSIGNED_BYTE, solid_glyph);

      // Test C: wide 320x44pt adaptive light capsule spanning left 45% dark (#141418) + right 55% white (#FFFFFF).
      {
        double tc[9 * MB_INST];
        rect_at(tc, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(tc + MB_INST, 0, 0, 184, 300, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(tc + 2 * MB_INST, 40, 128, 320, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -23);
        tc[2 * MB_INST + 4] = 22.0;
        tc[2 * MB_INST + 6] = 1.0;
        tc[2 * MB_INST + 7] = 2.0;
        tc[2 * MB_INST + 11] = 0x67 / 255.0;
        tc[2 * MB_INST + 12] = 0.0;
        tc[2 * MB_INST + 13] = 14.0;
        tc[2 * MB_INST + 14] = -1.0;
        tc[2 * MB_INST + 15] = 1.0;
        tc[2 * MB_INST + 21] = 0.0;
        tc[2 * MB_INST + 22] = 0.0;
        tc[2 * MB_INST + 23] = 0.0;
        // 3: Left subtle ink (kind 10) at center (72, 150)
        rect_at(tc + 3 * MB_INST, 60, 140, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[3 * MB_INST + 4] = 4.0;
        tc[3 * MB_INST + 12] = 0.1; tc[3 * MB_INST + 13] = 0.5;
        tc[3 * MB_INST + 14] = 0.9; tc[3 * MB_INST + 15] = 0.5;
        tc[3 * MB_INST + 21] = 200.0; tc[3 * MB_INST + 22] = 150.0; tc[3 * MB_INST + 23] = 44.0;
        // 4: Left text glyph (kind 7) at center (104, 150)
        rect_at(tc + 4 * MB_INST, 96, 142, 16, 16, 7, 0.14, 0.15, 0.17, 0);
        tc[4 * MB_INST + 12] = 16.0; tc[4 * MB_INST + 13] = 16.0;
        tc[4 * MB_INST + 14] = 16.0; tc[4 * MB_INST + 15] = 16.0;
        tc[4 * MB_INST + 21] = 200.0; tc[4 * MB_INST + 22] = 150.0; tc[4 * MB_INST + 23] = 44.0;
        // 5: Left chromatic accent (kind 10) at center (136, 150)
        rect_at(tc + 5 * MB_INST, 124, 140, 24, 20, 10, 0.90, 0.30, 0.15, 0);
        tc[5 * MB_INST + 4] = 4.0;
        tc[5 * MB_INST + 12] = 0.1; tc[5 * MB_INST + 13] = 0.5;
        tc[5 * MB_INST + 14] = 0.9; tc[5 * MB_INST + 15] = 0.5;
        tc[5 * MB_INST + 21] = 200.0; tc[5 * MB_INST + 22] = 150.0; tc[5 * MB_INST + 23] = 44.0;
        // 6: Right subtle ink (kind 10) at center (232, 150)
        rect_at(tc + 6 * MB_INST, 220, 140, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[6 * MB_INST + 4] = 4.0;
        tc[6 * MB_INST + 12] = 0.1; tc[6 * MB_INST + 13] = 0.5;
        tc[6 * MB_INST + 14] = 0.9; tc[6 * MB_INST + 15] = 0.5;
        tc[6 * MB_INST + 21] = 200.0; tc[6 * MB_INST + 22] = 150.0; tc[6 * MB_INST + 23] = 44.0;
        // 7: Right text glyph (kind 7) at center (268, 150)
        rect_at(tc + 7 * MB_INST, 260, 142, 16, 16, 7, 0.14, 0.15, 0.17, 0);
        tc[7 * MB_INST + 12] = 16.0; tc[7 * MB_INST + 13] = 16.0;
        tc[7 * MB_INST + 14] = 16.0; tc[7 * MB_INST + 15] = 16.0;
        tc[7 * MB_INST + 21] = 200.0; tc[7 * MB_INST + 22] = 150.0; tc[7 * MB_INST + 23] = 44.0;
        // 8: Out-of-bd guard (kind 10) at (16, 16), outside capsule bd capture rect
        rect_at(tc + 8 * MB_INST, 4, 6, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[8 * MB_INST + 4] = 4.0;
        tc[8 * MB_INST + 12] = 0.1; tc[8 * MB_INST + 13] = 0.5;
        tc[8 * MB_INST + 14] = 0.9; tc[8 * MB_INST + 15] = 0.5;
        tc[8 * MB_INST + 21] = 200.0; tc[8 * MB_INST + 22] = 150.0; tc[8 * MB_INST + 23] = 44.0;
        for (int i = 0; i < 9; i++) { tc[i * MB_INST + 18] = 400.0; tc[i * MB_INST + 19] = 300.0; }

        gl_set_fixed_dt(1.0 / 60.0);
        glass_forget();
        gl_present(tc, 9, 1.0, 1.0, 1.0);
        unsigned char *px_tc = pixels_of_fb(big_fb);
        unsigned char *p_ls = px_tc + ((fb_h - 1 - 150) * fb_w + 72) * 4;
        unsigned char *p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
        unsigned char *p_lc = px_tc + ((fb_h - 1 - 150) * fb_w + 136) * 4;
        unsigned char *p_rs = px_tc + ((fb_h - 1 - 150) * fb_w + 232) * 4;
        unsigned char *p_rt = px_tc + ((fb_h - 1 - 150) * fb_w + 268) * 4;
        unsigned char *p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
        unsigned char *p_ob = px_tc + ((fb_h - 1 - 16) * fb_w + 16) * 4;
        double l_sub = (0.2126 * p_ls[0] + 0.7152 * p_ls[1] + 0.0722 * p_ls[2]) / 255.0;
        double l_txt = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
        double r_sub = (0.2126 * p_rs[0] + 0.7152 * p_rs[1] + 0.0722 * p_rs[2]) / 255.0;
        double r_txt = (0.2126 * p_rt[0] + 0.7152 * p_rt[1] + 0.0722 * p_rt[2]) / 255.0;
        double g_right = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
        double oob_sub = (0.2126 * p_ob[0] + 0.7152 * p_ob[1] + 0.0722 * p_ob[2]) / 255.0;
        printf("gles_render: wave7 testC half_dark l_sub=%.3f l_txt=%.3f r_sub=%.3f r_txt=%.3f g_right=%.3f oob=%.3f chroma=%d,%d,%d\n",
               l_sub, l_txt, r_sub, r_txt, g_right, oob_sub, p_lc[0], p_lc[1], p_lc[2]);
        CHECK(l_sub > 0.82);
        CHECK(l_txt > 0.82);
        CHECK(r_sub < 0.45);
        CHECK(r_txt < 0.45);
        CHECK(g_right > 0.75);
        CHECK(oob_sub < 0.45);
        CHECK((int)p_lc[0] > (int)p_lc[2] + 120);
        free(px_tc);

        // Expand dark backdrop from 45% to 100% across 20 frames + 10 settle frames:
        double min_l_sub = 1.0, min_l_txt = 1.0, end_r_sub = 0.0, end_g_right = 1.0;
        for (int s = 0; s < 30; s++) {
          double t = s < 20 ? (double)(s + 1) / 20.0 : 1.0;
          tc[MB_INST + 2] = 184.0 + (400.0 - 184.0) * t;
          gl_present(tc, 9, 1.0, 1.0, 1.0);
          px_tc = pixels_of_fb(big_fb);
          p_ls = px_tc + ((fb_h - 1 - 150) * fb_w + 72) * 4;
          p_lt = px_tc + ((fb_h - 1 - 150) * fb_w + 104) * 4;
          p_rs = px_tc + ((fb_h - 1 - 150) * fb_w + 232) * 4;
          p_rg = px_tc + ((fb_h - 1 - 150) * fb_w + 310) * 4;
          double cs = (0.2126 * p_ls[0] + 0.7152 * p_ls[1] + 0.0722 * p_ls[2]) / 255.0;
          double ct = (0.2126 * p_lt[0] + 0.7152 * p_lt[1] + 0.0722 * p_lt[2]) / 255.0;
          end_r_sub = (0.2126 * p_rs[0] + 0.7152 * p_rs[1] + 0.0722 * p_rs[2]) / 255.0;
          end_g_right = (0.2126 * p_rg[0] + 0.7152 * p_rg[1] + 0.0722 * p_rg[2]) / 255.0;
          if (cs < min_l_sub) min_l_sub = cs;
          if (ct < min_l_txt) min_l_txt = ct;
          free(px_tc);
        }
        printf("gles_render: wave7 testC scroll_to_full min_l_sub=%.3f min_l_txt=%.3f end_r_sub=%.3f end_g_right=%.3f\n",
               min_l_sub, min_l_txt, end_r_sub, end_g_right);
        CHECK(end_r_sub > 0.68);
        CHECK(end_g_right < 0.35);
      }

      // Test D: small 240x30pt adaptive capsule straddling white/dark horizontal edge:
      // disables local override so uppercase 'H' and lowercase 'o' stay dark (< 0.35) and match.
      {
        double td[5 * MB_INST];
        rect_at(td, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(td + MB_INST, 0, 152, 400, 148, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(td + 2 * MB_INST, 80, 135, 240, 30, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -24);
        td[2 * MB_INST + 4] = 15.0;
        td[2 * MB_INST + 6] = 1.0;
        td[2 * MB_INST + 7] = 2.0;
        td[2 * MB_INST + 11] = 0x67 / 255.0;
        td[2 * MB_INST + 12] = 0.0;
        td[2 * MB_INST + 13] = 12.0;
        td[2 * MB_INST + 14] = -1.0;
        td[2 * MB_INST + 15] = 1.0;
        rect_at(td + 3 * MB_INST, 180, 138, 12, 12, 7, 0.14, 0.15, 0.17, 0);
        td[3 * MB_INST + 12] = 16.0; td[3 * MB_INST + 13] = 16.0;
        td[3 * MB_INST + 14] = 16.0; td[3 * MB_INST + 15] = 16.0;
        td[3 * MB_INST + 21] = 200.0; td[3 * MB_INST + 22] = 150.0; td[3 * MB_INST + 23] = 30.0;
        rect_at(td + 4 * MB_INST, 196, 153, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        td[4 * MB_INST + 12] = 16.0; td[4 * MB_INST + 13] = 16.0;
        td[4 * MB_INST + 14] = 16.0; td[4 * MB_INST + 15] = 16.0;
        td[4 * MB_INST + 21] = 200.0; td[4 * MB_INST + 22] = 150.0; td[4 * MB_INST + 23] = 30.0;
        for (int i = 0; i < 5; i++) { td[i * MB_INST + 18] = 400.0; td[i * MB_INST + 19] = 300.0; }
        glass_forget();
        gl_present(td, 5, 1.0, 1.0, 1.0);
        unsigned char *px_td = pixels_of_fb(big_fb);
        unsigned char *p_H = px_td + ((fb_h - 1 - 144) * fb_w + 186) * 4;
        unsigned char *p_o = px_td + ((fb_h - 1 - 158) * fb_w + 202) * 4;
        double l_H = (0.2126 * p_H[0] + 0.7152 * p_H[1] + 0.0722 * p_H[2]) / 255.0;
        double l_o = (0.2126 * p_o[0] + 0.7152 * p_o[1] + 0.0722 * p_o[2]) / 255.0;
        printf("gles_render: wave7 testD small_pill_no_local l_H=%.3f l_o=%.3f\n", l_H, l_o);
        CHECK(l_H < 0.35);
        CHECK(l_o < 0.35);
        CHECK(fabs(l_H - l_o) < 0.05);
        free(px_td);
      }

      // Test E1: expanded 320x80pt large capsule (capHalf.y=40 > 28) with dark quadrant 0..184 x 0..152.
      // Center-relative offsets in slots 6-7: tall 'H' (y=138..148) and short 'o' (y=154..164) share line_cy=142,
      // and trailing 'i' (x=180..192 straddling x=184) shifts slot 6 to word center x=160: all 3 invert bright (> 0.82).
      {
        double te1[6 * MB_INST];
        rect_at(te1, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(te1 + MB_INST, 0, 0, 184, 152, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(te1 + 2 * MB_INST, 40, 110, 320, 80, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -25);
        te1[2 * MB_INST + 4] = 22.0;
        te1[2 * MB_INST + 6] = 1.0;
        te1[2 * MB_INST + 7] = 2.0;
        te1[2 * MB_INST + 11] = 0x67 / 255.0;
        te1[2 * MB_INST + 12] = 0.0;
        te1[2 * MB_INST + 13] = 14.0;
        te1[2 * MB_INST + 14] = -1.0;
        te1[2 * MB_INST + 15] = 1.0;
        rect_at(te1 + 3 * MB_INST, 96, 138, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        te1[3 * MB_INST + 6] = 0.0; te1[3 * MB_INST + 7] = 142.0 - 143.0;
        te1[3 * MB_INST + 12] = 16.0; te1[3 * MB_INST + 13] = 16.0;
        te1[3 * MB_INST + 14] = 16.0; te1[3 * MB_INST + 15] = 16.0;
        te1[3 * MB_INST + 21] = 200.0; te1[3 * MB_INST + 22] = 150.0; te1[3 * MB_INST + 23] = 80.0;
        rect_at(te1 + 4 * MB_INST, 112, 154, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        te1[4 * MB_INST + 6] = 0.0; te1[4 * MB_INST + 7] = 142.0 - 159.0;
        te1[4 * MB_INST + 12] = 16.0; te1[4 * MB_INST + 13] = 16.0;
        te1[4 * MB_INST + 14] = 16.0; te1[4 * MB_INST + 15] = 16.0;
        te1[4 * MB_INST + 21] = 200.0; te1[4 * MB_INST + 22] = 150.0; te1[4 * MB_INST + 23] = 80.0;
        rect_at(te1 + 5 * MB_INST, 180, 138, 12, 10, 7, 0.14, 0.15, 0.17, 0);
        te1[5 * MB_INST + 6] = 160.0 - 186.0; te1[5 * MB_INST + 7] = 142.0 - 143.0;
        te1[5 * MB_INST + 12] = 16.0; te1[5 * MB_INST + 13] = 16.0;
        te1[5 * MB_INST + 14] = 16.0; te1[5 * MB_INST + 15] = 16.0;
        te1[5 * MB_INST + 21] = 200.0; te1[5 * MB_INST + 22] = 150.0; te1[5 * MB_INST + 23] = 80.0;
        for (int i = 0; i < 6; i++) { te1[i * MB_INST + 18] = 400.0; te1[i * MB_INST + 19] = 300.0; }
        glass_forget();
        gl_present(te1, 6, 1.0, 1.0, 1.0);
        unsigned char *px_e1 = pixels_of_fb(big_fb);
        unsigned char *p_H = px_e1 + ((fb_h - 1 - 143) * fb_w + 102) * 4;
        unsigned char *p_o = px_e1 + ((fb_h - 1 - 159) * fb_w + 118) * 4;
        unsigned char *p_i = px_e1 + ((fb_h - 1 - 143) * fb_w + 186) * 4;
        double l_H = (0.2126 * p_H[0] + 0.7152 * p_H[1] + 0.0722 * p_H[2]) / 255.0;
        double l_o = (0.2126 * p_o[0] + 0.7152 * p_o[1] + 0.0722 * p_o[2]) / 255.0;
        double l_i = (0.2126 * p_i[0] + 0.7152 * p_i[1] + 0.0722 * p_i[2]) / 255.0;
        printf("gles_render: wave7 testE1 line_word_unified l_H=%.3f l_o=%.3f l_i=%.3f\n", l_H, l_o, l_i);
        CHECK(l_H > 0.82 && l_o > 0.82 && l_i > 0.82 && fabs(l_H - l_o) < 0.05 && fabs(l_H - l_i) < 0.05);
        free(px_e1);
      }

      // Test E2: macro spatial low-pass rejects short-range oscillation.
      // 320x44pt large capsule over left dark region (0..184) with an embedded 16x10pt 2D white highlight (100..116, 145..155).
      // Three adjacent glyphs at x=90, x=108 (over highlight), x=126 must all stay bright (> 0.82, diff < 0.05),
      // while the right-side glyph at x=268 over white stays dark (< 0.35).
      {
        double te2[8 * MB_INST];
        rect_at(te2, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(te2 + MB_INST, 0, 0, 184, 300, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(te2 + 2 * MB_INST, 100, 145, 16, 10, 0, 1.0, 1.0, 1.0, 0);
        rect_at(te2 + 3 * MB_INST, 40, 128, 320, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -27);
        te2[3 * MB_INST + 4] = 22.0;
        te2[3 * MB_INST + 6] = 1.0;
        te2[3 * MB_INST + 7] = 2.0;
        te2[3 * MB_INST + 11] = 0x67 / 255.0;
        te2[3 * MB_INST + 12] = 0.0;
        te2[3 * MB_INST + 13] = 14.0;
        te2[3 * MB_INST + 14] = -1.0;
        te2[3 * MB_INST + 15] = 1.0;
        double gx_xs[4] = { 84.0, 102.0, 120.0, 262.0 };
        for (int k = 0; k < 4; k++) {
          double *g = te2 + (4 + k) * MB_INST;
          rect_at(g, gx_xs[k], 142, 12, 16, 7, 0.14, 0.15, 0.17, 0);
          g[6] = 0.0; g[7] = 0.0;
          g[12] = 16.0; g[13] = 16.0; g[14] = 16.0; g[15] = 16.0;
          g[21] = 200.0; g[22] = 150.0; g[23] = 44.0;
        }
        for (int i = 0; i < 8; i++) { te2[i * MB_INST + 18] = 400.0; te2[i * MB_INST + 19] = 300.0; }
        glass_forget();
        gl_present(te2, 8, 1.0, 1.0, 1.0);
        unsigned char *px_e2 = pixels_of_fb(big_fb);
        unsigned char *p1 = px_e2 + ((fb_h - 1 - 150) * fb_w + 90) * 4;
        unsigned char *p2 = px_e2 + ((fb_h - 1 - 150) * fb_w + 108) * 4;
        unsigned char *p3 = px_e2 + ((fb_h - 1 - 150) * fb_w + 126) * 4;
        unsigned char *p4 = px_e2 + ((fb_h - 1 - 150) * fb_w + 268) * 4;
        double l1 = (0.2126 * p1[0] + 0.7152 * p1[1] + 0.0722 * p1[2]) / 255.0;
        double l2 = (0.2126 * p2[0] + 0.7152 * p2[1] + 0.0722 * p2[2]) / 255.0;
        double l3 = (0.2126 * p3[0] + 0.7152 * p3[1] + 0.0722 * p3[2]) / 255.0;
        double l4 = (0.2126 * p4[0] + 0.7152 * p4[1] + 0.0722 * p4[2]) / 255.0;
        printf("gles_render: wave7 testE2 lowpass_anti_osc l1=%.3f l2=%.3f l3=%.3f l4=%.3f\n",
               l1, l2, l3, l4);
        CHECK(l1 > 0.82 && l2 > 0.82 && l3 > 0.82);
        CHECK(fabs(l1 - l2) < 0.05 && fabs(l2 - l3) < 0.05);
        CHECK(l4 < 0.35);
        free(px_e2);
      }

      // Test F: expanded 320x80pt large capsule (capHalf.y=40 > 28) with horizontal dark/white boundary at y=152
      // (top-left dark quadrant so whole capsule stays light). Two kind-11 vector bands share p.zw -> (104, 142):
      // both bands must invert bright (> 0.82) with matching luma (no band-splitting).
      {
        double tf[6 * MB_INST];
        rect_at(tf, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(tf + MB_INST, 0, 0, 184, 152, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(tf + 2 * MB_INST, 40, 110, 320, 80, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -26);
        tf[2 * MB_INST + 4] = 22.0;
        tf[2 * MB_INST + 6] = 1.0;
        tf[2 * MB_INST + 7] = 2.0;
        tf[2 * MB_INST + 11] = 0x67 / 255.0;
        tf[2 * MB_INST + 12] = 0.0;
        tf[2 * MB_INST + 13] = 14.0;
        tf[2 * MB_INST + 14] = -1.0;
        tf[2 * MB_INST + 15] = 1.0;
        rect_at(tf + 3 * MB_INST, 96, 138, 16, 10, 11, 0.14, 0.15, 0.17, 0);
        tf[3 * MB_INST + 4] = 4.0;
        tf[3 * MB_INST + 6] = 104.0 - 104.0; tf[3 * MB_INST + 7] = 142.0 - 143.0;
        tf[3 * MB_INST + 12] = 0.0; tf[3 * MB_INST + 13] = 1.0;
        tf[3 * MB_INST + 21] = 200.0; tf[3 * MB_INST + 22] = 150.0; tf[3 * MB_INST + 23] = 80.0;
        rect_at(tf + 4 * MB_INST, 96, 154, 16, 10, 11, 0.14, 0.15, 0.17, 0);
        tf[4 * MB_INST + 4] = 4.0;
        tf[4 * MB_INST + 6] = 104.0 - 104.0; tf[4 * MB_INST + 7] = 142.0 - 159.0;
        tf[4 * MB_INST + 12] = 0.0; tf[4 * MB_INST + 13] = 1.0;
        tf[4 * MB_INST + 21] = 200.0; tf[4 * MB_INST + 22] = 150.0; tf[4 * MB_INST + 23] = 80.0;
        for (int i = 0; i < 5; i++) { tf[i * MB_INST + 18] = 400.0; tf[i * MB_INST + 19] = 300.0; }
        memset(tf + 5 * MB_INST, 0, MB_INST * sizeof(double));
        tf[5 * MB_INST + 0] = 0.1; tf[5 * MB_INST + 1] = 0.5;
        tf[5 * MB_INST + 2] = 0.9; tf[5 * MB_INST + 3] = 0.5;
        tf[5 * MB_INST + 5] = 12.0;

        glass_forget();
        gl_present(tf, 6, 1.0, 1.0, 1.0);
        unsigned char *px_tf = pixels_of_fb(big_fb);
        unsigned char *p_top = px_tf + ((fb_h - 1 - 143) * fb_w + 104) * 4;
        unsigned char *p_bot = px_tf + ((fb_h - 1 - 159) * fb_w + 104) * 4;
        double l_top = (0.2126 * p_top[0] + 0.7152 * p_top[1] + 0.0722 * p_top[2]) / 255.0;
        double l_bot = (0.2126 * p_bot[0] + 0.7152 * p_bot[1] + 0.0722 * p_bot[2]) / 255.0;
        printf("gles_render: wave7 testF icon_bands_unified l_top=%.3f l_bot=%.3f\n", l_top, l_bot);
        CHECK(l_top > 0.82 && l_bot > 0.82 && fabs(l_top - l_bot) < 0.05);
        free(px_tf);
      }

      gl_set_fixed_dt(0.0);
      glass_forget();
      target_fb = saved_fb;
      fb_w = saved_fb_w; fb_h = saved_fb_h;
      cur_w = saved_cur_w; cur_h = saved_cur_h; cur_scale = saved_cur_scale;
      glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
      glDeleteFramebuffers(1, &big_fb);
      glDeleteTextures(1, &big_tex);
    }
    // Wave 4B v17: foreground optical lens (kind == 8): offscreen Gaussian defocus + spherical bevel refraction + SDF clip
    double k8[3 * MB_INST];
    rect_at(k8, 0, 0, W, H, 0, 1.0, 1.0, 1.0, 0);
    rect_at(k8 + MB_INST, 15, 10, 70, 60, 8, 1.0, 1.0, 1.0, 0);
    k8[MB_INST + 4] = 16;
    k8[MB_INST + 7] = 3.0;   // blur = 3pt
    k8[MB_INST + 11] = 1.0;  // alpha = 1
    k8[MB_INST + 12] = 1.0;  // child_n = 1
    k8[MB_INST + 13] = 18.0; // bezel = 18pt
    k8[MB_INST + 14] = 14.0; // refraction = 14pt
    k8[MB_INST + 15] = 1.0;
    k8[MB_INST + 36] = 16; k8[MB_INST + 37] = 16; k8[MB_INST + 38] = 16; k8[MB_INST + 39] = 16;
    rect_at(k8 + 2 * MB_INST, 38, 28, 24, 24, 0, 1.0, 0.0, 0.0, 0);
    gl_present(k8, 3, 1.0, 1.0, 1.0);
    unsigned char *px_k8 = pixels_of_fb(surface);
    // RGBA at 2x (y flipped): center (50,40)->(100,80), blur halo (35,40)->(70,80), outside SDF (5,40)->(10,80)
    unsigned char *k8_ctr = px_k8 + ((fb_h - 1 - 80) * fb_w + 100) * 4;
    unsigned char *k8_halo = px_k8 + ((fb_h - 1 - 80) * fb_w + 70) * 4;
    unsigned char *k8_out = px_k8 + ((fb_h - 1 - 80) * fb_w + 10) * 4;
    printf("gles_render: kind8 lens ctr=%d,%d,%d halo=%d,%d,%d out=%d,%d,%d\n",
           k8_ctr[0], k8_ctr[1], k8_ctr[2], k8_halo[0], k8_halo[1], k8_halo[2], k8_out[0], k8_out[1], k8_out[2]);
    CHECK((int)k8_ctr[0] - (int)k8_ctr[2] > 120);
    CHECK((int)k8_halo[0] - (int)k8_halo[2] > 20);
    CHECK(abs((int)k8_out[0] - (int)k8_out[2]) <= 2 && k8_out[0] >= 250);
    free(px_k8);
  }

  // A group the host keeps drawn out by its header straight into the floats: each instance moved in doubles, then
  // made a float, as the app's own instance moved there would be.
  double kept[MB_INST];
  rect_at(kept, 10.1, 20.3, 30, 20, 0, 0.5, 0.5, 0.5, 0);
  double kept_moves[1] = {0};
  mb_host_group_set(5, kept, kept_moves, 1);
  double head[MB_INST] = {0};
  head[0] = 0.2;
  head[1] = -7.7;
  head[5] = MB_GROUP_HEAD;
  head[12] = 5;
  head[13] = 0;
  head[14] = 1;
  gl_present(head, 1, 0.1, 0.2, 0.3);
  CHECK(kept_count == 1);
  CHECK(fbuf[0] == (float)(10.1 + 0.2));
  CHECK(fbuf[1] == (float)(20.3 + -7.7));
  CHECK(fbuf[2] == 30.0f);
  CHECK(fbuf[5] == 0.0f);
  CHECK(surface_as_whole(surface));
  mb_host_group_drop(5);

  // IME height sliding hits top-bar glass cache, and gradually growing glass height stays in one 256px level bucket
  // without rebuilding levels or clearing unchanged glass slots.
  {
    int saved_fb_w = fb_w, saved_fb_h = fb_h;
    double saved_w = cur_w, saved_h = cur_h, saved_scale = cur_scale;
    GLuint saved_target = target_fb;

    const int BW = 300, BH = 500, BS = 2;
    fb_w = BW * BS;
    fb_h = BH * BS;
    cur_w = BW;
    cur_h = BH;
    cur_scale = BS;
    GLuint big_tex, big_fb;
    glGenTextures(1, &big_tex);
    glBindTexture(GL_TEXTURE_2D, big_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &big_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    target_fb = big_fb;
    glass_free();

    // (1) IME cur_h sliding: top-bar glass stays cached (blurs_made +1 per step, only bottom bar re-blurred)
    double ime_inst[5 * MB_INST];
    static const double ime_hs[5] = {460, 420, 380, 420, 460};
    rect_at(ime_inst, 0, 0, BW, BH, 0, 0.94, 0.94, 0.92, 0);
    ime_inst[18] = BW; ime_inst[19] = BH;
    rect_at(ime_inst + 1 * MB_INST, 20, 12, 120, 20, 0, 0.85, 0.20, 0.20, 0);
    ime_inst[1 * MB_INST + 18] = BW; ime_inst[1 * MB_INST + 19] = BH;
    rect_at(ime_inst + 2 * MB_INST, 10, 6, 280, 32, 5, 1, 1, 1, -20);
    ime_inst[2 * MB_INST + 7] = 3;
    ime_inst[2 * MB_INST + 11] = 0.4;
    ime_inst[2 * MB_INST + 18] = BW; ime_inst[2 * MB_INST + 19] = BH;
    rect_at(ime_inst + 3 * MB_INST, 20, 466, 120, 20, 0, 0.20, 0.30, 0.85, 0);
    ime_inst[3 * MB_INST + 18] = BW; ime_inst[3 * MB_INST + 19] = BH;
    rect_at(ime_inst + 4 * MB_INST, 10, 460, 280, 32, 5, 1, 1, 1, -21);
    ime_inst[4 * MB_INST + 7] = 3;
    ime_inst[4 * MB_INST + 11] = 0.4;
    ime_inst[4 * MB_INST + 18] = BW; ime_inst[4 * MB_INST + 19] = BH;

    made = blurs_made;
    gl_present(ime_inst, 5, 0.1, 0.2, 0.3);
    CHECK(blurs_made == made + 2);
    CHECK(surface_as_fresh(big_fb));
    for (int i = 0; i < 5; i++) {
      cur_h = ime_hs[i];
      ime_inst[3 * MB_INST + 1] = cur_h - 34;
      ime_inst[4 * MB_INST + 1] = cur_h - 40;
      made = blurs_made;
      gl_present(ime_inst, 5, 0.1, 0.2, 0.3);
      CHECK(blurs_made == made + 1);
      CHECK(surface_as_fresh(big_fb));
    }

    // (2) Glass height growing from 100px to 220px (+12px/step, 10 steps): levels_rebuilt <= 1, unchanged glass hits cache
    cur_h = BH;
    glass_free();
    int rb0 = levels_rebuilt;
    double grow_inst[5 * MB_INST];
    rect_at(grow_inst, 0, 0, BW, BH, 0, 0.92, 0.90, 0.88, 0);
    grow_inst[18] = BW; grow_inst[19] = BH;
    rect_at(grow_inst + 1 * MB_INST, 20, 14, 100, 24, 0, 0.15, 0.65, 0.25, 0);
    grow_inst[1 * MB_INST + 18] = BW; grow_inst[1 * MB_INST + 19] = BH;
    rect_at(grow_inst + 2 * MB_INST, 10, 10, 160, 32, 5, 1, 1, 1, -22);
    grow_inst[2 * MB_INST + 7] = 2;
    grow_inst[2 * MB_INST + 11] = 0.4;
    grow_inst[2 * MB_INST + 18] = BW; grow_inst[2 * MB_INST + 19] = BH;
    rect_at(grow_inst + 3 * MB_INST, 20, 140, 100, 120, 0, 0.75, 0.25, 0.15, 0);
    grow_inst[3 * MB_INST + 18] = BW; grow_inst[3 * MB_INST + 19] = BH;
    rect_at(grow_inst + 4 * MB_INST, 10, 120, 160, 50, 5, 1, 1, 1, -23);
    grow_inst[4 * MB_INST + 7] = 2;
    grow_inst[4 * MB_INST + 11] = 0.4;
    grow_inst[4 * MB_INST + 18] = BW; grow_inst[4 * MB_INST + 19] = BH;

    for (int step = 0; step < 10; step++) {
      // height in pt: 50 + step * 6 -> 100px..208px (+ margin 16px = 132px..240px, within one 256px bucket)
      grow_inst[4 * MB_INST + 3] = 50.0 + step * 6.0;
      made = blurs_made;
      gl_present(grow_inst, 5, 0.1, 0.2, 0.3);
      CHECK(blurs_made == made + (step == 0 ? 2 : 1));
      CHECK(surface_as_whole(big_fb));
    }
    CHECK(surface_as_fresh(big_fb));
    CHECK(levels_rebuilt - rb0 <= 1);

    glass_free();
    glBindFramebuffer(GL_FRAMEBUFFER, saved_target);
    glDeleteFramebuffers(1, &big_fb);
    glDeleteTextures(1, &big_tex);
    fb_w = saved_fb_w;
    fb_h = saved_fb_h;
    cur_w = saved_w;
    cur_h = saved_h;
    cur_scale = saved_scale;
    target_fb = saved_target;
  }

  // A selection changes shape data while two adaptive glasses share a backdrop. Each host-added settle
  // region must redraw the complete shared capture, so no previous glass or caret enters the new blur.
  {
    double a[6 * MB_INST];
    rect_at(a, 0, 0, W, H, 0, 0.95, 0.95, 0.95, 0);
    rect_at(a + MB_INST, 14, 54, 40, 3, 0, 0.1, 0.1, 0.1, 0);
    rect_at(a + 2 * MB_INST, 10, 29, 35, 8, 6, 0.99, 0.99, 0.99, -1);
    a[2 * MB_INST + 4] = 4.0;
    a[2 * MB_INST + 6] = 1.0;
    a[2 * MB_INST + 7] = 4.0;
    a[2 * MB_INST + 11] = 0x67 / 255.0;
    a[2 * MB_INST + 13] = 8.0;
    a[2 * MB_INST + 14] = -1.0;
    a[2 * MB_INST + 15] = 1.0;
    a[2 * MB_INST + 21] = 6.0;
    rect_at(a + 3 * MB_INST, 8, 45, 84, 23, 6, 0.99, 0.99, 0.99, -1);
    a[3 * MB_INST + 4] = 8.0;
    a[3 * MB_INST + 6] = 1.0;
    a[3 * MB_INST + 7] = 4.0;
    a[3 * MB_INST + 11] = 0x67 / 255.0;
    a[3 * MB_INST + 13] = 8.0;
    a[3 * MB_INST + 14] = -1.0;
    a[3 * MB_INST + 15] = 1.0;
    a[3 * MB_INST + 21] = 6.0;
    rect_at(a + 4 * MB_INST, 10, 2, 30, 3, 0, 0.4, 0.6, 1.0, 0);
    a[4 * MB_INST + 11] = 0.0;
    rect_at(a + 5 * MB_INST, 0, 0, 0, 0, 12, 0, 0, 0, 0);
    glass_forget();
    gl_set_fixed_dt(1.0 / 60.0);
    gl_present(a, 6, 0.95, 0.95, 0.95);
    gl_dirty_add(0, 0, W, H);
    a[8] = 0.93;
    gl_present(a, 6, 0.95, 0.95, 0.95);
    CHECK(gl_adaptive_settling());
    a[4 * MB_INST + 11] = 0.5;
    a[5 * MB_INST + 12] = 1.0;
    gl_dirty_add(8, 0, 36, 8);
    gl_present(a, 6, 0.95, 0.95, 0.95);
    slots_invalidate();
    CHECK(surface_as_whole(surface));
    gl_set_fixed_dt(0.0);
    glass_forget();
  }

  // Two independent adaptive liquid glasses spaced 8pt apart so their captures overlap, with a high-contrast blue
  // foreground caret drawn after the lower glass. Three consecutive partial frames updating only the top non-glass
  // region while settling must stay pixel-identical to a whole redraw, and overlapping settle damage merges to one.
  {
    double a[7 * MB_INST];
    rect_at(a, 0, 0, W, H, 0, 0.95, 0.95, 0.95, 0);
    rect_at(a + MB_INST, 14, 50, 40, 3, 0, 0.1, 0.1, 0.1, 0);
    rect_at(a + 2 * MB_INST, 10, 20, 35, 10, 6, 0.99, 0.99, 0.99, -1);
    a[2 * MB_INST + 4] = 4.0;
    a[2 * MB_INST + 6] = 1.0;
    a[2 * MB_INST + 7] = 2.1;
    a[2 * MB_INST + 11] = 0x67 / 255.0;
    a[2 * MB_INST + 13] = 8.0;
    a[2 * MB_INST + 14] = -1.0;
    a[2 * MB_INST + 15] = 1.0;
    a[2 * MB_INST + 21] = 28.0;
    rect_at(a + 3 * MB_INST, 8, 38, 84, 24, 6, 0.99, 0.99, 0.99, -2);
    a[3 * MB_INST + 4] = 8.0;
    a[3 * MB_INST + 6] = 1.0;
    a[3 * MB_INST + 7] = 4.0;
    a[3 * MB_INST + 11] = 0x67 / 255.0;
    a[3 * MB_INST + 13] = 8.0;
    a[3 * MB_INST + 14] = -1.0;
    a[3 * MB_INST + 15] = 1.0;
    a[3 * MB_INST + 21] = 28.0;
    rect_at(a + 4 * MB_INST, 16, 44, 2, 12, 0, 0.05, 0.35, 1.0, 0);
    rect_at(a + 5 * MB_INST, 10, 2, 30, 4, 0, 0.4, 0.6, 1.0, 0);
    a[5 * MB_INST + 11] = 0.0;
    rect_at(a + 6 * MB_INST, 0, 0, 0, 0, 12, 0, 0, 0, 0);
    glass_forget();
    gl_set_fixed_dt(1.0 / 60.0);
    gl_present(a, 7, 0.95, 0.95, 0.95);
    gl_dirty_add(0, 0, W, H);
    a[8] = 0.93;
    gl_present(a, 7, 0.95, 0.95, 0.95);
    CHECK(gl_adaptive_settling());
    for (int step = 0; step < 3; step++) {
      a[5 * MB_INST + 11] = 0.3 * (step + 1);
      a[6 * MB_INST + 12] = (double)(step + 1);
      gl_dirty_add(8, 0, 36, 8);
      gl_present(a, 7, 0.95, 0.95, 0.95);
      slots_invalidate();
      CHECK(surface_as_whole(surface));
    }
    float f[7 * MB_INST];
    for (int i = 0; i < 7 * MB_INST; i++) f[i] = (float)a[i];
    double r[][4] = {{6, 16, 43, 18}, {4, 34, 92, 32}};
    int rn = 2;
    CHECK(mb_glass_damage_expand(f, 7, r, &rn, W, H, S));
    CHECK(rn == 1);
    gl_set_fixed_dt(0.0);
    glass_forget();
  }

  // Captures reached through another capture are closed too, including every shape of a merged liquid group.
  {
    float f[4 * MB_INST] = {0};
    const float x[] = {70, 10, 40, 160};
    const float id[] = {-2, -1, -1, -3};
    for (int i = 0; i < 4; i++) {
      float *a = f + i * MB_INST;
      a[0] = x[i]; a[1] = 40; a[2] = 10; a[3] = 10; a[5] = 6; a[20] = id[i];
    }
    f[MB_INST + 23] = 8;
    double r[][4] = {{12, 42, 1, 1}};
    int rn = 1;
    CHECK(mb_glass_damage_expand(f, 4, r, &rn, 200, 100, 1));
    CHECK(rn == 1);
    CHECK(r[0][0] <= 0 && r[0][0] + r[0][2] >= 84 && r[0][0] + r[0][2] < 150);
  }

  // Perf-29: (1) Stacked glass cache independence (top progressive blur + top liquid glass capsule + changing bottom
  // content must produce 0 blur rebuilds, while changing content under top progressive blur rebuilds both identically
  // to a fresh render); (2) GLES async PBO+fence same-side early stop within 4 frames; (3) progressive blur visible-box
  // scissor & ramp boundary fast-path pixel equivalence.
  {
    double sg[5 * MB_INST];
    // 0: full background
    rect_at(sg, 0, 0, W, H, 0, 0.94, 0.94, 0.92, 0);
    // 1: top content under progressive blur
    rect_at(sg + 1 * MB_INST, 10, 4, 40, 10, 0, 0.85, 0.20, 0.20, 0);
    // 2: bottom unrelated content (far below top glass & its blur margin)
    rect_at(sg + 2 * MB_INST, 10, 62, 60, 10, 0, 0.20, 0.45, 0.90, 0);
    // 3: top progressive frosted blur (kind 5, a[22] = -1, fade y from 14..22)
    rect_at(sg + 3 * MB_INST, 0, 0, W, 22, 5, 0.96, 0.96, 0.96, -30);
    sg[3 * MB_INST + 6] = 1.1;
    sg[3 * MB_INST + 7] = 4.0;
    sg[3 * MB_INST + 11] = 0.35;
    sg[3 * MB_INST + 15] = 1.0;
    sg[3 * MB_INST + 22] = -1.0;
    sg[3 * MB_INST + 54] = 22.0;  // fade bottom end
    sg[3 * MB_INST + 55] = 8.0;   // fade bottom length (y=0..14 full ramp=1, 14..22 ramp->0)
    // 4: top liquid glass capsule stacked over the progressive blur
    rect_at(sg + 4 * MB_INST, 12, 4, 44, 12, 6, 0.99, 0.99, 0.99, -31);
    sg[4 * MB_INST + 4] = 6.0;
    sg[4 * MB_INST + 6] = 1.0;
    sg[4 * MB_INST + 7] = 2.0;
    sg[4 * MB_INST + 11] = 0x67 / 255.0;
    sg[4 * MB_INST + 13] = 8.0;
    sg[4 * MB_INST + 14] = -1.0;
    sg[4 * MB_INST + 15] = 1.0;
    sg[4 * MB_INST + 21] = 4.0;

    glass_forget();
    gl_set_fixed_dt(1.0 / 60.0);
    made = blurs_made;
    gl_present(sg, 5, 0.94, 0.94, 0.92);
    CHECK(blurs_made == made + 2);
    CHECK(surface_as_fresh(surface));

    // Mutate bottom unrelated rect across 3 frames: neither top progressive nor stacked liquid glass may re-blur.
    for (int step = 0; step < 3; step++) {
      sg[2 * MB_INST + 8] = 0.20 + 0.25 * (step + 1);
      made = blurs_made;
      gl_present(sg, 5, 0.94, 0.94, 0.92);
      CHECK(blurs_made == made);
      CHECK(surface_as_fresh(surface));
    }

    // Mutate content under the top progressive blur: both top progressive and stacked liquid glass must re-blur.
    sg[1 * MB_INST + 9] = 0.80;
    made = blurs_made;
    gl_present(sg, 5, 0.94, 0.94, 0.92);
    CHECK(blurs_made == made + 2);
    CHECK(surface_as_fresh(surface));

    // GLES async PBO+fence same-side early stop: light->light (0.94 -> 0.92) stops settling within 4 frames.
    double es[3 * MB_INST];
    rect_at(es, 0, 0, W, H, 0, 0.95, 0.95, 0.95, 0);
    rect_at(es + MB_INST, 8, 28, 84, 16, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -32);
    es[MB_INST + 4] = 8.0;
    es[MB_INST + 6] = 1.0;
    es[MB_INST + 7] = 2.0;
    es[MB_INST + 11] = 0x67 / 255.0;
    es[MB_INST + 13] = 8.0;
    es[MB_INST + 14] = -1.0;
    es[MB_INST + 15] = 1.0;
    rect_at(es + 2 * MB_INST, 16, 30, 20, 12, 10, 0.11, 0.11, 0.11, 0);
    es[2 * MB_INST + 4] = 3.0;
    es[2 * MB_INST + 12] = 0.1; es[2 * MB_INST + 13] = 0.5;
    es[2 * MB_INST + 14] = 0.9; es[2 * MB_INST + 15] = 0.5;
    es[2 * MB_INST + 21] = 50.0; es[2 * MB_INST + 22] = 36.0; es[2 * MB_INST + 23] = 16.0;
    glass_forget();
    gl_present(es, 3, 0.95, 0.95, 0.95);
    CHECK(gl_adaptive_settling() == 0);
    es[8] = 0.93; es[9] = 0.93; es[10] = 0.93;
    gl_present(es, 3, 0.93, 0.93, 0.93);
    CHECK(gl_adaptive_settling() == 1);
    for (int s = 0; s < 4 && gl_adaptive_settling(); s++) {
      gl_present(es, 3, 0.93, 0.93, 0.93);
    }
    CHECK(gl_adaptive_settling() == 0);
    gl_set_fixed_dt(0.0);
    glass_forget();
  }

  // Glass after glass in one frame and the next: no pass samples a level it draws into. A progressive blur binds
  // lv[1..3] for its composite and a lens its level as the backdrop; left bound, the next blur's passes (into those
  // levels) or the next lens's (into its own) are feedback loops, dropped by WebGL2 and strict GLES 3 drivers and the
  // glass left black. Each picture is the same to the byte as the same glass drawn alone.
  {
    double base[3 * MB_INST];
    rect_at(base, 0, 0, W, H, 0, 0.94, 0.94, 0.92, 0);
    rect_at(base + MB_INST, 10, 4, 40, 10, 0, 0.85, 0.20, 0.20, 0);
    rect_at(base + 2 * MB_INST, 10, 60, 60, 10, 0, 0.20, 0.45, 0.90, 0);
    double fl[9 * MB_INST];
    while (glGetError() != GL_NO_ERROR) {
    }

    // (1) Two progressive blurs, the top's and the foot's, against the foot's alone.
    memcpy(fl, base, sizeof base);
    progressive_at(fl + 3 * MB_INST, 0, 22, 1, -50);
    progressive_at(fl + 4 * MB_INST, 53, H, 0, -51);
    glass_forget();
    feedback_loops = 0;
    gl_present(fl, 5, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    CHECK(!level_left_bound());
    unsigned char *both = pixels_of_fb(surface);
    // (the next frame, from blurs kept, and drawn anew)
    gl_present(fl, 5, 0.94, 0.94, 0.92);
    CHECK(feedback_loops == 0);
    CHECK(surface_as_fresh(surface));
    CHECK(feedback_loops == 0);
    memcpy(fl + 3 * MB_INST, fl + 4 * MB_INST, MB_INST * sizeof(double));
    glass_forget();
    gl_present(fl, 4, 0.94, 0.94, 0.92);
    unsigned char *alone = pixels_of_fb(surface);
    printf("gles_render: two progressive foot=%.3f alone=%.3f loops=%d\n", luma_at(both, 50, 66), luma_at(alone, 50, 66),
           feedback_loops);
    CHECK(luma_at(both, 50, 66) > 0.5);
    CHECK(foot_same(both, alone, 46 * S));
    free(both);
    free(alone);

    // (2) A progressive blur, then a liquid glass capsule (kind 6) and a frosted glass (kind 5), against those alone.
    double later[2 * MB_INST];
    rect_at(later, 12, 30, 44, 12, 6, 0.99, 0.99, 0.99, -53);
    later[4] = 6.0;
    later[6] = 1.0;
    later[7] = 2.0;
    later[11] = 0x67 / 255.0;
    later[13] = 8.0;
    later[14] = -1.0;
    later[15] = 1.0;
    later[21] = 4.0;
    rect_at(later + MB_INST, 0, 53, W, 22, 5, 0.96, 0.96, 0.96, -52);
    later[MB_INST + 6] = 1.1;
    later[MB_INST + 7] = 4.0;
    later[MB_INST + 11] = 0.35;
    later[MB_INST + 15] = 1.0;
    memcpy(fl, base, sizeof base);
    progressive_at(fl + 3 * MB_INST, 0, 22, 1, -50);
    memcpy(fl + 4 * MB_INST, later, sizeof later);
    glass_forget();
    feedback_loops = 0;
    gl_present(fl, 6, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    CHECK(!level_left_bound());
    both = pixels_of_fb(surface);
    gl_present(fl, 6, 0.94, 0.94, 0.92);
    CHECK(feedback_loops == 0);
    CHECK(surface_as_fresh(surface));
    memcpy(fl + 3 * MB_INST, later, sizeof later);
    glass_forget();
    gl_present(fl, 5, 0.94, 0.94, 0.92);
    alone = pixels_of_fb(surface);
    printf("gles_render: progressive then glass capsule=%.3f frost=%.3f loops=%d\n", luma_at(both, 34, 36),
           luma_at(both, 50, 66), feedback_loops);
    CHECK(luma_at(both, 34, 36) > 0.5);
    CHECK(luma_at(both, 50, 66) > 0.5);
    CHECK(foot_same(both, alone, 26 * S));
    free(both);
    free(alone);

    // (3) A progressive blur, then two lenses (kind 8), red and blue under them; the frame again, and anew.
    memcpy(fl, base, sizeof base);
    progressive_at(fl + 3 * MB_INST, 0, 22, 1, -50);
    lens_at(fl + 4 * MB_INST, 5, 30, 1.0, 0.0, 0.0);
    lens_at(fl + 6 * MB_INST, 55, 30, 0.0, 0.0, 1.0);
    glass_forget();
    feedback_loops = 0;
    gl_present(fl, 8, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    CHECK(!level_left_bound());
    both = pixels_of_fb(surface);
    gl_present(fl, 8, 0.94, 0.94, 0.92);
    CHECK(glGetError() == GL_NO_ERROR);
    CHECK(feedback_loops == 0);
    alone = pixels_of_fb(surface);
    CHECK(memcmp(both, alone, (size_t)fb_w * fb_h * 4) == 0);
    free(alone);
    CHECK(surface_as_fresh(surface));
    CHECK(feedback_loops == 0);
    const unsigned char *red = both + ((fb_h - 1 - 50 * S) * fb_w + 25 * S) * 4;
    const unsigned char *blue = both + ((fb_h - 1 - 50 * S) * fb_w + 75 * S) * 4;
    printf("gles_render: two lenses red=%d,%d,%d blue=%d,%d,%d loops=%d\n", red[0], red[1], red[2], blue[0], blue[1],
           blue[2], feedback_loops);
    CHECK((int)red[0] - (int)red[2] > 100);
    CHECK((int)blue[2] - (int)blue[0] > 100);
    free(both);
    glass_forget();
  }

  // Progressive blur small-radius anti-ghosting regression: 1pt and 1px dark vertical/horizontal strokes over
  // a light background under blur=8.5, fade_h=68 progressive blur at both 2x and 1x scale must produce strictly
  // unimodal profiles (no 9-tap comb ghosting / secondary dark peaks) and monotonically attenuate center contrast.
  {
    static const int scales[2] = {2, 1};
    static const double v_ramps[6] = {0.06, 0.10, 0.14, 0.18, 0.24, 0.35};
    static const double h_ramps[3] = {0.10, 0.18, 0.24};
    GLuint pb_tex = 0, pb_fb = 0;
    for (int si = 0; si < 2; si++) {
      int sc = scales[si];
      fb_w = W * sc;
      fb_h = H * sc;
      cur_w = W;
      cur_h = H;
      cur_scale = (double)sc;
      if (pb_fb) { glDeleteFramebuffers(1, &pb_fb); pb_fb = 0; }
      if (pb_tex) { glDeleteTextures(1, &pb_tex); pb_tex = 0; }
      glGenTextures(1, &pb_tex);
      glBindTexture(GL_TEXTURE_2D, pb_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &pb_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, pb_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pb_tex, 0);
      CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
      target_fb = pb_fb;
      canvas_ok = 0;

      double widths[2] = {1.0, 1.0 / (double)sc};
      int n_widths = (sc > 1) ? 2 : 1;
      for (int wi = 0; wi < n_widths; wi++) {
        double lw = widths[wi];
        // 1) Vertical stroke across the entire fade band (y=0..75)
        double pb[3 * MB_INST];
        rect_at(pb, 0, 0, W, H, 0, 0.96, 0.96, 0.96, 0);
        rect_at(pb + MB_INST, 50.0, 0.0, lw, H, 0, 0.05, 0.05, 0.05, 0);
        rect_at(pb + 2 * MB_INST, 0, 0, W, 68.0, 5, 0.96, 0.96, 0.96, -40);
        pb[2 * MB_INST + 6] = 1.0;
        pb[2 * MB_INST + 7] = 8.5;
        pb[2 * MB_INST + 11] = 0.15;
        pb[2 * MB_INST + 15] = 1.0;
        pb[2 * MB_INST + 22] = -1.0;
        pb[2 * MB_INST + 54] = 68.0;
        pb[2 * MB_INST + 55] = 68.0;
        glass_forget();
        gl_present(pb, 3, 0.96, 0.96, 0.96);
        unsigned char *px = pixels_of_fb(pb_fb);
        int prev_center = -1;
        int first_center = -1;
        int last_center = -1;
        int mono_ok = 1;
        int max_dip = 0;
        for (int ri = 0; ri < 6; ri++) {
          int py = (int)llround(68.0 * (1.0 - v_ramps[ri]) * (double)sc);
          if (py < 0) py = 0;
          if (py >= fb_h) py = fb_h - 1;
          int row = fb_h - 1 - py;
          int x0 = (int)floor(50.0 * (double)sc) - 2;
          int x1 = (int)ceil((50.0 + lw) * (double)sc) + 2;
          int xc = x0, min_l = 256;
          for (int x = x0; x <= x1; x++) {
            int l = px[(row * fb_w + x) * 4 + 1];
            if (l < min_l) { min_l = l; xc = x; }
          }
          if (ri == 0) first_center = min_l;
          last_center = min_l;
          if (prev_center >= 0 && min_l < prev_center - 2) {
            fprintf(stderr, "gles_render: prog-blur v-stroke center non-mono sc=%d lw=%.2f ramp=%.2f prev=%d cur=%d\n",
                    sc, lw, v_ramps[ri], prev_center, min_l);
            mono_ok = 0;
          }
          prev_center = min_l;
          for (int dir = -1; dir <= 1; dir += 2) {
            int max_seen = min_l;
            for (int dx = 1; dx <= 12; dx++) {
              int x = xc + dir * dx;
              if (x < 0 || x >= fb_w) break;
              int l = px[(row * fb_w + x) * 4 + 1];
              if (max_seen - l > max_dip) max_dip = max_seen - l;
              if (l < max_seen - 2) mono_ok = 0;
              if (l > max_seen) max_seen = l;
            }
          }
        }
        printf("gles_render: prog-blur v-stroke sc=%d lw=%.2f first=%d last=%d max_dip=%d\n",
               sc, lw, first_center, last_center, max_dip);
        CHECK(mono_ok);
        CHECK(last_center > first_center + 15);
        free(px);

        // 2) Horizontal strokes at representative small-radius ramps
        int h_mono_ok = 1;
        int h_max_dip = 0;
        for (int ri = 0; ri < 3; ri++) {
          double y_pt = 68.0 * (1.0 - h_ramps[ri]);
          double hp[3 * MB_INST];
          rect_at(hp, 0, 0, W, H, 0, 0.96, 0.96, 0.96, 0);
          rect_at(hp + MB_INST, 10.0, y_pt, 80.0, lw, 0, 0.05, 0.05, 0.05, 0);
          rect_at(hp + 2 * MB_INST, 0, 0, W, 68.0, 5, 0.96, 0.96, 0.96, -41);
          hp[2 * MB_INST + 6] = 1.0;
          hp[2 * MB_INST + 7] = 8.5;
          hp[2 * MB_INST + 11] = 0.15;
          hp[2 * MB_INST + 15] = 1.0;
          hp[2 * MB_INST + 22] = -1.0;
          hp[2 * MB_INST + 54] = 68.0;
          hp[2 * MB_INST + 55] = 68.0;
          glass_forget();
          gl_present(hp, 3, 0.96, 0.96, 0.96);
          unsigned char *hpx = pixels_of_fb(pb_fb);
          int px_x = 50 * sc;
          int y0 = (int)floor(y_pt * (double)sc) - 2;
          int y1 = (int)ceil((y_pt + lw) * (double)sc) + 2;
          int yc = y0, min_l = 256;
          for (int y = y0; y <= y1; y++) {
            int row = fb_h - 1 - y;
            int l = hpx[(row * fb_w + px_x) * 4 + 1];
            if (l < min_l) { min_l = l; yc = y; }
          }
          for (int dir = -1; dir <= 1; dir += 2) {
            int max_seen = min_l;
            for (int dy = 1; dy <= 10; dy++) {
              int y = yc + dir * dy;
              if (y < 0 || y >= fb_h) break;
              int row = fb_h - 1 - y;
              int l = hpx[(row * fb_w + px_x) * 4 + 1];
              if (max_seen - l > h_max_dip) h_max_dip = max_seen - l;
              if (l < max_seen - 2) h_mono_ok = 0;
              if (l > max_seen) max_seen = l;
            }
          }
          free(hpx);
        }
        printf("gles_render: prog-blur h-stroke sc=%d lw=%.2f max_dip=%d\n", sc, lw, h_max_dip);
        CHECK(h_mono_ok);
      }
    }
    if (pb_fb) glDeleteFramebuffers(1, &pb_fb);
    if (pb_tex) glDeleteTextures(1, &pb_tex);
    fb_w = W * S;
    fb_h = H * S;
    cur_w = W;
    cur_h = H;
    cur_scale = S;
    target_fb = surface;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    canvas_ok = 0;
    glass_forget();
  }

  // Perf-30: (1) Rotated spinner isolation & 60-frame benchmark, (2) 45-deg grazing & far-pivot rotated overlap,
  // (3) unrelated kind==12 vector segment isolation, (4) GLES VRAM budget + compact 64px slots + high-water lv shrink.
  {
    GLuint p30_tex = 0, p30_fb = 0;
    int pw = 400, ph = 600, psc = 2;
    fb_w = pw * psc;
    fb_h = ph * psc;
    cur_w = pw;
    cur_h = ph;
    cur_scale = psc;
    glGenTextures(1, &p30_tex);
    glBindTexture(GL_TEXTURE_2D, p30_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &p30_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, p30_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p30_tex, 0);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    target_fb = p30_fb;
    canvas_ok = 0;
    glass_free();

    // (1) Rotated spinner 400pt below top progressive blur + liquid glass: 60 frames, frames 2..60 must have 0 blurs.
    {
      double sp[5 * MB_INST];
      rect_at(sp, 0, 0, pw, ph, 0, 0.94, 0.94, 0.92, 0);
      sp[18] = pw; sp[19] = ph;
      rect_at(sp + 1 * MB_INST, 20, 8, 120, 24, 0, 0.85, 0.20, 0.20, 0);
      sp[1 * MB_INST + 18] = pw; sp[1 * MB_INST + 19] = ph;
      // Rotating spinner far below (y=460, 400pt below top glass)
      rect_at(sp + 2 * MB_INST, 180, 460, 20, 20, 0, 0.20, 0.45, 0.90, 0);
      sp[2 * MB_INST + 18] = pw; sp[2 * MB_INST + 19] = ph;
      sp[2 * MB_INST + 32] = 0.1;
      sp[2 * MB_INST + 33] = 190.0;
      sp[2 * MB_INST + 34] = 470.0;
      // Top progressive blur
      rect_at(sp + 3 * MB_INST, 0, 0, pw, 64, 5, 0.96, 0.96, 0.96, -50);
      sp[3 * MB_INST + 6] = 1.1;
      sp[3 * MB_INST + 7] = 6.0;
      sp[3 * MB_INST + 11] = 0.35;
      sp[3 * MB_INST + 15] = 1.0;
      sp[3 * MB_INST + 18] = pw; sp[3 * MB_INST + 19] = ph;
      sp[3 * MB_INST + 22] = -1.0;
      sp[3 * MB_INST + 54] = 64.0;
      sp[3 * MB_INST + 55] = 24.0;
      // Top liquid glass capsule
      rect_at(sp + 4 * MB_INST, 24, 12, 140, 32, 6, 0.99, 0.99, 0.99, -51);
      sp[4 * MB_INST + 4] = 16.0;
      sp[4 * MB_INST + 6] = 1.0;
      sp[4 * MB_INST + 7] = 2.0;
      sp[4 * MB_INST + 11] = 0x67 / 255.0;
      sp[4 * MB_INST + 13] = 8.0;
      sp[4 * MB_INST + 14] = -1.0;
      sp[4 * MB_INST + 15] = 1.0;
      sp[4 * MB_INST + 18] = pw; sp[4 * MB_INST + 19] = ph;
      sp[4 * MB_INST + 21] = 6.0;

      glass_forget();
      gl_set_fixed_dt(1.0 / 60.0);
      int b_start = blurs_made;
      int steady_blurs = 0;
      struct timespec t0, t1;
      clock_gettime(CLOCK_MONOTONIC, &t0);
      for (int frame = 0; frame < 60; frame++) {
        sp[2 * MB_INST + 32] = 0.1 + frame * 0.105;
        int b_before = blurs_made;
        gl_present(sp, 5, 0.94, 0.94, 0.92);
        if (frame == 0) {
          CHECK(blurs_made == b_before + 2);
        } else {
          steady_blurs += (blurs_made - b_before);
          CHECK(blurs_made == b_before);
        }
      }
      glFinish();
      clock_gettime(CLOCK_MONOTONIC, &t1);
      double elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
      printf("gles_render: Perf-30 60-frame spinner blurs=%d (frames 2..60=%d) ms=%.2f\n",
             blurs_made - b_start, steady_blurs, elapsed_ms);
      CHECK(steady_blurs == 0);
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));
      gl_set_fixed_dt(0.0);
    }

    // (2) Rotated instance grazing overlap at 45 deg + far-pivot swing into glass capture region.
    {
      double rg[3 * MB_INST];
      rect_at(rg, 0, 0, pw, ph, 0, 0.94, 0.94, 0.92, 0);
      rg[18] = pw; rg[19] = ph;
      // Glass at y=0..60 with blur=4.0 (margin = 14pt -> grab reaches y=74)
      // Rect 40x40 centered at (100, 100): at angle=0, top is y=80 (> 74, outside).
      // At angle=45 deg, half-diagonal is 20*sqrt(2) = 28.28 -> top reaches y=71.72 (< 74, overlaps grab!).
      rect_at(rg + 1 * MB_INST, 80, 80, 40, 40, 0, 0.90, 0.15, 0.15, 0);
      rg[1 * MB_INST + 18] = pw; rg[1 * MB_INST + 19] = ph;
      rg[1 * MB_INST + 32] = 0.0;
      rg[1 * MB_INST + 33] = 100.0;
      rg[1 * MB_INST + 34] = 100.0;
      rect_at(rg + 2 * MB_INST, 40, 20, 120, 40, 5, 0.98, 0.98, 0.98, -52);
      rg[2 * MB_INST + 7] = 4.0;
      rg[2 * MB_INST + 11] = 0.45;
      rg[2 * MB_INST + 18] = pw; rg[2 * MB_INST + 19] = ph;

      glass_forget();
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      CHECK(surface_as_whole(p30_fb));
      // Rotate to 45 deg: corner grazes glass capture -> must rebuild and match fresh render byte-for-byte
      rg[1 * MB_INST + 32] = 0.7853981633974483;
      int b0 = blurs_made;
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      CHECK(surface_as_fresh(p30_fb));

      // Far-pivot swing: rect at (200, 300, 30, 30), pivot at (150, 170), rotate by PI -> lands near (85, 25) inside glass!
      rg[1 * MB_INST + 0] = 200.0; rg[1 * MB_INST + 1] = 300.0;
      rg[1 * MB_INST + 2] = 30.0; rg[1 * MB_INST + 3] = 30.0;
      rg[1 * MB_INST + 32] = 0.0;
      rg[1 * MB_INST + 33] = 150.0; rg[1 * MB_INST + 34] = 170.0;
      glass_forget();
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      rg[1 * MB_INST + 32] = 3.141592653589793;
      b0 = blurs_made;
      gl_present(rg, 3, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      CHECK(surface_as_fresh(p30_fb));
    }

    // (3) Unrelated kind==12 vector path segment isolation.
    {
      double vg[4 * MB_INST];
      rect_at(vg, 0, 0, pw, ph, 0, 0.94, 0.94, 0.92, 0);
      vg[18] = pw; vg[19] = ph;
      // Bottom kind==11 vector shape (y=400..440, far below top glass)
      rect_at(vg + 1 * MB_INST, 40, 400, 60, 40, 11, 0.10, 0.30, 0.85, 0);
      vg[1 * MB_INST + 12] = 0.0;  // seg start
      vg[1 * MB_INST + 13] = 1.0;  // seg count
      vg[1 * MB_INST + 18] = pw; vg[1 * MB_INST + 19] = ph;
      // Top frosted glass (y=20..60, no kind==11 under it)
      rect_at(vg + 2 * MB_INST, 20, 20, 140, 40, 5, 0.98, 0.98, 0.98, -53);
      vg[2 * MB_INST + 7] = 4.0;
      vg[2 * MB_INST + 11] = 0.45;
      vg[2 * MB_INST + 18] = pw; vg[2 * MB_INST + 19] = ph;
      // Trailing kind==12 segment piece
      memset(vg + 3 * MB_INST, 0, MB_INST * sizeof(double));
      vg[3 * MB_INST + 5] = 12;
      vg[3 * MB_INST + 0] = 40; vg[3 * MB_INST + 1] = 400;
      vg[3 * MB_INST + 2] = 100; vg[3 * MB_INST + 3] = 440;

      glass_forget();
      int b0 = blurs_made;
      gl_present(vg, 4, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      for (int step = 0; step < 3; step++) {
        vg[3 * MB_INST + 2] = 90 + step * 5;
        b0 = blurs_made;
        gl_present(vg, 4, 0.94, 0.94, 0.92);
        CHECK(blurs_made == b0);
        CHECK(surface_as_whole(p30_fb));
      }
      CHECK(surface_as_fresh(p30_fb));

      // Move kind==11 under the top glass: mutating kind==12 MUST rebuild blur!
      vg[1 * MB_INST + 1] = 24.0;
      vg[3 * MB_INST + 1] = 24.0; vg[3 * MB_INST + 3] = 56.0;
      glass_forget();
      gl_present(vg, 4, 0.94, 0.94, 0.92);
      vg[3 * MB_INST + 2] = 110.0;
      b0 = blurs_made;
      gl_present(vg, 4, 0.94, 0.94, 0.92);
      CHECK(blurs_made == b0 + 1);
      CHECK(surface_as_fresh(p30_fb));
    }

    // (4) GLES VRAM budget + compact 64px slot textures + high-water lv_w/lv_h shrink.
    {
      GLuint big_tex = 0, big_fb = 0;
      int bw_pt = 1280, bh_pt = 720, bsc = 2;
      fb_w = bw_pt * bsc;
      fb_h = bh_pt * bsc;
      cur_w = bw_pt;
      cur_h = bh_pt;
      cur_scale = bsc;
      glGenTextures(1, &big_tex);
      glBindTexture(GL_TEXTURE_2D, big_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &big_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
      CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
      target_fb = big_fb;
      canvas_ok = 0;
      glass_free();

      double big[3 * MB_INST];
      rect_at(big, 0, 0, bw_pt, bh_pt, 0, 0.12, 0.16, 0.22, 0);
      big[18] = bw_pt; big[19] = bh_pt;
      rect_at(big + MB_INST, 0, 0, 1240, 60, 5, 1, 1, 1, -54);
      big[MB_INST + 7] = 12.0;
      big[MB_INST + 11] = 0.4;
      big[MB_INST + 18] = bw_pt; big[MB_INST + 19] = bh_pt;
      big[MB_INST + 22] = -1.0;
      big[MB_INST + 54] = 60.0;
      big[MB_INST + 55] = 30.0;
      rect_at(big + 2 * MB_INST, 0, 80, 120, 620, 5, 1, 1, 1, -55);
      big[2 * MB_INST + 7] = 12.0;
      big[2 * MB_INST + 11] = 0.4;
      big[2 * MB_INST + 18] = bw_pt; big[2 * MB_INST + 19] = bh_pt;
      gl_present(big, 3, 0.12, 0.16, 0.22);
      CHECK(lv_w >= 2400 && lv_h >= 1200);
      CHECK(slots_total_bytes() <= MB_GLASS_CACHE_MAX_BYTES);
      CHECK(surface_as_whole(big_fb));

      double sm[4 * MB_INST];
      rect_at(sm, 0, 0, bw_pt, bh_pt, 0, 0.14, 0.18, 0.24, 0);
      sm[18] = bw_pt; sm[19] = bh_pt;
      rect_at(sm + MB_INST, 20, 30, 420, 60, 0, 0.90, 0.35, 0.20, 0);
      sm[MB_INST + 18] = bw_pt; sm[MB_INST + 19] = bh_pt;
      rect_at(sm + 2 * MB_INST, 40, 40, 160, 44, 5, 1, 1, 1, -56);
      sm[2 * MB_INST + 7] = 12.0;
      sm[2 * MB_INST + 11] = 0.45;
      sm[2 * MB_INST + 18] = bw_pt; sm[2 * MB_INST + 19] = bh_pt;
      sm[2 * MB_INST + 22] = -1.0;
      sm[2 * MB_INST + 54] = 84.0;
      sm[2 * MB_INST + 55] = 44.0;
      rect_at(sm + 3 * MB_INST, 300, 40, 120, 40, 5, 1, 1, 1, -57);
      sm[3 * MB_INST + 7] = 3.0;
      sm[3 * MB_INST + 11] = 0.45;
      sm[3 * MB_INST + 18] = bw_pt; sm[3 * MB_INST + 19] = bh_pt;

      size_t peak_slot_bytes = slots_total_bytes();
      size_t max_small_tex_area = 0;
      for (int step = 0; step < 40; step++) {
        sm[MB_INST + 0] = 20 + (step * 7) % 120;
        gl_present(sm, 4, 0.14, 0.18, 0.24);
        size_t cur_bytes = slots_total_bytes();
        if (cur_bytes > peak_slot_bytes) peak_slot_bytes = cur_bytes;
        CHECK(cur_bytes <= MB_GLASS_CACHE_MAX_BYTES);
        for (int j = 0; j < MB_GLASS_SLOTS; j++) {
          if (slots[j].valid && slots[j].bt && slots[j].grab.w < 1000) {
            size_t area = (size_t)slots[j].bw * (size_t)slots[j].bh;
            if (area > max_small_tex_area) max_small_tex_area = area;
          }
        }
      }
      printf("gles_render: glass stress peak_slot_bytes=%zu (limit=%zu) max_small_area=%zu lv_area=%zu\n",
             peak_slot_bytes, (size_t)MB_GLASS_CACHE_MAX_BYTES, max_small_tex_area, (size_t)lv_w * (size_t)lv_h);
      CHECK(peak_slot_bytes <= MB_GLASS_CACHE_MAX_BYTES);
      CHECK(max_small_tex_area > 0 && max_small_tex_area * 8 < (size_t)lv_w * (size_t)lv_h);
      CHECK(surface_as_whole(big_fb));
      CHECK(surface_as_fresh(big_fb));

      // High-water mark shrink over MB_GLASS_IDLE (180) frames
      glass_free();
      fb_w = 400 * 2;
      fb_h = 300 * 2;
      cur_w = 400;
      cur_h = 300;
      cur_scale = 2;
      target_fb = p30_fb;
      glBindFramebuffer(GL_FRAMEBUFFER, p30_fb);
      // Reuse a 800x600 FBO for clean 400x300@2x shrink test
      glDeleteFramebuffers(1, &big_fb);
      glDeleteTextures(1, &big_tex);
      glGenTextures(1, &big_tex);
      glBindTexture(GL_TEXTURE_2D, big_tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
      glGenFramebuffers(1, &big_fb);
      glBindFramebuffer(GL_FRAMEBUFFER, big_fb);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, big_tex, 0);
      target_fb = big_fb;
      canvas_ok = 0;

      double lg[2 * MB_INST];
      rect_at(lg, 0, 0, 400, 300, 0, 0.15, 0.25, 0.40, 0);
      lg[18] = 400; lg[19] = 300;
      rect_at(lg + MB_INST, 0, 0, 400, 300, 5, 1, 1, 1, -58);
      lg[MB_INST + 7] = 8.0;
      lg[MB_INST + 11] = 0.45;
      lg[MB_INST + 18] = 400; lg[MB_INST + 19] = 300;
      gl_present(lg, 2, 0.15, 0.25, 0.40);
      size_t big_lv_area = (size_t)lv_w * (size_t)lv_h;
      CHECK(lv_w == 800 && lv_h == 600);
      CHECK(surface_as_whole(big_fb));

      double sml[3 * MB_INST];
      rect_at(sml, 0, 0, 400, 300, 0, 0.15, 0.25, 0.40, 0);
      sml[18] = 400; sml[19] = 300;
      rect_at(sml + MB_INST, 24, 24, 52, 32, 0, 0.90, 0.20, 0.20, 0);
      sml[MB_INST + 18] = 400; sml[MB_INST + 19] = 300;
      rect_at(sml + 2 * MB_INST, 20, 20, 60, 40, 5, 1, 1, 1, -59);
      sml[2 * MB_INST + 7] = 4.0;
      sml[2 * MB_INST + 11] = 0.45;
      sml[2 * MB_INST + 18] = 400; sml[2 * MB_INST + 19] = 300;
      for (int i = 0; i < MB_GLASS_IDLE; i++) {
        sml[MB_INST + 0] = 24 + (i % 20);
        gl_present(sml, 3, 0.15, 0.25, 0.40);
      }
      size_t shrunk_lv_area = (size_t)lv_w * (size_t)lv_h;
      printf("gles_render: lv shrink big_area=%zu -> shrunk_area=%zu (%dx%d)\n",
             big_lv_area, shrunk_lv_area, lv_w, lv_h);
      CHECK(shrunk_lv_area * 4 < big_lv_area);
      CHECK(surface_as_whole(big_fb));
      CHECK(surface_as_fresh(big_fb));

      glDeleteFramebuffers(1, &big_fb);
      glDeleteTextures(1, &big_tex);
    }

    // (5) Perf-31: multi-dirty-rect partial redraw de-amplification (single VBO upload, grab_in_cut skip,
    //     kind 8 lens skip, conservative CPU scissor culling for non-glass runs, byte-for-byte parity).
    {
      int pw_pt = 400, ph_pt = 600, psc = 2;
      fb_w = pw_pt * psc;
      fb_h = ph_pt * psc;
      cur_w = pw_pt;
      cur_h = ph_pt;
      cur_scale = psc;
      target_fb = p30_fb;
      glBindFramebuffer(GL_FRAMEBUFFER, p30_fb);
      canvas_ok = 0;
      glass_free();

      // Build a rich scene: 400 grid rects + 1 shadow + 1 clipped/oclipped rect + 1 rotated rect +
      // 2 frosted glass groups (top y=10..50, bottom y=540..580) + 1 foreground lens (kind 8 + 2 children at y=280..320).
      const int GRID_N = 400;
      const int TOTAL = GRID_N + 8;
      double *sc = (double *)calloc((size_t)TOTAL * MB_INST, sizeof(double));
      for (int i = 0; i < GRID_N; i++) {
        int col = i % 20, row = i / 20;
        double x = 8.0 + col * 19.0;
        double y = 60.0 + row * 23.0;
        rect_at(sc + (size_t)i * MB_INST, x, y, 14.0, 16.0, 0,
                0.2 + 0.03 * col, 0.25 + 0.03 * row, 0.55, 0);
        sc[(size_t)i * MB_INST + 18] = pw_pt;
        sc[(size_t)i * MB_INST + 19] = ph_pt;
      }
      int idx = GRID_N;
      // Shadow (kind 2) near (26, 100)
      rect_at(sc + (size_t)idx * MB_INST, 26, 100, 24, 20, 2, 0.0, 0.0, 0.0, 0);
      sc[(size_t)idx * MB_INST + 7] = 6.0;
      sc[(size_t)idx * MB_INST + 11] = 0.45;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      // Clipped + outer-clipped rect (active a_orc -> a_oclip clips it inside [300, 440] x [340, 470])
      rect_at(sc + (size_t)idx * MB_INST, 290, 430, 60, 50, 0, 0.85, 0.25, 0.15, 0);
      sc[(size_t)idx * MB_INST + 16] = 295; sc[(size_t)idx * MB_INST + 17] = 435;
      sc[(size_t)idx * MB_INST + 18] = 345; sc[(size_t)idx * MB_INST + 19] = 475;
      sc[(size_t)idx * MB_INST + 40] = 300; sc[(size_t)idx * MB_INST + 41] = 440;
      sc[(size_t)idx * MB_INST + 42] = 340; sc[(size_t)idx * MB_INST + 43] = 470;
      sc[(size_t)idx * MB_INST + 44] = 6.0; sc[(size_t)idx * MB_INST + 45] = 6.0;
      sc[(size_t)idx * MB_INST + 46] = 6.0; sc[(size_t)idx * MB_INST + 47] = 6.0;
      idx++;
      // Rotated rect near (190, 150)
      rect_at(sc + (size_t)idx * MB_INST, 180, 140, 26, 26, 0, 0.15, 0.80, 0.35, 0);
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      sc[(size_t)idx * MB_INST + 32] = 0.6;
      sc[(size_t)idx * MB_INST + 33] = 193.0;
      sc[(size_t)idx * MB_INST + 34] = 153.0;
      idx++;
      // Glass group 1 at top (y=10..50)
      rect_at(sc + (size_t)idx * MB_INST, 20, 10, 360, 40, 5, 0.96, 0.96, 0.96, -71);
      sc[(size_t)idx * MB_INST + 7] = 6.0;
      sc[(size_t)idx * MB_INST + 11] = 0.45;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      // Glass group 2 at bottom (y=540..580)
      rect_at(sc + (size_t)idx * MB_INST, 20, 540, 360, 40, 5, 0.96, 0.96, 0.96, -72);
      sc[(size_t)idx * MB_INST + 7] = 6.0;
      sc[(size_t)idx * MB_INST + 11] = 0.45;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      // Foreground lens (kind 8) with 2 children at (140, 280, 120, 40)
      rect_at(sc + (size_t)idx * MB_INST, 140, 280, 120, 40, 8, 1.0, 1.0, 1.0, 0);
      sc[(size_t)idx * MB_INST + 4] = 12.0;
      sc[(size_t)idx * MB_INST + 7] = 2.0;
      sc[(size_t)idx * MB_INST + 11] = 1.0;
      sc[(size_t)idx * MB_INST + 12] = 2.0; // child_n = 2
      sc[(size_t)idx * MB_INST + 14] = 4.0;
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      rect_at(sc + (size_t)idx * MB_INST, 150, 288, 40, 24, 0, 0.90, 0.30, 0.20, 0);
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      rect_at(sc + (size_t)idx * MB_INST, 200, 288, 45, 24, 0, 0.20, 0.45, 0.90, 0);
      sc[(size_t)idx * MB_INST + 18] = pw_pt; sc[(size_t)idx * MB_INST + 19] = ph_pt;
      idx++;
      CHECK(idx == TOTAL);

      // Whole frame first (primes canvas_ok = 1 via dirty whole).
      mb_host_render_dirty(0, 0, pw_pt, ph_pt);
      gl_present(sc, TOTAL, 0.92, 0.93, 0.95);
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));

      // Case A: 4 small disjoint dirty rects away from both glass groups and the lens.
      // Invalidate glass slots to prove neither off-rect glass group triggers capture()/blur().
      slots_invalidate();
      sc[21 * MB_INST + 8] = 0.95; // near (27, 83)
      sc[88 * MB_INST + 9] = 0.90; // near (160, 152)
      sc[310 * MB_INST + 10] = 0.10; // near (198, 405)
      sc[(GRID_N + 1) * MB_INST + 9] = 0.85; // oclipped rect at (300..340, 440..470)
      int vbo0 = vbo_uploads, blurs0 = blurs_made, draws0 = instanced_draws, inst0 = instanced_total;
      mb_host_render_dirty(8, 78, 56, 52);      // covers shadow + rect 21 (clear of top glass y<=70)
      mb_host_render_dirty(155, 130, 60, 50);   // covers rotated rect + rect 88
      mb_host_render_dirty(190, 398, 30, 30);   // covers rect 310
      mb_host_render_dirty(292, 432, 56, 46);   // covers oclipped rect
      gl_present(sc, TOTAL, 0.92, 0.93, 0.95);
      int vbo_d = vbo_uploads - vbo0;
      int blurs_d = blurs_made - blurs0;
      int draws_d = instanced_draws - draws0;
      int inst_d = instanced_total - inst0;
      printf("gles_render: Perf-31 4-rect partial: vbo_uploads=%d blurs=%d draws=%d inst_submitted=%d (unculled=%d)\n",
             vbo_d, blurs_d, draws_d, inst_d, 4 * TOTAL);
      CHECK(vbo_d == 1);
      CHECK(blurs_d == 0);
      CHECK(inst_d < TOTAL); // <25% of 4*TOTAL
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));

      // Case B: 2 dirty rects, one covering top glass + one covering the kind 8 lens; bottom glass remains untouched.
      slots_invalidate();
      sc[(GRID_N + 6) * MB_INST + 8] = 0.15; // lens child 1 color change
      sc[0 * MB_INST + 8] = 0.95;            // rect near top glass
      vbo0 = vbo_uploads;
      blurs0 = blurs_made;
      mb_host_render_dirty(0, 0, 400, 80);    // covers top glass
      mb_host_render_dirty(120, 260, 160, 80); // covers kind 8 lens
      gl_present(sc, TOTAL, 0.92, 0.93, 0.95);
      CHECK(vbo_uploads - vbo0 == 1);
      CHECK(blurs_made - blurs0 == 1); // only top glass blurred, bottom glass skipped!
      CHECK(surface_as_whole(p30_fb));
      CHECK(surface_as_fresh(p30_fb));

      free(sc);
    }

    glDeleteFramebuffers(1, &p30_fb);
    glDeleteTextures(1, &p30_tex);
    fb_w = W * S;
    fb_h = H * S;
    cur_w = W;
    cur_h = H;
    cur_scale = S;
    target_fb = surface;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    canvas_ok = 0;
    glass_free();
  }

  // Verify every program group (MB_PROG_*) and auxiliary program (prog_flat, post, ad_prog) compiles and links cleanly.
  {
    while (glGetError() != GL_NO_ERROR) {
    }
    for (int g = 0; g < MB_PROGS; g++) {
      use_prog(g);
      GLint linked = 0;
      CHECK(progs[g].p != 0);
      glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
      if (linked != GL_TRUE) {
        char log[1024];
        glGetProgramInfoLog(progs[g].p, sizeof log, NULL, log);
        fprintf(stderr, "gles_render: program group %d link failed: %s\n", g, log);
      }
      CHECK(linked == GL_TRUE);
    }
    ensure_prog_flat();
    ensure_post();
    ensure_ad_prog();
    GLuint aux[3] = {prog_flat, post, ad_prog};
    for (int i = 0; i < 3; i++) {
      GLint linked = 0;
      CHECK(aux[i] != 0);
      glGetProgramiv(aux[i], GL_LINK_STATUS, &linked);
      CHECK(linked == GL_TRUE);
    }
    CHECK(glGetError() == GL_NO_ERROR);
  }

  // Perf-37: mixed UI primitives (rect/text/shadow/line/icon) with tid==0 batch into a single instanced draw
  // without redundant glUseProgram switches.
  {
    double batch[12 * MB_INST];
    for (int i = 0; i < 3; i++) {
      double y = 4.0 + i * 22.0;
      // shadow (kind 2)
      rect_at(batch + (i * 4 + 0) * MB_INST, 4, y, 80, 18, 2, 0.0, 0.0, 0.0, 0);
      batch[(i * 4 + 0) * MB_INST + 7] = 2.0;
      batch[(i * 4 + 0) * MB_INST + 11] = 0.2;
      // rect (kind 0, small so bands.h does not split)
      rect_at(batch + (i * 4 + 1) * MB_INST, 4, y, 20, 16, 0, 0.2, 0.4, 0.8, 0);
      // glyph (kind 1)
      rect_at(batch + (i * 4 + 2) * MB_INST, 28, y + 2, 10, 10, 1, 0.1, 0.1, 0.1, 0);
      batch[(i * 4 + 2) * MB_INST + 12] = 16; batch[(i * 4 + 2) * MB_INST + 13] = 16;
      batch[(i * 4 + 2) * MB_INST + 14] = 16; batch[(i * 4 + 2) * MB_INST + 15] = 16;
      // line (kind 10)
      rect_at(batch + (i * 4 + 3) * MB_INST, 44, y + 2, 20, 10, 10, 0.9, 0.2, 0.1, 0);
      batch[(i * 4 + 3) * MB_INST + 4] = 2.0;
      batch[(i * 4 + 3) * MB_INST + 12] = 0.1; batch[(i * 4 + 3) * MB_INST + 13] = 0.5;
      batch[(i * 4 + 3) * MB_INST + 14] = 0.9; batch[(i * 4 + 3) * MB_INST + 15] = 0.5;
    }
    int d0 = instanced_draws, b0 = program_binds;
    gl_present(batch, 12, 1.0, 1.0, 1.0);
    int d_used = instanced_draws - d0, b_used = program_binds - b0;
    printf("gles_render: Perf-37 mixed batch (12 mixed inst): draws=%d prog_binds=%d\n", d_used, b_used);
    CHECK(d_used == 1);
    CHECK(b_used == 1);
  }

  // Perf-37: GLES 3.0 program binary disk cache (miss -> store -> warm hit -> corrupt fallback).
  {
    char cdir[256];
    snprintf(cdir, sizeof cdir, "/tmp/mbui_gl_cache_test_%ld", (long)getpid());
    prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
    gl_set_prog_cache_dir(cdir);
    // Clean any stale files from previous runs
    char rmcmd[320];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf %s", cdir);
    (void)system(rmcmd);

    GLint nfmt = 0;
    glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &nfmt);
    printf("gles_render: program_binary_formats=%d\n", (int)nfmt);

    // Cold pass: reset GL objects (simulating fresh context), compile all programs -> miss + store
    for (int g = 0; g < MB_PROGS; g++) { if (progs[g].p) glDeleteProgram(progs[g].p); progs[g].p = 0; }
    if (prog_flat) { glDeleteProgram(prog_flat); prog_flat = 0; }
    if (post) { glDeleteProgram(post); post = 0; }
    if (ad_prog) { glDeleteProgram(ad_prog); ad_prog = 0; }
    if (vs_main) { glDeleteShader(vs_main); vs_main = 0; }
    if (vs_main_ad) { glDeleteShader(vs_main_ad); vs_main_ad = 0; }
    if (vs_post) { glDeleteShader(vs_post); vs_post = 0; }
    prog_now = 0;
    prog_bin_checked = 0;

    for (int g = 0; g < MB_PROGS; g++) use_prog(g);
    ensure_prog_flat();
    ensure_post();
    ensure_ad_prog();
    int total_progs = MB_PROGS + 3;
    if (nfmt > 0) {
      CHECK(prog_cache_misses == total_progs);
      CHECK(prog_cache_stores == total_progs);
      CHECK(prog_cache_hits == 0);

      // Warm pass: reset GL objects, reload all programs from disk cache -> all hits, zero shader compiles
      for (int g = 0; g < MB_PROGS; g++) { glDeleteProgram(progs[g].p); progs[g].p = 0; }
      glDeleteProgram(prog_flat); prog_flat = 0;
      glDeleteProgram(post); post = 0;
      glDeleteProgram(ad_prog); ad_prog = 0;
      if (vs_main) { glDeleteShader(vs_main); vs_main = 0; }
      if (vs_main_ad) { glDeleteShader(vs_main_ad); vs_main_ad = 0; }
      if (vs_post) { glDeleteShader(vs_post); vs_post = 0; }
      prog_now = 0;
      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;

      for (int g = 0; g < MB_PROGS; g++) {
        use_prog(g);
        GLint linked = 0;
        glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
        CHECK(linked == GL_TRUE);
      }
      ensure_prog_flat();
      ensure_post();
      ensure_ad_prog();
      CHECK(prog_cache_hits == total_progs);
      CHECK(prog_cache_misses == 0);
      CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
      CHECK(glGetError() == GL_NO_ERROR);

      // Corrupt-file fallback: overwrite every .glbin with garbage, verify clean fallback recompile & restore
      char corcmd[400];
      snprintf(corcmd, sizeof corcmd, "for f in %s/*.glbin; do printf 'BADDATA' > \"$f\"; done", cdir);
      (void)system(corcmd);
      for (int g = 0; g < MB_PROGS; g++) { glDeleteProgram(progs[g].p); progs[g].p = 0; }
      glDeleteProgram(prog_flat); prog_flat = 0;
      glDeleteProgram(post); post = 0;
      glDeleteProgram(ad_prog); ad_prog = 0;
      prog_now = 0;
      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;

      for (int g = 0; g < MB_PROGS; g++) {
        use_prog(g);
        GLint linked = 0;
        glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
        CHECK(linked == GL_TRUE);
      }
      ensure_prog_flat();
      ensure_post();
      ensure_ad_prog();
      CHECK(prog_cache_hits == 0);
      CHECK(prog_cache_misses == total_progs);
      CHECK(prog_cache_stores == total_progs);
      CHECK(glGetError() == GL_NO_ERROR);

      // Verify rendering still works after binary-loaded programs
      double smoke[MB_INST];
      rect_at(smoke, 10, 10, 20, 20, 0, 0.2, 0.7, 0.3, 0);
      gl_present(smoke, 1, 0.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *p = px + ((fb_h - 1 - 40) * fb_w + 40) * 4;
      CHECK(p[1] > 150 && p[0] < 80);
      free(px);
    }
    gl_set_prog_cache_dir(NULL);
    (void)system(rmcmd);
  }

  // Wave 1: gl_setup() preloads only existing valid .glbin cache hits (zero shader compiles on empty/partial/warm).
  {
    char pdir[256];
    snprintf(pdir, sizeof pdir, "/tmp/mbui_gl_preload_test_%ld", (long)getpid());
    char rmcmd[320];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf %s", pdir);
    (void)system(rmcmd);

    GLint nfmt = 0;
    glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &nfmt);
    int total_progs = MB_PROGS + 3;

    // 1) Empty cache dir: gl_setup() compiles nothing, loads nothing, records zero hits and zero misses.
    gl_set_prog_cache_dir(pdir);
    prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
    gl_setup();
    for (int g = 0; g < MB_PROGS; g++) CHECK(progs[g].p == 0);
    CHECK(prog_flat == 0 && post == 0 && ad_prog == 0);
    CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
    CHECK(prog_cache_hits == 0 && prog_cache_misses == 0 && prog_now == 0);

    if (nfmt > 0) {
      // 2) Warm cache dir: populate all MB_PROGS + 3 .glbin files, then verify gl_setup() preloads all of them.
      for (int g = 0; g < MB_PROGS; g++) use_prog(g);
      ensure_prog_flat();
      ensure_post();
      ensure_ad_prog();
      CHECK(prog_cache_stores == total_progs);

      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
      gl_setup();
      CHECK(prog_cache_hits == total_progs);
      CHECK(prog_cache_misses == 0);
      CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
      CHECK(prog_now == 0);
      for (int g = 0; g < MB_PROGS; g++) {
        GLint linked = 0;
        CHECK(progs[g].p != 0);
        glGetProgramiv(progs[g].p, GL_LINK_STATUS, &linked);
        CHECK(linked == GL_TRUE);
      }
      CHECK(prog_flat != 0 && post != 0 && ad_prog != 0);
      CHECK(glGetError() == GL_NO_ERROR);

      glBindFramebuffer(GL_FRAMEBUFFER, surface);
      double smoke[MB_INST];
      rect_at(smoke, 10, 10, 20, 20, 0, 0.2, 0.7, 0.3, 0);
      gl_present(smoke, 1, 0.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *p = px + ((fb_h - 1 - 40) * fb_w + 40) * 4;
      CHECK(p[1] > 150 && p[0] < 80);
      free(px);
      CHECK(glGetError() == GL_NO_ERROR);

      // 3) Partial cache dir: keep only MB_PROG_UI and post .glbin files, verify gl_setup() loads only those two
      //    with zero shader compilation, and remaining programs still compile lazily on demand.
      (void)system(rmcmd);
      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
      gl_setup();
      use_prog(MB_PROG_UI);
      ensure_post();
      CHECK(prog_cache_stores == 2);

      prog_cache_hits = prog_cache_misses = prog_cache_stores = 0;
      gl_setup();
      CHECK(prog_cache_hits == 2);
      CHECK(prog_cache_misses == 0);
      CHECK(vs_main == 0 && vs_main_ad == 0 && vs_post == 0);
      CHECK(prog_now == 0);
      CHECK(progs[MB_PROG_UI].p != 0 && post != 0);
      CHECK(progs[MB_PROG_PATH].p == 0 && progs[MB_PROG_FROSTED].p == 0 &&
            progs[MB_PROG_LIQUID_MERGED].p == 0 && progs[MB_PROG_LIQUID_SINGLE].p == 0 &&
            progs[MB_PROG_LENS].p == 0 && prog_flat == 0 && ad_prog == 0);

      // Draw a frosted glass scene (small rect so bands.h does not invoke prog_flat):
      // triggers lazy compile for MB_PROG_FROSTED alone (MB_PROG_UI and post are already preloaded).
      glBindFramebuffer(GL_FRAMEBUFFER, surface);
      double fg[2 * MB_INST];
      rect_at(fg, 25, 25, 10, 10, 0, 0.9, 0.1, 0.1, 0);
      rect_at(fg + MB_INST, 20, 20, 40, 30, 5, 1, 1, 1, -2);
      fg[MB_INST + 7] = 4;
      fg[MB_INST + 11] = 0.5;
      gl_present(fg, 2, 0.1, 0.2, 0.3);
      CHECK(progs[MB_PROG_FROSTED].p != 0);
      CHECK(prog_cache_misses == 1 && prog_cache_stores == 1);
      CHECK(progs[MB_PROG_LIQUID_MERGED].p == 0 && progs[MB_PROG_LIQUID_SINGLE].p == 0 &&
            progs[MB_PROG_LENS].p == 0 && progs[MB_PROG_PATH].p == 0 && prog_flat == 0 && ad_prog == 0);
      CHECK(glGetError() == GL_NO_ERROR);
    }

    printf("gles_render: gl_setup cache preload ok (nfmt=%d)\n", (int)nfmt);
    gl_set_prog_cache_dir(NULL);
    (void)system(rmcmd);
  }

  // Programs made ahead: asked for once, after a new context's first frame; what was made is taken where a frame
  // first needs it, nothing compiled then; what was made for a context gone is not handed over.
  {
    char adir[256];
    snprintf(adir, sizeof adir, "/tmp/mbui_gl_ahead_test_%ld", (long)getpid());
    char rmcmd[320];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf %s", adir);
    (void)system(rmcmd);
    gl_set_prog_cache_dir(adir);
    gl_setup();
    ahead_started = 0;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    double one[MB_INST];
    rect_at(one, 10, 10, 20, 20, 0, 0.2, 0.7, 0.3, 0);
    gl_present(one, 1, 0.0, 0.0, 0.0);
    CHECK(ahead_started == 1 && ahead_started_gen == ahead_gen);
    gl_present(one, 1, 0.0, 0.0, 0.0);
    CHECK(ahead_started == 1);
    // (the first frame made the plain one, MB_PROG_UI, itself: every other slot made ahead)
    CHECK(gl_progs_ahead(ahead_started_gen) == MB_SLOTS - 1);
    CHECK(progs[MB_PROG_FROSTED].p == 0 && post == 0);
    prog_cache_misses = 0;
    double fg[2 * MB_INST];
    rect_at(fg, 25, 25, 10, 10, 0, 0.9, 0.1, 0.1, 0);
    rect_at(fg + MB_INST, 20, 20, 40, 30, 5, 1, 1, 1, -2);
    fg[MB_INST + 7] = 4;
    fg[MB_INST + 11] = 0.5;
    gl_present(fg, 2, 0.1, 0.2, 0.3);
    CHECK(progs[MB_PROG_FROSTED].p != 0 && post != 0);
    CHECK(prog_cache_misses == 0);
    CHECK(ahead_progs[MB_PROG_FROSTED] == 0 && ahead_progs[MB_SLOT_POST] == 0);
    CHECK(glGetError() == GL_NO_ERROR);
    // (a context made anew: the one before's programs dropped, none made for it handed over)
    unsigned old = ahead_gen;
    gl_setup();
    for (int i = 0; i < MB_SLOTS; i++) CHECK(ahead_progs[i] == 0);
    CHECK(gl_progs_ahead(old) == 0);
    for (int i = 0; i < MB_SLOTS; i++) CHECK(ahead_progs[i] == 0);
    printf("gles_render: programs made ahead ok\n");
    gl_set_prog_cache_dir(NULL);
    (void)system(rmcmd);
  }

  // P0 optics fix numerical smoke vectors:
  // 0: Dark Regular (0x20202067) over #000000 -> (30,30,30)
  // 1: Dark Regular (0x20202067) over #1B1C1F -> (46,47,50)
  // 2: Dark Adaptive (0x20202067, adaptive=1) over #FFFFFF -> (93,93,93)
  // 3: Light Regular (0xFDFCFD67) over #0088FF -> (40,154,255), HSV S >= 0.75
  // 4: Pure Clear (0xFFFFFF00, regMix=0) over (0,255,64) -> (0,255,64)
  {
    struct {
      const char *name;
      double bg_r, bg_g, bg_b;
      double t_r, t_g, t_b, t_a;
      double blur, adaptive;
      int exp_r, exp_g, exp_b, tol;
    } p0_cases[5] = {
      {"dark_black",    0.0, 0.0, 0.0,                   32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0,  0.0, 30,  30,  30, 3},
      {"dark_1b1c1f",   27.0/255.0, 28.0/255.0, 31.0/255.0, 32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0, 0.0, 46,  47,  50, 3},
      {"dark_ad_white", 1.0, 1.0, 1.0,                   32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0, -1.0, 93,  93,  93, 3},
      {"light_blue",    0.0, 136.0/255.0, 1.0,           253.0/255.0, 252.0/255.0, 253.0/255.0, 0x67/255.0, 2.0, 0.0, 40, 154, 255, 3},
      {"pure_clear",    0.0, 1.0, 64.0/255.0,            1.0, 1.0, 1.0, 0.0,                              0.0,  0.0,  0, 255,  64, 1},
    };
    double p0[2 * MB_INST];
    for (int ci = 0; ci < 5; ci++) {
      rect_at(p0, 0, 0, W, H, 0, p0_cases[ci].bg_r, p0_cases[ci].bg_g, p0_cases[ci].bg_b, 0);
      rect_at(p0 + MB_INST, 10, 10, 80, 50, 6, p0_cases[ci].t_r, p0_cases[ci].t_g, p0_cases[ci].t_b, -30 - ci);
      p0[MB_INST + 4] = 12.0;
      p0[MB_INST + 6] = 1.0;
      p0[MB_INST + 7] = p0_cases[ci].blur;
      p0[MB_INST + 11] = p0_cases[ci].t_a;
      p0[MB_INST + 12] = 0.0;
      p0[MB_INST + 13] = 4.0;
      p0[MB_INST + 14] = p0_cases[ci].adaptive;
      p0[MB_INST + 15] = 1.0;
      p0[MB_INST + 21] = 0.0;
      p0[MB_INST + 22] = 0.0;
      p0[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(p0, 2, p0_cases[ci].bg_r, p0_cases[ci].bg_g, p0_cases[ci].bg_b);
      unsigned char *px = pixels_of_fb(surface);
      unsigned char *c = px + ((fb_h - 1 - 70) * fb_w + 100) * 4;
      printf("gles_render: p0_%s rgb=(%d,%d,%d) exp=(%d,%d,%d)\n",
             p0_cases[ci].name, c[0], c[1], c[2], p0_cases[ci].exp_r, p0_cases[ci].exp_g, p0_cases[ci].exp_b);
      CHECK(abs((int)c[0] - p0_cases[ci].exp_r) <= p0_cases[ci].tol);
      CHECK(abs((int)c[1] - p0_cases[ci].exp_g) <= p0_cases[ci].tol);
      CHECK(abs((int)c[2] - p0_cases[ci].exp_b) <= p0_cases[ci].tol);
      if (ci == 3) {
        double mx = fmax(fmax(c[0], c[1]), c[2]);
        double mn = fmin(fmin(c[0], c[1]), c[2]);
        double hsv_s = mx > 0.0 ? (mx - mn) / mx : 0.0;
        printf("gles_render: p0_light_blue hsv_s=%.3f\n", hsv_s);
        CHECK(hsv_s >= 0.75);
      }
      free(px);
    }
  }

  // Commit 2 V8/V9 2D Multi-Pixel ROI Gates (Slider, Switch ON/OFF, 3x TIR rows, 2x phase-shifted TIR, Light Segmented Prism):
  {
    int saved_fb_w = fb_w, saved_fb_h = fb_h;
    double saved_w = cur_w, saved_h = cur_h, saved_s = cur_scale;
    GLuint saved_surface = surface;
    GLuint saved_target = target_fb;
    int VW = 160, VH = 80;
    GLuint vtex = 0, vfb = 0;
    glGenTextures(1, &vtex);
    glGenFramebuffers(1, &vfb);
    surface = vfb;
    target_fb = vfb;

    #define V_RECT(d, x, y, w, h, k, r, g, b, tid) do { \
      rect_at((d), (x), (y), (w), (h), (k), (r), (g), (b), (tid)); \
      (d)[18] = VW; (d)[19] = VH; \
    } while (0)
    #define V_SETUP(SC) do { \
      fb_w = VW * (SC); fb_h = VH * (SC); cur_w = VW; cur_h = VH; cur_scale = (SC); \
      glDeleteTextures(1, &vtex); glGenTextures(1, &vtex); \
      glBindTexture(GL_TEXTURE_2D, vtex); \
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h); \
      glBindFramebuffer(GL_FRAMEBUFFER, vfb); \
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, vtex, 0); \
      glass_forget(); \
    } while (0)
    #define V_PX(buf, xpx, ypx) ((buf) + ((fb_h - 1 - (ypx)) * fb_w + (xpx)) * 4)

    // --- V8a: Slider Dark & Light @ 3x ---
    V_SETUP(3);
    for (int is_light = 0; is_light <= 1; is_light++) {
      double bg = is_light ? 1.0 : 28.0 / 255.0;
      double bg_b = is_light ? 1.0 : 30.0 / 255.0;
      double sl[4 * MB_INST];
      V_RECT(sl, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
      V_RECT(sl + MB_INST, 10, 37, 70, 6, 0, 0.0, 136.0 / 255.0, 1.0, 0);
      V_RECT(sl + 2 * MB_INST, 80, 37, 70, 6, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
      V_RECT(sl + 3 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -50 - is_light);
      sl[3 * MB_INST + 4] = 19.0; sl[3 * MB_INST + 6] = 1.0; sl[3 * MB_INST + 7] = -16.0;
      sl[3 * MB_INST + 11] = 0.0; sl[3 * MB_INST + 12] = 1.0; sl[3 * MB_INST + 13] = 9.0;
      sl[3 * MB_INST + 15] = 1.0; sl[3 * MB_INST + 21] = 9.0; sl[3 * MB_INST + 22] = 0.0; sl[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sl, 4, bg, bg, bg_b);
      unsigned char *px = pixels_of_fb(vfb);

      double max_bh = 0.0, peak_dx = 0.0, h_55 = 0.0;
      double max_gh = 0.0, grey_peak_dx = 0.0, grey_h55 = 0.0;
      for (int i = 0; i <= 18; i++) {
        int x_l = 51 * 3 + i;
        int cnt = 0;
        for (int ypx = 21 * 3; ypx < 59 * 3; ypx++) {
          unsigned char *c = V_PX(px, x_l, ypx);
          if ((int)c[2] - (int)c[0] > 100) cnt++;
        }
        double hpt = cnt / 3.0;
        double dx_l = (i + 0.5) / 3.0;
        if (hpt > max_bh) { max_bh = hpt; peak_dx = dx_l; }
        if (i == 16) h_55 = hpt;
      }
      // Right grey peak height (mirrored pixel centers x_r = 109*3 - 1 - i)
      unsigned char *bg_ref = V_PX(px, 80 * 3, 25 * 3);
      double ref_y = 0.2126 * bg_ref[0] + 0.7152 * bg_ref[1] + 0.0722 * bg_ref[2];
      for (int i = 0; i <= 18; i++) {
        int x_r = 109 * 3 - 1 - i;
        int cnt = 0;
        for (int ypx = 33 * 3; ypx < 47 * 3; ypx++) {
          unsigned char *c = V_PX(px, x_r, ypx);
          double cy = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
          if (is_light ? (cy < ref_y - 70.0) : (cy > ref_y + 20.0)) cnt++;
        }
        double hpt = cnt / 3.0;
        double dx_r = (i + 0.5) / 3.0;
        if (hpt > max_gh) { max_gh = hpt; grey_peak_dx = dx_r; }
        if (i == 16) grey_h55 = hpt;
      }
      // Center unshifted + zero blue at |dy| >= 14pt
      unsigned char *c_l = V_PX(px, (int)(79.3 * 3), 40 * 3);
      unsigned char *c_r = V_PX(px, (int)(80.7 * 3), 40 * 3);
      unsigned char *c_top = V_PX(px, 60 * 3, 25 * 3);
      unsigned char *c_bot = V_PX(px, 60 * 3, 55 * 3);
      // 5-point 3D thickness profile at x = 80 (dy = 0, 0.67, 2.0, 9.0, 24.0pt from y = 21)
      unsigned char *t0 = V_PX(px, 80 * 3, 21 * 3);
      unsigned char *t1 = V_PX(px, 80 * 3, 21 * 3 + 2);
      unsigned char *t2 = V_PX(px, 80 * 3, 23 * 3);
      unsigned char *t9 = V_PX(px, 80 * 3, 30 * 3);
      unsigned char *t24 = V_PX(px, 80 * 3, 45 * 3);
      double y0 = 0.2126 * t0[0] + 0.7152 * t0[1] + 0.0722 * t0[2];
      double y1 = 0.2126 * t1[0] + 0.7152 * t1[1] + 0.0722 * t1[2];
      double y2 = 0.2126 * t2[0] + 0.7152 * t2[1] + 0.0722 * t2[2];
      double y9 = 0.2126 * t9[0] + 0.7152 * t9[1] + 0.0722 * t9[2];
      double y24 = 0.2126 * t24[0] + 0.7152 * t24[1] + 0.0722 * t24[2];
      printf("gles_render: v8_slider(%s) blue_peak=%.2f@dx=%.2f blue_h55=%.2f grey_peak=%.2f@dx=%.2f grey_h55=%.2f prof5=(%.0f,%.0f,%.0f,%.0f,%.0f)\n",
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

    // --- V8a2: Horizontal-stripe vertical monotonicity (zero folding) ---
    {
      double st[42 * MB_INST];
      V_RECT(st, 0, 0, VW, VH, 0, 0.0, 0.0, 0.0, 0);
      for (int i = 0; i < 40; i++) {
        double v = fmin(1.0, fmax(0.0, (i - 12.0) / 16.0));
        V_RECT(st + (i + 1) * MB_INST, 0, 20 + i, VW, 1, 0, 1.0 - v, 0.0, v, 0);
      }
      V_RECT(st + 41 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -52);
      st[41 * MB_INST + 4] = 19.0; st[41 * MB_INST + 6] = 1.0; st[41 * MB_INST + 7] = -16.0;
      st[41 * MB_INST + 11] = 0.0; st[41 * MB_INST + 12] = 1.0; st[41 * MB_INST + 13] = 9.0;
      st[41 * MB_INST + 15] = 1.0; st[41 * MB_INST + 21] = 9.0; st[41 * MB_INST + 22] = 0.0; st[41 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(st, 42, 0.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(vfb);
      int xpx = (int)(51.85 * 3);
      int prev = -1000;
      int mono_ok = 1;
      for (int ypx = 36 * 3; ypx <= 44 * 3; ypx++) {
        unsigned char *c = V_PX(px, xpx, ypx);
        int cur = (int)c[2] - (int)c[0];  // B - R: invariant to achromatic specular rim
        if (prev > -999 && cur < prev - 6) mono_ok = 0;
        prev = cur;
      }
      CHECK(mono_ok);
      free(px);
    }

    // --- V8b: 124x48pt dropRole=0 magnifier unaffected + Role 0 real zoom (1.18) contact-edge push ---
    {
      double mg[3 * MB_INST];
      V_RECT(mg, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(mg + MB_INST, 0, 37, VW, 6, 0, 0.0, 136.0 / 255.0, 1.0, 0);
      V_RECT(mg + 2 * MB_INST, 18, 16, 124, 48, 6, 1.0, 1.0, 1.0, -53);
      mg[2 * MB_INST + 4] = 24.0; mg[2 * MB_INST + 6] = 1.0; mg[2 * MB_INST + 7] = 0.0;
      mg[2 * MB_INST + 11] = 0.0; mg[2 * MB_INST + 12] = 1.0; mg[2 * MB_INST + 13] = 8.0;
      mg[2 * MB_INST + 15] = 1.0; mg[2 * MB_INST + 21] = 3.0; mg[2 * MB_INST + 22] = 0.0; mg[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(mg, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      int cnt = 0;
      for (int ypx = 16 * 3; ypx < 64 * 3; ypx++) {
        unsigned char *c = V_PX(px, 19 * 3, ypx);
        if ((int)c[2] - (int)c[0] > 100) cnt++;
      }
      printf("gles_render: v8_magnifier_role0 h(1.0)=%.2f\n", cnt / 3.0);
      CHECK(cnt / 3.0 < 7.0);
      free(px);
    }
    {
      double zm[3 * MB_INST];
      V_RECT(zm, 0, 0, VW, VH, 0, 1.0, 0.0, 0.0, 0);
      V_RECT(zm + MB_INST, 0, 0, 55.2, VH, 0, 0.0, 1.0, 0.0, 0);
      V_RECT(zm + 2 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -59);
      zm[2 * MB_INST + 4] = 19.0; zm[2 * MB_INST + 6] = 1.0; zm[2 * MB_INST + 7] = -0.18;
      zm[2 * MB_INST + 11] = 0.0; zm[2 * MB_INST + 12] = 1.0; zm[2 * MB_INST + 13] = 8.0;
      zm[2 * MB_INST + 15] = 1.0; zm[2 * MB_INST + 21] = 8.0; zm[2 * MB_INST + 22] = 0.0; zm[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(zm, 3, 1.0, 0.0, 0.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *edge = V_PX(px, 51 * 3, 40 * 3);
      printf("gles_render: v8_role0_zoom118_contact rgb=(%d,%d,%d)\n", edge[0], edge[1], edge[2]);
      CHECK((int)edge[1] > (int)edge[0] + 40);
      free(px);
    }

    // --- V9a: Switch ON @ 3x (core + moat from y_top+2 >= 6.5pt + 3 adjacent TIR rows + neutral outer right tip) ---
    {
      double sw[3 * MB_INST];
      V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sw + MB_INST, 40, 26, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
      sw[MB_INST + 4] = 14.0;
      V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -54);
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
      sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *r0 = V_PX(px, 80 * 3, 21 * 3 + 0);  // d = 0.167pt
      unsigned char *r1 = V_PX(px, 80 * 3, 21 * 3 + 1);  // d = 0.500pt
      unsigned char *r2 = V_PX(px, 80 * 3, 21 * 3 + 2);  // d = 0.833pt
      int gr0 = (int)r0[1] - (int)r0[0];
      int gr1 = (int)r1[1] - (int)r1[0];
      int gr2 = (int)r2[1] - (int)r2[0];
      int core_px = 0, first_core_y = -1;
      for (int ypx = 21 * 3 + 2; ypx < 59 * 3; ypx++) {
        unsigned char *c = V_PX(px, 80 * 3, ypx);
        if ((int)c[1] - (int)c[0] > 60) {
          if (first_core_y < 0) first_core_y = ypx;
          core_px++;
        }
      }
      double moat_top_pt = first_core_y >= 0 ? (first_core_y - (21 * 3 + 2)) / 3.0 : 0.0;
      unsigned char *tip = V_PX(px, (int)(111.5 * 3), 40 * 3);
      int tip_gr = (int)tip[1] - (int)tip[0];
      printf("gles_render: v9_switch_on_3x tir=(%d,%d,%d) core=%.2f moat_top=%.2f tip_gr=%d\n",
             gr0, gr1, gr2, core_px / 3.0, moat_top_pt, tip_gr);
      CHECK(gr0 < 15 && gr1 > 60 && gr2 < 15);
      CHECK(core_px / 3.0 >= 20.0 && core_px / 3.0 <= 22.5);
      CHECK(moat_top_pt >= 6.5);
      CHECK(tip_gr < 15);
      free(px);
    }

    // --- V9b: Switch OFF @ 3x + right-cap inward horizontal profile ---
    {
      double sw[4 * MB_INST];
      V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sw + MB_INST, 40, 26, 63, 28, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
      sw[MB_INST + 4] = 14.0;
      V_RECT(sw + 2 * MB_INST, 85.0, 26.0, 2.0, 28.0, 0, 0.0, 136.0 / 255.0, 1.0, 0);
      V_RECT(sw + 3 * MB_INST, 30.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -55);
      sw[3 * MB_INST + 4] = 19.2; sw[3 * MB_INST + 6] = 1.0; sw[3 * MB_INST + 7] = -32.0;
      sw[3 * MB_INST + 11] = 0.0; sw[3 * MB_INST + 12] = 1.0; sw[3 * MB_INST + 13] = 9.0;
      sw[3 * MB_INST + 15] = 1.0; sw[3 * MB_INST + 21] = 9.0; sw[3 * MB_INST + 22] = 0.0; sw[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sw, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *core_c = V_PX(px, 60 * 3, 40 * 3);
      unsigned char *moat_c = V_PX(px, 60 * 3, 25 * 3);
      unsigned char *h0 = V_PX(px, 60 * 3, 21 * 3);
      unsigned char *rm = V_PX(px, 60 * 3, 21 * 3 + 2);
      unsigned char *rcap = V_PX(px, (int)(88.6 * 3), 40 * 3);
      unsigned char *rtir = V_PX(px, (int)(89.3 * 3), 40 * 3);
      int rcap_br = (int)rcap[2] - (int)rcap[0];
      int rtir_br = (int)rtir[2] - (int)rtir[0];
      printf("gles_render: v9_switch_off_3x core=%d moat=%d rim=%d h0=%d rcap_br=%d rtir_br=%d\n",
             core_c[0], moat_c[0], rm[0], h0[0], rcap_br, rtir_br);
      CHECK(core_c[0] > moat_c[0] + 15 && rm[0] > h0[0]);
      CHECK(rcap_br < 20 && rtir_br > 80);
      free(px);
    }

    // --- V9b2: Switch half-press p = 0.5 / 0.6 / 1.0 pinch displacement on 2D color grid ---
    {
      double ps[3] = { 0.5, 0.6, 1.0 };
      int red_rows[3] = { 0, 0, 0 };
      for (int pi = 0; pi < 3; pi++) {
        double p = ps[pi];
        double sw[3 * MB_INST];
        V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(sw + MB_INST, 40, 20, 80, 7, 0, 1.0, 0.0, 0.0, 0);
        V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -60 - pi);
        sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
        sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0 * p; sw[2 * MB_INST + 13] = 9.0 * p;
        sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0 * p; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
        glass_forget();
        gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *px = pixels_of_fb(vfb);
        for (int ypx = 27 * 3; ypx < 38 * 3; ypx++) {
          unsigned char *c = V_PX(px, 80 * 3, ypx);
          if ((int)c[0] - (int)c[2] > 80) red_rows[pi]++;
        }
        free(px);
      }
      printf("gles_render: v9_switch_half_press red_shift_px=(p0.5:%d, p0.6:%d, p1.0:%d)\n",
             red_rows[0], red_rows[1], red_rows[2]);
      CHECK(red_rows[0] >= 4 && red_rows[1] >= red_rows[0] && red_rows[2] > red_rows[1]);
    }

    // --- V9c: Light Segmented Prism @ 3x (top/bot cyan, left/right amber, dark-stroke text ROI chroma-0 invariance) ---
    {
      double sg[4 * MB_INST];
      V_RECT(sg, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
      V_RECT(sg + MB_INST, 60.0, 34.0, 4.0, 12.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 0);
      V_RECT(sg + 2 * MB_INST, 78.0, 36.0, 22.0, 3.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 0);
      V_RECT(sg + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -56);
      sg[3 * MB_INST + 4] = 22.5; sg[3 * MB_INST + 6] = 1.0; sg[3 * MB_INST + 7] = -48.0;
      sg[3 * MB_INST + 11] = 0.0; sg[3 * MB_INST + 12] = 1.0; sg[3 * MB_INST + 13] = 9.0;
      sg[3 * MB_INST + 15] = 1.0; sg[3 * MB_INST + 21] = 9.0; sg[3 * MB_INST + 22] = 0.04; sg[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sg, 4, 1.0, 1.0, 1.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *top = V_PX(px, 80 * 3, (int)(18.4 * 3));
      unsigned char *bot = V_PX(px, 80 * 3, (int)(61.6 * 3));
      unsigned char *lft = V_PX(px, (int)(25.9 * 3), 40 * 3);
      unsigned char *rgt = V_PX(px, (int)(134.1 * 3), 40 * 3);
      printf("gles_render: v9_seg_light top B-R=%d bot B-R=%d lft R-B=%d rgt R-B=%d\n",
             (int)top[2] - (int)top[0], (int)bot[2] - (int)bot[0],
             (int)lft[0] - (int)lft[2], (int)rgt[0] - (int)rgt[2]);
      CHECK((int)top[2] - (int)top[0] >= 10);
      CHECK((int)bot[2] - (int)bot[0] >= 10);
      CHECK((int)lft[0] - (int)lft[2] >= 20);
      CHECK((int)rgt[0] - (int)rgt[2] >= 20);
      sg[3 * MB_INST + 20] = -561;
      sg[3 * MB_INST + 22] = 0.0;
      glass_forget();
      gl_present(sg, 4, 1.0, 1.0, 1.0);
      unsigned char *px0 = pixels_of_fb(vfb);
      int text_max_diff = 0;
      for (int py = 32 * 3; py <= 48 * 3; py++) {
        for (int px_i = 55 * 3; px_i <= 105 * 3; px_i++) {
          unsigned char *a = V_PX(px, px_i, py);
          unsigned char *b = V_PX(px0, px_i, py);
          for (int ch = 0; ch < 3; ch++) {
            int df = abs((int)a[ch] - (int)b[ch]);
            if (df > text_max_diff) text_max_diff = df;
          }
        }
      }
      printf("gles_render: v9_seg_text_roi_diff=%d\n", text_max_diff);
      CHECK(text_max_diff == 0);
      free(px);
      free(px0);
    }

    // --- V9e: Switch uniform green (48,209,88) center RGB ~(57,218,97) + blue-track swap + OFF r9->r4.5 + 5-level press ---
    {
      double sg[2 * MB_INST];
      V_RECT(sg, 0, 0, VW, VH, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
      V_RECT(sg + MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -562);
      sg[MB_INST + 4] = 19.2; sg[MB_INST + 6] = 1.0; sg[MB_INST + 7] = -32.0;
      sg[MB_INST + 11] = 0.0; sg[MB_INST + 12] = 1.0; sg[MB_INST + 13] = 9.0;
      sg[MB_INST + 15] = 1.0; sg[MB_INST + 21] = 9.0; sg[MB_INST + 22] = 0.0; sg[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sg, 2, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      unsigned char *c = V_PX(px, (int)lround(82.5 * 3), (int)lround(40.2 * 3));
      printf("gles_render: v9_switch_green_ctr rgb=(%d,%d,%d) exp=(57,218,97)\n", c[0], c[1], c[2]);
      CHECK(abs((int)c[0] - 57) <= 2 && abs((int)c[1] - 218) <= 2 && abs((int)c[2] - 97) <= 2);
      free(px);

      // Blue track swap: first colored caustic pixel turns blue
      double sb[3 * MB_INST];
      V_RECT(sb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sb + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 0.0, 122.0 / 255.0, 1.0, 0);
      sb[MB_INST + 4] = 14.0;
      sb[MB_INST + 36] = 14.0; sb[MB_INST + 37] = 14.0; sb[MB_INST + 38] = 14.0; sb[MB_INST + 39] = 14.0;
      V_RECT(sb + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -5621);
      sb[2 * MB_INST + 4] = 19.2; sb[2 * MB_INST + 6] = 1.0; sb[2 * MB_INST + 7] = -32.0;
      sb[2 * MB_INST + 11] = 0.0; sb[2 * MB_INST + 12] = 1.0; sb[2 * MB_INST + 13] = 9.0;
      sb[2 * MB_INST + 15] = 1.0; sb[2 * MB_INST + 21] = 9.0; sb[2 * MB_INST + 22] = 0.0; sb[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *pxb = pixels_of_fb(vfb);
      unsigned char *cb = V_PX(pxb, 80 * 3, 21 * 3 + 1);
      printf("gles_render: v9_switch_blue_caustic rgb=(%d,%d,%d) B-R=%d\n", cb[0], cb[1], cb[2], (int)cb[2] - (int)cb[0]);
      CHECK((int)cb[2] - (int)cb[0] >= 100 && cb[2] > cb[1]);
      free(pxb);

      // OFF fixed press: slot 21 9.0 -> 4.5 narrows neutral moat
      int off_moat[2] = {0, 0};
      double refs[2] = {9.0, 4.5};
      for (int ri = 0; ri < 2; ri++) {
        double so[3 * MB_INST];
        V_RECT(so, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(so + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
        so[MB_INST + 4] = 14.0;
        so[MB_INST + 36] = 14.0; so[MB_INST + 37] = 14.0; so[MB_INST + 38] = 14.0; so[MB_INST + 39] = 14.0;
        V_RECT(so + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -5622 - ri);
        so[2 * MB_INST + 4] = 19.2; so[2 * MB_INST + 6] = 1.0; so[2 * MB_INST + 7] = -32.0;
        so[2 * MB_INST + 11] = 0.0; so[2 * MB_INST + 12] = 1.0; so[2 * MB_INST + 13] = 9.0;
        so[2 * MB_INST + 15] = 1.0; so[2 * MB_INST + 21] = refs[ri]; so[2 * MB_INST + 22] = 0.0; so[2 * MB_INST + 23] = 0.0;
        glass_forget();
        gl_present(so, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *pxo = pixels_of_fb(vfb);
        int best = 0, cur = 0;
        for (int py = 21 * 3 + 2; py < 40 * 3; py++) {
          unsigned char *c0 = V_PX(pxo, 80 * 3, py);
          if (c0[0] < 95) { cur++; if (cur > best) best = cur; } else cur = 0;
        }
        off_moat[ri] = best;
        free(pxo);
      }
      printf("gles_render: v9_switch_off_moat r9=%dpx r4.5=%dpx\n", off_moat[0], off_moat[1]);
      CHECK(off_moat[0] > off_moat[1] && off_moat[1] >= 1);

      // Real white-cap + glass 5-level press (0.0, 0.25, 0.5, 0.75, 1.0) monotonic visible delta area vs p=0 rest (synced with liquid_toggle.mbt)
      double ps[5] = {0.0, 0.25, 0.50, 0.75, 1.0};
      int areas[5] = {0, 0, 0, 0, 0};
      unsigned char *px_rest = NULL;
      for (int pi = 0; pi < 5; pi++) {
        double p = ps[pi];
        double sc5[4 * MB_INST];
        V_RECT(sc5, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(sc5 + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
        sc5[MB_INST + 4] = 14.0;
        sc5[MB_INST + 36] = 14.0; sc5[MB_INST + 37] = 14.0; sc5[MB_INST + 38] = 14.0; sc5[MB_INST + 39] = 14.0;
        double cw = 37.0 * (1.0 + 0.60 * p), ch = 24.0 * (1.0 + 0.60 * p);
        double cx0 = 82.5 - cw * 0.5, cy0 = 40.0 - ch * 0.5;
        double cap_a = 1.0 - 1.8 * p;
        if (cap_a < 0.0) cap_a = 0.0;
        if (cap_a > 1.0) cap_a = 1.0;
        V_RECT(sc5 + 2 * MB_INST, cx0, cy0, cw, ch, 0, 1.0, 1.0, 1.0, 0);
        sc5[2 * MB_INST + 4] = ch * 0.5;
        sc5[2 * MB_INST + 11] = cap_a;
        sc5[2 * MB_INST + 36] = ch * 0.5; sc5[2 * MB_INST + 37] = ch * 0.5;
        sc5[2 * MB_INST + 38] = ch * 0.5; sc5[2 * MB_INST + 39] = ch * 0.5;
        int ninst = 3;
        if (p > 0.001) {
          V_RECT(sc5 + 3 * MB_INST, cx0, cy0, cw, ch, 6, 1.0, 1.0, 1.0, -5625 - pi);
          sc5[3 * MB_INST + 4] = ch * 0.5; sc5[3 * MB_INST + 6] = 1.0; sc5[3 * MB_INST + 7] = -32.0;
          sc5[3 * MB_INST + 11] = 0.0; sc5[3 * MB_INST + 12] = p; sc5[3 * MB_INST + 13] = 9.0 * p;
          sc5[3 * MB_INST + 15] = p; sc5[3 * MB_INST + 21] = 9.0 * p; sc5[3 * MB_INST + 22] = 0.0; sc5[3 * MB_INST + 23] = 0.0;
          ninst = 4;
        }
        glass_forget();
        gl_present(sc5, ninst, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *px5 = pixels_of_fb(vfb);
        if (pi == 0) {
          px_rest = px5;
          areas[0] = 0;
        } else {
          int cnt = 0;
          for (int py = 21 * 3; py <= 59 * 3; py += 2) {
            for (int px_i = 53 * 3; px_i <= 112 * 3; px_i += 2) {
              unsigned char *c0 = V_PX(px5, px_i, py);
              unsigned char *r0 = V_PX(px_rest, px_i, py);
              int d = abs((int)c0[0] - (int)r0[0]) + abs((int)c0[1] - (int)r0[1]) + abs((int)c0[2] - (int)r0[2]);
              if (d >= 30) cnt++;
            }
          }
          areas[pi] = cnt;
          free(px5);
        }
      }
      free(px_rest);
      printf("gles_render: v9_switch_5press_delta_area=(%d,%d,%d,%d,%d)\n", areas[0], areas[1], areas[2], areas[3], areas[4]);
      CHECK(areas[0] < areas[1] && areas[1] < areas[2] && areas[2] < areas[3] && areas[3] < areas[4]);
    }

    // --- V9f: Role 4 Tab icon bevel gate (FIXED refract=9.0, Role 4 -64; icon at x_right-6.7pt vs empty; |y-cy|=0.42*h diff==0) ---
    {
      double tb[4 * MB_INST];
      V_RECT(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(tb + MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -563);
      tb[MB_INST + 4] = 22.5; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = -64.0;
      tb[MB_INST + 11] = 0.0; tb[MB_INST + 12] = 1.0; tb[MB_INST + 13] = 9.0;
      tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 9.0; tb[MB_INST + 22] = 0.0; tb[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px_empty = pixels_of_fb(vfb);
      // Place bright orange icons strictly inside: (1) right cap mid-band at x_right-6.7 = 128.3 (only p+barCaDisp hits it),
      // (2) bottom outer-band at (117.0, 56.0) where |y-cy|=0.42*h has barIconGate == 0.
      V_RECT(tb + MB_INST, 127.3, 35.0, 2.0, 10.0, 0, 1.0, 0.55, 0.0, 0);
      V_RECT(tb + 2 * MB_INST, 117.0, 56.0, 2.0, 6.0, 0, 1.0, 0.55, 0.0, 0);
      V_RECT(tb + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -564);
      tb[3 * MB_INST + 4] = 22.5; tb[3 * MB_INST + 6] = 1.0; tb[3 * MB_INST + 7] = -64.0;
      tb[3 * MB_INST + 11] = 0.0; tb[3 * MB_INST + 12] = 1.0; tb[3 * MB_INST + 13] = 9.0;
      tb[3 * MB_INST + 15] = 1.0; tb[3 * MB_INST + 21] = 9.0; tb[3 * MB_INST + 22] = 0.0; tb[3 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tb, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px_icon = pixels_of_fb(vfb);
      unsigned char *a_mid = V_PX(px_empty, 400, 120);
      unsigned char *b_mid = V_PX(px_icon, 400, 120);
      int mid_delta = abs((int)b_mid[0] - (int)a_mid[0]) + abs((int)b_mid[1] - (int)a_mid[1]);
      // Control at |y - cy| = 0.42 * 45 = 18.9 -> y = 58.9, x = 123.2 (inward = 1.5pt, barIconGate == 0)
      unsigned char *a_out = V_PX(px_empty, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      unsigned char *b_out = V_PX(px_icon, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
      int out_diff = 0;
      for (int ch = 0; ch < 3; ch++) {
        int df = abs((int)b_out[ch] - (int)a_out[ch]);
        if (df > out_diff) out_diff = df;
      }
      printf("gles_render: v9_tab_icon_bevel mid_delta=%d out_diff=%d\n", mid_delta, out_diff);
      CHECK(mid_delta >= 40 && out_diff == 0);
      free(px_empty);
      free(px_icon);
    }

    // --- V9g: Role 4 Tab bevelGate outer falloff regression (no un-refracted ghost at inward=10pt) ---
    {
      double tg[3 * MB_INST];
      V_RECT(tg, 0, 0, VW, VH, 0, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 0);
      V_RECT(tg + MB_INST, 41.5, 8.0, 2.0, 64.0, 0, 90.0 / 255.0, 90.0 / 255.0, 90.0 / 255.0, 0);
      V_RECT(tg + 2 * MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, -565);
      tg[2 * MB_INST + 4] = 31.75; tg[2 * MB_INST + 6] = 1.0; tg[2 * MB_INST + 7] = -64.0;
      tg[2 * MB_INST + 11] = 0.0; tg[2 * MB_INST + 12] = 1.0; tg[2 * MB_INST + 13] = 9.0;
      tg[2 * MB_INST + 15] = 1.0; tg[2 * MB_INST + 21] = 9.0; tg[2 * MB_INST + 22] = 0.0; tg[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(tg, 3, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
      unsigned char *pxg = pixels_of_fb(vfb);
      unsigned char *co = V_PX(pxg, 127, 120);
      double l_orig = 0.2126 * co[0] + 0.7152 * co[1] + 0.0722 * co[2];
      double min_l = 1e9;
      for (int px_i = 132; px_i <= 136; px_i++) {
        unsigned char *cr = V_PX(pxg, px_i, 120);
        double lr = 0.2126 * cr[0] + 0.7152 * cr[1] + 0.0722 * cr[2];
        if (lr < min_l) min_l = lr;
      }
      printf("gles_render: v9_tab_no_ghost orig_L=%.1f refr_min_L=%.1f\n", l_orig, min_l);
      CHECK(l_orig > 220.0 && min_l < 170.0);
      free(pxg);
    }

    // --- V9a2: Switch ON @ 2x phase-shifted integrated green mass ---
    V_SETUP(2);
    for (int ph = 0; ph < 2; ph++) {
      double yoff = ph * 0.25;
      double sw[3 * MB_INST];
      V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(sw + MB_INST, 40, 26 + yoff, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
      sw[MB_INST + 4] = 14.0;
      V_RECT(sw + 2 * MB_INST, 52.9, 21.0 + yoff, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -57 - ph);
      sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
      sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
      sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      int gsum = 0;
      for (int dy = 0; dy < 3; dy++) {
        unsigned char *c = V_PX(px, 80 * 2, 21 * 2 + dy);
        int d = (int)c[1] - (int)c[0];
        if (d > 0) gsum += d;
      }
      printf("gles_render: v9_switch_on_2x phase=%d green_mass=%d\n", ph, gsum);
      CHECK(gsum > 40);
      free(px);
    }

    // --- V10: Regular Glass Light Parabolic AA (@2x, R=24pt) ---
    {
      V_SETUP(2);
      double rg[2 * MB_INST];
      V_RECT(rg, 0, 0, VW, VH, 0, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 0);
      V_RECT(rg + MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -70);
      rg[MB_INST + 4] = 24.0; rg[MB_INST + 6] = 1.0; rg[MB_INST + 7] = 0.0;
      rg[MB_INST + 11] = 0.40; rg[MB_INST + 12] = 0.6; rg[MB_INST + 13] = 14.0;
      rg[MB_INST + 15] = 1.0; rg[MB_INST + 21] = 20.0; rg[MB_INST + 22] = 0.0; rg[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(rg, 2, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0);
      unsigned char *px = pixels_of_fb(vfb);
      double mins[64];
      int n = 0;
      for (int py = 20 + 4; py <= 20 + 44; py++) {
        double rm = 1e9;
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          unsigned char *c = V_PX(px, xpx, py);
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
        unsigned char *c = V_PX(px, xpx, 40 * 2);
        double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
        if (L < side_lmin) side_lmin = L;
      }
      printf("gles_render: v10_reg_light_2x max_d2=%.2f side_lmin=%.2f\n", max_d2, side_lmin);
      CHECK(max_d2 <= 14.0);
      CHECK(side_lmin >= 212.0 && side_lmin <= 232.0);
      free(px);
      double rgd[2 * MB_INST];
      V_RECT(rgd, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
      V_RECT(rgd + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -71);
      rgd[MB_INST + 4] = 24.0; rgd[MB_INST + 6] = 1.0; rgd[MB_INST + 7] = 0.0;
      rgd[MB_INST + 11] = 0x67 / 255.0; rgd[MB_INST + 12] = 0.6; rgd[MB_INST + 13] = 14.0;
      rgd[MB_INST + 15] = 1.0; rgd[MB_INST + 21] = 20.0; rgd[MB_INST + 22] = 0.0; rgd[MB_INST + 23] = 0.0;
      glass_forget();
      gl_present(rgd, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
      unsigned char *pxd = pixels_of_fb(vfb);
      unsigned char *dc_mid = V_PX(pxd, 80 * 2, 40 * 2);
      unsigned char *dc_top = V_PX(pxd, 80 * 2, 10 * 2 + 1);
      unsigned char *dc_side = V_PX(pxd, 140 * 2 - 1, 40 * 2);
      double l_mid = 0.2126 * dc_mid[0] + 0.7152 * dc_mid[1] + 0.0722 * dc_mid[2];
      double l_top = 0.2126 * dc_top[0] + 0.7152 * dc_top[1] + 0.0722 * dc_top[2];
      double l_side = 0.2126 * dc_side[0] + 0.7152 * dc_side[1] + 0.0722 * dc_side[2];
      printf("gles_render: v10_reg_dark_2x top=%.1f mid=%.1f side=%.1f", l_top, l_mid, l_side);
      // Full Dark Regular corner ROI (top column + straight side + 45-deg corner arc RGBA8) FNV-1a hash
      uint64_t dh = 14695981039346656037ULL;
      for (int py = 10 * 2; py <= 10 * 2 + 8; py++) {
        unsigned char *c = V_PX(pxd, 80 * 2, py);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 1; xpx++) {
        unsigned char *c = V_PX(pxd, xpx, 40 * 2);
        for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
      }
      for (int py = 10 * 2; py <= 10 * 2 + 48; py++) {
        for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
          unsigned char *c = V_PX(pxd, xpx, py);
          for (int ch = 0; ch < 4; ch++) { dh ^= c[ch]; dh *= 1099511628211ULL; }
        }
      }
      printf(" roi_fnv1a=0x%016llx\n", (unsigned long long)dh);
      CHECK(dh == 0x80e02702612bc2bbULL);
      CHECK(l_top > l_mid + 5.0);
      CHECK(l_side >= l_mid - 6.0 && l_side <= l_mid + 20.0);
      free(pxd);
    }

    // --- V11-AA & V11-Wall: Switch ON (Dark & Light, 3x & 2x, shadow-free) ---
    for (int is_light = 0; is_light <= 1; is_light++) {
      double bg = is_light ? 1.0 : 28.0 / 255.0;
      double bg_b = is_light ? 1.0 : 30.0 / 255.0;
      double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
      double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
      double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
      for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
        int sc = (sc_idx == 0) ? 3 : 2;
        V_SETUP(sc);
        double sw[3 * MB_INST];
        V_RECT(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
        V_RECT(sw + MB_INST, 18.5, 18.0, 63.0, 28.0, 0, tr_r, tr_g, tr_b, 0);
        sw[MB_INST + 4] = 14.0;
        sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
        V_RECT(sw + 2 * MB_INST, 31.58, 12.8, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -72 - is_light * 2 - sc_idx);
        sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
        sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
        sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
        glass_forget();
        gl_present(sw, 3, bg, bg, bg_b);
        unsigned char *px = pixels_of_fb(vfb);
        int y_lo = (int)ceil((32.0 - 0.52 * 19.2) * sc - 0.5);
        int y_hi = (int)floor((32.0 + 0.52 * 19.2) * sc - 0.5);
        int xl0 = (sc == 3) ? 89 : 58, xl1 = (sc == 3) ? 109 : 74;
        int xr0 = (sc == 3) ? 259 : 170, xr1 = (sc == 3) ? 281 : 188;
        double minL[128], minR[128];
        int n = 0;
        for (int py = y_lo; py <= y_hi; py++) {
          double ml = 1e9, mr = 1e9;
          for (int xpx = xl0; xpx <= xl1; xpx++) {
            unsigned char *c = V_PX(px, xpx, py);
            double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            if (L < ml) ml = L;
          }
          for (int xpx = xr0; xpx <= xr1; xpx++) {
            unsigned char *c = V_PX(px, xpx, py);
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
        printf("gles_render: v11_aa(%s %dx [%d..%d]) L=%.2f R=%.2f (lim=%.1f)\n",
               is_light ? "light" : "dark", sc, y_lo, y_hi, d2L, d2R, lim);
        CHECK(d2L <= lim && d2R <= lim);
        if (sc == 3) {
          int cy_px = 32 * 3;
          int rx_min = 271;
          double r_minL = 1e9;
          for (int xpx = 268; xpx <= 272; xpx++) {
            unsigned char *c = V_PX(px, xpx, cy_px);
            double L = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            if (L < r_minL) { r_minL = L; rx_min = xpx; }
          }
          unsigned char *rc0 = V_PX(px, rx_min, cy_px);
          int r_gr = (int)rc0[1] - (int)rc0[0];
          double l1, l2, l3, l4;
          {
            unsigned char *c1 = V_PX(px, rx_min - 1, cy_px);
            unsigned char *c2 = V_PX(px, rx_min - 2, cy_px);
            unsigned char *c3 = V_PX(px, rx_min - 3, cy_px);
            unsigned char *c4 = V_PX(px, rx_min - 4, cy_px);
            l1 = 0.2126 * c1[0] + 0.7152 * c1[1] + 0.0722 * c1[2];
            l2 = 0.2126 * c2[0] + 0.7152 * c2[1] + 0.0722 * c2[2];
            l3 = 0.2126 * c3[0] + 0.7152 * c3[1] + 0.0722 * c3[2];
            l4 = 0.2126 * c4[0] + 0.7152 * c4[1] + 0.0722 * c4[2];
          }
          int r_mono = (l1 >= r_minL && l2 >= l1 && l3 >= l2 && l4 >= l3);
          int best_gr = -999, best_g = 0;
          for (int xpx = 94; xpx <= 98; xpx++) {
            unsigned char *c = V_PX(px, xpx, cy_px);
            int gr = (int)c[1] - (int)c[0];
            if (gr > best_gr && c[1] >= 125 && c[1] <= 165) { best_gr = gr; best_g = c[1]; }
          }
          printf("gles_render: v11_wall(%s 3x) r_minL=%.1f@x=%d r_gr=%d wall=(%.1f,%.1f,%.1f,%.1f) r_mono=%d l_emerald=(G=%d,G-R=%d)\n",
                 is_light ? "light" : "dark", r_minL, rx_min, r_gr, l1, l2, l3, l4, r_mono, best_g, best_gr);
          if (!is_light) {
            CHECK(r_minL <= 14.0 && r_gr <= 12 && r_mono);
          } else {
            CHECK(r_minL >= 170.0 && r_minL <= 205.0 && r_mono && l4 >= 230.0);
          }
          CHECK(best_gr >= 90 && best_g >= 125 && best_g <= 165);
          {
            double prev_moat = -1.0;
            printf("gles_render: v9_left_horn_3x(%s)", is_light ? "light" : "dark");
            for (int dx = 6; dx <= 20; dx += 2) {
              int pc = (int)lround((31.58 + dx) * 3.0);
              double dyc = sqrt(fmax(19.2 * 19.2 - fmax(19.2 - dx, 0.0) * fmax(19.2 - dx, 0.0), 0.0));
              int y0 = (int)lround((32.0 - dyc + 1.0) * 3.0);
              int y1 = (int)lround(32.0 * 3.0);
              int best = 0, cur = 0;
              for (int py = y0; py < y1; py++) {
                unsigned char *c = V_PX(px, pc, py);
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

    // --- V11-Top: Registered 3x & 2x top-wall at 5.00pt & 5.20pt (Dark & Light) ---
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
            V_SETUP(sc);
            double sw[3 * MB_INST];
            V_RECT(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
            V_RECT(sw + MB_INST, 40.0, 21.0 + off, 63.0, th, 0, tr_r, tr_g, tr_b, 0);
            sw[MB_INST + 4] = th * 0.5;
            sw[MB_INST + 36] = th * 0.5; sw[MB_INST + 37] = th * 0.5; sw[MB_INST + 38] = th * 0.5; sw[MB_INST + 39] = th * 0.5;
            V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -80 - is_light * 4 - oi * 2 - sc_idx);
            sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
            sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
            sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
            glass_forget();
            gl_present(sw, 3, bg, bg, bg_b);
            unsigned char *px = pixels_of_fb(vfb);
            unsigned char *r0 = V_PX(px, 80 * sc, 21 * sc + 0);
            unsigned char *r1 = V_PX(px, 80 * sc, 21 * sc + 1);
            unsigned char *r2 = V_PX(px, 80 * sc, 21 * sc + 2);
            int gr0 = (int)r0[1] - (int)r0[0], gr1 = (int)r1[1] - (int)r1[0], gr2 = (int)r2[1] - (int)r2[0];
            double l0 = 0.2126 * r0[0] + 0.7152 * r0[1] + 0.0722 * r0[2];
            double l2 = 0.2126 * r2[0] + 0.7152 * r2[1] + 0.0722 * r2[2];
            printf("gles_render: v11_top(%s %dx @%.2fpt) r0=(G-R=%d,L=%.0f) r1=(G-R=%d) r2=(G-R=%d,L=%.0f)\n",
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

    // --- V9h: Switch ON held glassFrost C0 continuity (0 -> eps, 0.108->0.110 veil, 0.127->0.129 blur, 0.60 frosted) ---
    {
      static const double frosts[8] = { 0.0, 0.0001, 0.00011, 0.108, 0.110, 0.127, 0.129, 0.60 };
      V_SETUP(3);
      unsigned char *px0 = NULL, *px_prev = NULL;
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
        V_RECT(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
        V_RECT(sw + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
        sw[MB_INST + 4] = 14.0;
        sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
        V_RECT(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -90 - fi);
        sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = slot7;
        sw[2 * MB_INST + 11] = alpha; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
        sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = refr;
        glass_forget();
        gl_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
        unsigned char *px = pixels_of_fb(vfb);
        if (fi == 0) {
          px0 = px;
          unsigned char *c = V_PX(px, 82 * 3, 40 * 3);
          c0_r = c[0]; c0_g = c[1];
        } else {
          if (fi == 2) {
            for (int py = 21 * 3; py <= 59 * 3; py++) {
              for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
                unsigned char *a = V_PX(px0, xpx, py);
                unsigned char *b = V_PX(px, xpx, py);
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
          } else if (fi == 4 || fi == 6) {
            int md = 0;
            for (int py = 21 * 3; py <= 59 * 3; py++) {
              for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
                unsigned char *a = V_PX(px_prev, xpx, py);
                unsigned char *b = V_PX(px, xpx, py);
                for (int ch = 0; ch < 3; ch++) {
                  int d = abs((int)a[ch] - (int)b[ch]);
                  if (d > md) md = d;
                }
              }
            }
            if (fi == 4) max_d_veil = md; else max_d_blur = md;
          } else if (fi == 7) {
            unsigned char *c = V_PX(px, 82 * 3, 40 * 3);
            c60_r = c[0]; c60_g = c[1];
          }
          free(px);
        }
      }
      free(px0);
      free(px_prev);
      printf("gles_render: v9_switch_frost_continuity max_d_eps=%d max_d_veil=%d max_d_blur=%d ctr0=(%d,%d) ctr60=(%d,%d)\n",
             max_d_eps, max_d_veil, max_d_blur, c0_r, c0_g, c60_r, c60_g);
      CHECK(max_d_eps <= 2);
      CHECK(max_d_veil <= 10);
      CHECK(max_d_blur <= 10);
      CHECK(c60_r > c0_r + 25 && (c60_g - c60_r) < (c0_g - c0_r) - 20);
    }

    #undef V_RECT
    #undef V_SETUP
    #undef V_PX
    surface = saved_surface;
    target_fb = saved_target;
    glBindFramebuffer(GL_FRAMEBUFFER, surface);
    glDeleteFramebuffers(1, &vfb);
    glDeleteTextures(1, &vtex);
    fb_w = saved_fb_w; fb_h = saved_fb_h; cur_w = saved_w; cur_h = saved_h; cur_scale = saved_s;
  }

  if (!failed) printf("gles_render: ok\n");
  return failed;
}
