// The OpenGL ES 3 renderer of the hosts that draw with it, Android's (android_host.c) and Linux's (linux_render.c):
// the same instances and shader as Metal and WebGL2 (a program of it for each kind it draws most: use_prog), glass's
// passes, the frame presented last kept to be drawn again, its pixels read back. Included once, by the file that has
// GLES 3's functions declared (Android's <GLES3/gl3.h>, Linux's epoxy) and, before it:
//   LOG(...)                          a line of the host's log, printf's way
//   static GLuint image_tex(int id);  the texture an instance's image (slot 20) is drawn from; 0: none (yet)
//   static void view_parts_in(int tid, int32_t start, int32_t end);  a native view's picture's run (draw_kept below)
//   MB_VIEW_TEX                       the first of a native view picture's image ids (src/hostapi/host.mbt)
//   MB_VIEWS_UNDER (optional)         the host keeps its native views under the surface (Linux's pages), not drawn in it
//                                     (Android's; Linux's players): a view's run for which the host's
//                                     static int view_under(int tid) is true takes the canvas away where it shows
//                                     (draw_kept below)
//   MB_HOST_THREADS (optional)        the app runs on another thread than draws (Android's): the host defines
//                                     mb_host_render_dirty (what a frame says differs goes with the frame, handed to
//                                     gl_dirty_add as it is drawn), mb_render_drawn_pixels and mb_render_pixels_of
//                                     (done on the drawing thread: gles_drawn_pixels, gles_pixels_of) itself
// What is drawn where is the host's to say: the frame's size in points and its scale (cur_w, cur_h, cur_scale), the
// surface's in pixels (fb_w, fb_h), the framebuffer drawn into (target_fb); gl_setup once its context is current.
#define MB_GLES_RENDER 1  // (frame_mail.h, included after it, keeps its frames in it: fm_keep)
#include <pthread.h>
#include <stdint.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "contained.h"
#include "bands.h"
// the groups of instances the host keeps, drawn out as gl_present takes a frame
#include "groups.h"

// the numbers of an instance (src/ui/scene.mbt)
#define MB_INST 60
#include "glass_damage.h"
// the glyphs' atlases, square, what goes where in them MoonBit's (hostapi's atlas.mbt): the words' (a byte a texel,
// how much of it the glyph covers: drawn in the text's colour; as many bytes as one RGBA atlas half as wide) and colour
// glyphs' (RGBA: an emoji's own). A colour glyph's place across is MB_ATLAS_COLOR_U past its place in its atlas (what
// MoonBit says of it, @hostapi.colour_atlas_u): the shader takes the atlas by it, as Apple's does.
#define MB_ATLAS 4096
#define MB_ATLAS_COLOR 1024
#define MB_ATLAS_COLOR_U 16384

static const char *VS =
    "#version 300 es\n"
    "layout(location=0) in vec4 a_rect;\n"
    "layout(location=1) in vec4 a_p;\n"
    "layout(location=2) in vec4 a_color;\n"
    "layout(location=3) in vec4 a_c2;\n"
    "layout(location=4) in vec4 a_clip;\n"
    "layout(location=5) in vec4 a_pad;\n"
    "layout(location=6) in vec4 a_rc;\n"
    "layout(location=7) in vec4 a_rs;\n"
    "layout(location=8) in vec4 a_rot;\n"
    "layout(location=9) in vec4 a_rr;\n"
    "layout(location=10) in vec4 a_oclip;\n"
    "layout(location=11) in vec4 a_orc;\n"
    "layout(location=12) in vec4 a_ors;\n"
    "layout(location=13) in vec4 a_fade;\n"
    "layout(location=14) in vec4 a_fadex;\n"
    "uniform vec2 u_vp;\n"
    "uniform vec2 u_origin;\n"
    "uniform vec4 u_gb;\n"
    "#if MB_VS_ADAPTIVE\n"
    "uniform highp sampler2D u_bd;\n"
    "uniform vec4 u_map;\n"
    "uniform vec4 u_uvc;\n"
    "uniform highp sampler2D u_ad;\n"
    "uniform vec4 u_ad_box[16];\n"
    "uniform int u_ad_n;\n"
    "vec3 vs_backdrop(vec2 p) {\n"
    "  return textureLod(u_bd, clamp(p * u_map.xy + u_map.zw, u_uvc.xy, u_uvc.zw), 0.0).rgb;\n"
    "}\n"
    "float vs_luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    "float vs_ink_luma(vec3 c) { return dot(c * c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    "float vs_backdrop_luma_rect(vec2 c, vec2 h) {\n"
    "  float sum = 0.0;\n"
    "  float mx1 = -1.0, mx2 = -1.0;\n"
    "  float mn1 = 2.0, mn2 = 2.0;\n"
    "  for (int iy = -1; iy <= 1; iy++) {\n"
    "    float py = c.y + float(iy) * (h.y * 0.60);\n"
    "    for (int ix = -2; ix <= 2; ix++) {\n"
    "      float px = c.x + float(ix) * (h.x * 0.38);\n"
    "      float y = vs_ink_luma(vs_backdrop(vec2(px, py)));\n"
    "      sum += y;\n"
    "      if (y > mx1) { mx2 = mx1; mx1 = y; } else if (y > mx2) { mx2 = y; }\n"
    "      if (y < mn1) { mn2 = mn1; mn1 = y; } else if (y < mn2) { mn2 = y; }\n"
    "    }\n"
    "  }\n"
    "  return (sum - mx1 - mx2 - mn1 - mn2) / 11.0;\n"
    "}\n"
    "float vs_unpack16(vec2 rg) {\n"
    "  float hi = floor(clamp(rg.x, 0.0, 1.0) * 255.0 + 0.5);\n"
    "  float lo = floor(clamp(rg.y, 0.0, 1.0) * 255.0 + 0.5);\n"
    "  return (hi * 256.0 + lo) / 65535.0;\n"
    "}\n"
    "vec2 vs_ad_sample_ink(vec2 ac, float fallback_r, out vec2 capCenter, out vec2 capHalf) {\n"
    "  if (u_ad_n > 0) {\n"
    "    int best = -1;\n"
    "    float best_d = 1e9;\n"
    "    for (int i = 0; i < 16; i++) {\n"
    "      if (i >= u_ad_n) break;\n"
    "      float d = length(ac - u_ad_box[i].xy);\n"
    "      if (d <= 2.0 && d < best_d) { best = i; best_d = d; }\n"
    "    }\n"
    "    if (best < 0) {\n"
    "      best_d = 1e9;\n"
    "      for (int i = 0; i < 16; i++) {\n"
    "        if (i >= u_ad_n) break;\n"
    "        vec2 diff = abs(ac - u_ad_box[i].xy);\n"
    "        if (diff.x <= u_ad_box[i].z + 2.0 && diff.y <= u_ad_box[i].w + 2.0) {\n"
    "          float d = length(diff);\n"
    "          if (d < best_d) { best = i; best_d = d; }\n"
    "        }\n"
    "      }\n"
    "    }\n"
    "    if (best >= 0) {\n"
    "      vec4 px = texelFetch(u_ad, ivec2(best, 0), 0);\n"
    "      capCenter = u_ad_box[best].xy;\n"
    "      capHalf = u_ad_box[best].zw;\n"
    "      return vec2(vs_unpack16(px.rg), px.a);\n"
    "    }\n"
    "  }\n"
    "  capCenter = ac;\n"
    "  capHalf = vec2(0.0);\n"
    "  float bgL = vs_backdrop_luma_rect(ac, vec2(max(fallback_r, 1.0)));\n"
    "  return vec2(1.0 - smoothstep(0.30, 0.42, bgL), bgL);\n"
    "}\n"
    "float vs_srgb_to_lin(float c) {\n"
    "  return c <= 0.04045 ? (c / 12.92) : pow(max((c + 0.055) / 1.055, 0.0), 2.4);\n"
    "}\n"
    "float vs_lin_to_srgb(float y) {\n"
    "  y = clamp(y, 0.0, 1.0);\n"
    "  return y <= 0.0031308 ? (12.92 * y) : (1.055 * pow(max(y, 0.0), 1.0 / 2.4) - 0.055);\n"
    "}\n"
    "vec3 vs_bare_adaptive_ink_at(vec3 rgb, vec2 ac, float hr) {\n"
    "  float ch = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);\n"
    "  if (ch > 0.08) return rgb;\n"
    "  float origL = vs_luma(rgb);\n"
    "  float bgL = vs_backdrop_luma_rect(ac, vec2(max(hr, 1.0)));\n"
    "  float c_bg = sqrt(max(bgL, 0.0));\n"
    "  float Lbg = vs_srgb_to_lin(c_bg);\n"
    "  float target = 4.65;\n"
    "  float out_c;\n"
    "  if (Lbg >= 0.1792) {\n"
    "    float pref = origL < 0.5 ? origL : clamp(1.0 - origL, 0.02, 0.45);\n"
    "    float y_pref = vs_srgb_to_lin(pref);\n"
    "    float y_max = max(0.0, (Lbg + 0.05) / target - 0.05);\n"
    "    if (origL < 0.5 && y_pref <= y_max) return rgb;\n"
    "    out_c = vs_lin_to_srgb(min(y_pref, y_max));\n"
    "  } else {\n"
    "    float pref = origL >= 0.5 ? origL : clamp(1.06 - origL, 0.55, 0.98);\n"
    "    float y_pref = vs_srgb_to_lin(pref);\n"
    "    float y_min = min(1.0, target * (Lbg + 0.05) - 0.05);\n"
    "    if (origL >= 0.5 && y_pref >= y_min) return rgb;\n"
    "    out_c = vs_lin_to_srgb(max(y_pref, y_min));\n"
    "  }\n"
    "  return vec3(out_c);\n"
    "}\n"
    "vec3 vs_adaptive_ink_at(vec3 rgb, vec2 ac, float fallback_r, vec4 rect, vec2 sample_off, bool is_icon) {\n"
    "  float ch = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);\n"
    "  float origL = vs_luma(rgb);\n"
    "  if (ch > 0.08 || origL >= 0.5) return rgb;\n"
    "  vec2 capCenter, capHalf;\n"
    "  vec2 cap = vs_ad_sample_ink(ac, fallback_r, capCenter, capHalf);\n"
    "  float capsuleDarkT = cap.x;\n"
    "  float capsuleBgL = cap.y;\n"
    "  float darkT = capsuleDarkT;\n"
    "  float localBoost = 0.0;\n"
    "  bool is_large = (capHalf.x >= 140.0 && capHalf.y >= 19.0);\n"
    "  if (is_large && capsuleDarkT < 0.999) {\n"
    "    vec2 samplePos = rect.xy + rect.zw * 0.5 + sample_off;\n"
    "    if (capHalf.y <= 28.0) samplePos.y = capCenter.y;\n"
    "    vec2 guv = samplePos * u_map.xy + u_map.zw;\n"
    "    if (u_uvc.z > u_uvc.x && u_uvc.w > u_uvc.y && guv.x >= u_uvc.x && guv.x <= u_uvc.z && guv.y >= u_uvc.y && guv.y <= u_uvc.w) {\n"
    "      vec2 sampleH;\n"
    "      if (is_icon) {\n"
    "        sampleH = vec2(10.0, 8.0);\n"
    "      } else {\n"
    "        float edgeDist = min(samplePos.x - (capCenter.x - capHalf.x + 8.0), (capCenter.x + capHalf.x - 8.0) - samplePos.x);\n"
    "        float rx = clamp(edgeDist / 0.76, 10.0, 20.0);\n"
    "        float ry = clamp(capHalf.y * 0.55, 8.0, 14.0);\n"
    "        sampleH = vec2(rx, ry);\n"
    "      }\n"
    "      float localL = vs_backdrop_luma_rect(samplePos, sampleH);\n"
    "      float localDarkT = 1.0 - smoothstep(0.22, 0.28, localL);\n"
    "      float localW = max(smoothstep(0.35, 0.44, capsuleBgL), smoothstep(0.08, 0.20, capsuleBgL - localL));\n"
    "      float localEff = localDarkT * localW;\n"
    "      if (localEff > darkT) {\n"
    "        localBoost = clamp(localEff - capsuleDarkT, 0.0, 1.0);\n"
    "        darkT = localEff;\n"
    "      }\n"
    "    }\n"
    "  }\n"
    "  float inkT = smoothstep(0.0, 1.0, darkT);\n"
    "  float baseLightL = clamp(1.06 - origL, 0.68, 0.98);\n"
    "  float localLightL = clamp(1.14 - origL * 0.60, 0.86, 0.99);\n"
    "  float lightL = mix(baseLightL, localLightL, localBoost);\n"
    "  return mix(rgb, vec3(lightL), inkT);\n"
    "}\n"
    "#endif\n"
    "out vec2 v_pos; out vec2 v_cpos;\n"
    "flat out vec4 v_rect; flat out vec4 v_p; flat out vec4 v_color; flat out vec4 v_c2; flat out vec4 v_clip; flat out vec4 v_pad;\n"
    "flat out vec4 v_rc; flat out vec4 v_rs; flat out vec4 v_rr; flat out vec4 v_oclip; flat out vec4 v_orc; flat out vec4 v_ors;\n"
    "// how far each pixel is into its fades (scene.mbt 52-59: from its left, top, right, foot; 1 and past: whole), worked\n"
    "// out where it is drawn at its corners and taken across it as it goes straight\n"
    "out vec4 v_ramp;\n"
    "void main() {\n"
    "  int vid = gl_VertexID;\n"
    "  vec2 corner = vec2((vid == 1 || vid == 4 || vid == 5) ? 1.0 : 0.0, (vid == 2 || vid == 3 || vid == 5) ? 1.0 : 0.0);\n"
    "  int kind = int(a_p.y + 0.5);\n"
    "  bool merged_liquid = kind == 6 && a_pad.w > 0.0;\n"
    "  float grow = kind == 2 ? a_p.w * 3.0 + 2.0 : (kind == 6 && a_pad.w <= 0.0) ? 2.0 : ((kind == 0 || kind == 4 || kind == 5 || kind == 8) ? 1.0 : 0.0);\n"
    "  vec2 pos = a_rect.xy - grow + corner * (a_rect.zw + 2.0 * grow);\n"
    "  if (merged_liquid) pos = mix(u_gb.xy, u_gb.zw, corner);\n"
    "  // the pieces of shapes (kind 12): nothing drawn\n"
    "  if (kind == 12) pos = vec2(0.0);\n"
    "  // turned (scene.mbt 32-35): drawn turned about its point, everything of how in its own place (v_pos), its clip\n"
    "  // there too or (35: one from outside what turned) where it is drawn (v_cpos)\n"
    "  vec2 at = pos;\n"
    "  if (a_rot.x != 0.0) { vec2 d = pos - a_rot.yz; float c = cos(a_rot.x), s = sin(a_rot.x); at = a_rot.yz + vec2(c * d.x - s * d.y, s * d.x + c * d.y); }\n"
    "  vec2 rel = at - u_origin;\n"
    "  gl_Position = vec4(rel.x / u_vp.x * 2.0 - 1.0, 1.0 - rel.y / u_vp.y * 2.0, 0.0, 1.0);\n"
    "  v_pos = pos; v_cpos = a_rot.w > 0.5 ? at : pos; v_rect = a_rect; v_p = a_p; v_color = a_color; v_c2 = a_c2; v_clip = a_clip; v_pad = a_pad; v_rc = a_rc; v_rs = a_rs; v_rr = a_rr;\n"
    "#if MB_VS_ADAPTIVE\n"
    "  if (kind == 7) {\n"
    "    v_color.rgb = a_pad.w < 0.0\n"
    "      ? vs_bare_adaptive_ink_at(a_color.rgb, a_pad.yz, -a_pad.w * 0.5)\n"
    "      : vs_adaptive_ink_at(a_color.rgb, a_pad.yz, a_pad.w * 0.5, a_rect, a_p.zw, false);\n"
    "  } else if ((kind == 10 || kind == 11) && a_pad.w > 0.0) {\n"
    "    v_color.rgb = vs_adaptive_ink_at(a_color.rgb, a_pad.yz, a_pad.w * 0.5, a_rect, kind == 10 ? vec2(0.0) : a_p.zw, true);\n"
    "  } else if (kind == 0 && a_pad.w < 0.0) {\n"
    "    float ch = max(max(a_color.r, a_color.g), a_color.b) - min(min(a_color.r, a_color.g), a_color.b);\n"
    "    vec2 capCenter, capHalf;\n"
    "    float darkT = vs_ad_sample_ink(a_pad.yz, -a_pad.w * 0.5, capCenter, capHalf).x;\n"
    "    if (ch <= 0.08 && vs_luma(a_color.rgb) < 0.5) {\n"
    "      v_color.rgb = mix(a_color.rgb, vec3(1.0), darkT);\n"
    "      v_color.a = mix(a_color.a, min(a_color.a * 1.45, 0.28), darkT);\n"
    "    } else if (ch > 0.08 && vs_luma(a_color.rgb) < 0.35) {\n"
    "      v_color.rgb = mix(a_color.rgb, min(a_color.rgb * 1.65 + vec3(0.28, 0.20, 0.18), vec3(1.0)), darkT);\n"
    "      v_color.a = mix(a_color.a, min(a_color.a * 1.45, 0.36), darkT);\n"
    "    }\n"
    "  }\n"
    "#endif\n"
    "  if (kind == 4 && a_pad.z > 0.5) v_pad.x = a_rot.w;\n"
    "  // (a glyph's p.x, which it has no use for: how it is turned, for its texels taken whole where it is not)\n"
    "  if (kind == 1 || kind == 3 || kind == 7) v_p.x = a_rot.x;\n"
    "  v_oclip = a_oclip; v_orc = a_orc; v_ors = a_ors;\n"
    "  vec2 cq = a_rot.w > 0.5 ? at : pos;\n"
    "  v_ramp = vec4(a_fadex.y > 0.0 ? (cq.x - a_fadex.x) / a_fadex.y : 2.0, a_fade.y > 0.0 ? (cq.y - a_fade.x) / a_fade.y : 2.0,\n"
    "    a_fadex.w > 0.0 ? (a_fadex.z - cq.x) / a_fadex.w : 2.0, a_fade.w > 0.0 ? (a_fade.z - cq.y) / a_fade.w : 2.0);\n"
    "}\n";

// (after its version, ONE_KIND: the kind of what the program draws, fixed (use_prog); -1 any, as the instance says)
static const char *FS =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp int;\n"
    "in vec2 v_pos; in vec2 v_cpos;\n"
    "flat in vec4 v_rect; flat in vec4 v_p; flat in vec4 v_color; flat in vec4 v_c2; flat in vec4 v_clip; flat in vec4 v_pad;\n"
    "flat in vec4 v_rc; flat in vec4 v_rs; flat in vec4 v_rr; flat in vec4 v_oclip; flat in vec4 v_orc; flat in vec4 v_ors;\n"
    "in vec4 v_ramp;\n"
    "uniform float u_scale;\n"
    "#if MB_HAS(1) || MB_HAS(3) || MB_HAS(7)\n"
    "uniform sampler2D u_atlas;\n"
    "uniform sampler2D u_catlas;\n"
    "#endif\n"
    "#if MB_HAS(4) || MB_HAS(9)\n"
    "uniform sampler2D u_img;\n"
    "#endif\n"
    "// glass (src/ui/glass.mbt): the blurred copy under it and where a point is in it (uv = p * u_map.xy + u_map.zw, kept\n"
    "// in u_uvc), a liquid group's shapes and corners, how many\n"
    "#if MB_HAS_BACKDROP\n"
    "uniform highp sampler2D u_bd;\n"
    "uniform vec4 u_map;\n"
    "uniform vec4 u_uvc;\n"
    "#endif\n"
    "// a liquid group's bounds (as the vertex shader has them)\n"
    "#if MB_HAS_GROUP\n"
    "uniform vec4 u_gb;\n"
    "uniform vec4 u_shape[8];\n"
    "uniform vec4 u_rad[8];\n"
    "uniform int u_n;\n"
    "#endif\n"
    "#if MB_HAS_LIQUID\n"
    "uniform vec2 u_glight;\n"
    "#endif\n"
    "#if MB_HAS_ADAPTIVE\n"
    "uniform highp sampler2D u_ad;\n"
    "uniform vec4 u_ad_box[16];\n"
    "uniform int u_ad_n;\n"
    "#endif\n"
    "// the pieces of the frame's shapes (src/ui/shape.mbt: the instances of kind 12 after every one drawn), 2040 fours\n"
    "// (136 instances) a row\n"
    "#if MB_HAS(11)\n"
    "uniform highp sampler2D u_segs;\n"
    "#endif\n"
    "out vec4 o;\n"
    "#define float2 vec2\n"
    "#define float4 vec4\n"
    MB_CORNER_SL
    "#if MB_HAS(5) || MB_HAS_LIQUID || MB_HAS(8)\n"
    "float sd_rr(vec2 p, vec4 r, vec4 rad) {\n"
    "  vec2 hs = r.zw * 0.5;\n"
    "  return mb_sd_box(p - r.xy - hs, hs, mb_corner_of(p - r.xy - hs, rad), 1e9);\n"
    "}\n"
    "#endif\n"
    "// a notch cut into the top edge (scene.mbt 21-23): a circle about the top's middle (pad.y below it, pad.z its radius),\n"
    "// met by the edge through fillets (pad.w): the rounded intersection with what is outside the circle\n"
    "#if MB_HAS(0) || MB_HAS(5)\n"
    "float notch_cut(float d, vec2 p, vec4 r, vec4 pad) {\n"
    "  if (pad.z <= 0.0) return d;\n"
    "  float b = pad.z - length(p - vec2(r.x + r.z * 0.5, r.y + pad.y));\n"
    "  float f = max(pad.w, 0.0);\n"
    "  vec2 u = max(vec2(f + d, f + b), 0.0);\n"
    "  return min(-f, max(d, b)) + length(u);\n"
    "}\n"
    "#endif\n"
    "#if MB_HAS_GROUP\n"
    "float smin_k(float a, float b, float k) {\n"
    "  if (k <= 0.0) return min(a, b);\n"
    "  float h = max(k - abs(a - b), 0.0) / k;\n"
    "  return min(a, b) - h * h * k * 0.25;\n"
    "}\n"
    "float sd_group(vec2 p, float k) {\n"
    "  float d = 1e9;\n"
    "  for (int i = 0; i < 8; i++) {\n"
    "    if (i >= u_n) break;\n"
    "    d = smin_k(d, sd_rr(p, u_shape[i], u_rad[i]), k);\n"
    "  }\n"
    "  return d;\n"
    "}\n"
    "#endif\n"
    "// Integral of linear ramp from 0 to w (contourOffset = 0, width w in device px)\n"
    "#if MB_HAS_LIQUID\n"
    "float mb_contour_int(float t, float w) {\n"
    "  float u = clamp(t, 0.0, w);\n"
    "  return u - u * u / (2.0 * w);\n"
    "}\n"
    "float mb_para_int(float t, float w) {\n"
    "  float u = clamp(t / max(w, 0.0001), 0.0, 1.0);\n"
    "  return w * (2.0 * u * u - (4.0 / 3.0) * u * u * u);\n"
    "}\n"
    "float mb_bevel_F(float t, float w0, float L) {\n"
    "  if (t <= w0) return t;\n"
    "  return w0 + L * (1.0 - exp(-(t - w0) / max(L, 0.0001)));\n"
    "}\n"
    "float mb_bevel_cov(float sd_px, float scale, float w0_pt, float L_pt) {\n"
    "  float invS = 1.0 / max(scale, 1.0);\n"
    "  float s0 = max(sd_px - 0.5, 0.0) * invS;\n"
    "  float s1 = max(sd_px + 0.5, 0.0) * invS;\n"
    "  if (s1 <= s0) return 0.0;\n"
    "  return max(scale * (mb_bevel_F(s1, w0_pt, L_pt) - mb_bevel_F(s0, w0_pt, L_pt)), 0.0);\n"
    "}\n"
    "float mb_snell_intersect(float s, float ior, float H_opt) {\n"
    "  float invLen = inversesqrt(1.0 + s * s);\n"
    "  float cosI = invLen;\n"
    "  float sinI = abs(s) * invLen;\n"
    "  float eta = 1.0 / ior;\n"
    "  float sinT = sinI * eta;\n"
    "  float cosT = sqrt(max(1.0 - sinT * sinT, 0.0001));\n"
    "  float k = eta * cosI - cosT;\n"
    "  float Tr = k * (s * invLen);\n"
    "  float Tz = -eta + k * invLen;\n"
    "  return H_opt * (Tr / max(-Tz, 0.0001));\n"
    "}\n"
    "vec2 mb_droplet_snell(float d, float rawAmount, float halfMinor, int role, float ior) {\n"
    "  float hs = clamp(halfMinor / 19.2, 0.72, 1.25);\n"
    "  float refScale = clamp(rawAmount / 9.0, 0.0, 2.0);\n"
    "  float medialTaper = 1.0 - smoothstep(0.68 * halfMinor, 0.96 * halfMinor, d);\n"
    "  float s_lip = 0.0;\n"
    "  float s_cap = 0.0;\n"
    "  float H_opt = 0.0;\n"
    "  if (role == 1) {\n"
    "    float r_lip = 5.0 * hs;\n"
    "    float L_lip = 1.15 * hs;\n"
    "    s_lip = 10.5 * exp(-d / L_lip) * (1.0 - smoothstep(0.55 * r_lip, r_lip, d)) * medialTaper;\n"
    "    H_opt = 9.4 * hs * refScale;\n"
    "  } else if (role == 2) {\n"
    "    float r_lip = 3.8 * hs;\n"
    "    float L_lip = 0.52 * hs;\n"
    "    s_lip = 6.3 * exp(-d / L_lip) * (1.0 - smoothstep(0.55 * r_lip, r_lip, d)) * medialTaper;\n"
    "    float u = max(d - 1.20 * hs, 0.0) / (2.80 * hs);\n"
    "    s_cap = 1.28 * 1.847264 * u * u * exp(-u) * medialTaper;\n"
    "    H_opt = 10.6 * hs * refScale;\n"
    "  } else if (role == 3) {\n"
    "    float r_lip = 2.15 * hs;\n"
    "    float L_lip = 0.42 * hs;\n"
    "    s_lip = 14.5 * exp(-d / L_lip) * (1.0 - smoothstep(0.45 * r_lip, r_lip, d)) * medialTaper;\n"
    "    float u = max(d - 1.95 * hs, 0.0) / (1.80 * hs);\n"
    "    float capCut = 1.0 - smoothstep(7.5 * hs, 10.5 * hs, d);\n"
    "    s_cap = 1.16 * 1.847264 * u * u * exp(-u) * capCut * medialTaper;\n"
    "    H_opt = 10.6 * hs * refScale;\n"
    "  } else {\n"
    "    float r_lip = 2.15 * hs;\n"
    "    float L_lip = 0.42 * hs;\n"
    "    s_lip = 14.5 * exp(-d / L_lip) * (1.0 - smoothstep(0.45 * r_lip, r_lip, d)) * medialTaper;\n"
    "    float u = max(d - 1.95 * hs, 0.0) / (2.60 * hs);\n"
    "    s_cap = 0.56 * 1.847264 * u * u * exp(-u) * medialTaper;\n"
    "    H_opt = 10.6 * hs * refScale;\n"
    "  }\n"
    "  return vec2(mb_snell_intersect(s_lip - s_cap, ior, H_opt), s_lip);\n"
    "}\n"
    "#endif\n"
    "#if MB_HAS(5) || MB_HAS_LIQUID || MB_HAS_ADAPTIVE\n"
    "vec3 backdrop(vec2 p) {\n"
    "  return texture(u_bd, clamp(p * u_map.xy + u_map.zw, u_uvc.xy, u_uvc.zw)).rgb;\n"
    "}\n"
    "float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    "float mb_ink_luma(vec3 c) { return dot(c * c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    "#endif\n"
    "#if MB_HAS_ADAPTIVE\n"
    "float mb_backdrop_luma_rect(vec2 c, vec2 h) {\n"
    "  float sum = 0.0;\n"
    "  float mx1 = -1.0, mx2 = -1.0;\n"
    "  float mn1 = 2.0, mn2 = 2.0;\n"
    "  for (int iy = -1; iy <= 1; iy++) {\n"
    "    float py = c.y + float(iy) * (h.y * 0.60);\n"
    "    for (int ix = -2; ix <= 2; ix++) {\n"
    "      float px = c.x + float(ix) * (h.x * 0.38);\n"
    "      float y = mb_ink_luma(backdrop(vec2(px, py)));\n"
    "      sum += y;\n"
    "      if (y > mx1) { mx2 = mx1; mx1 = y; } else if (y > mx2) { mx2 = y; }\n"
    "      if (y < mn1) { mn2 = mn1; mn1 = y; } else if (y < mn2) { mn2 = y; }\n"
    "    }\n"
    "  }\n"
    "  return (sum - mx1 - mx2 - mn1 - mn2) / 11.0;\n"
    "}\n"
    "float mb_unpack16(vec2 rg) {\n"
    "  float hi = floor(clamp(rg.x, 0.0, 1.0) * 255.0 + 0.5);\n"
    "  float lo = floor(clamp(rg.y, 0.0, 1.0) * 255.0 + 0.5);\n"
    "  return (hi * 256.0 + lo) / 65535.0;\n"
    "}\n"
    "float ad_sample(vec2 ac, float fallback_r, bool is_dark_glass) {\n"
    "  if (u_ad_n > 0) {\n"
    "    int best = -1;\n"
    "    float best_d = 1e9;\n"
    "    for (int i = 0; i < 16; i++) {\n"
    "      if (i >= u_ad_n) break;\n"
    "      float d = length(ac - u_ad_box[i].xy);\n"
    "      if (d <= 2.0 && d < best_d) { best = i; best_d = d; }\n"
    "    }\n"
    "    if (best < 0) {\n"
    "      best_d = 1e9;\n"
    "      for (int i = 0; i < 16; i++) {\n"
    "        if (i >= u_ad_n) break;\n"
    "        vec2 diff = abs(ac - u_ad_box[i].xy);\n"
    "        if (diff.x <= u_ad_box[i].z + 2.0 && diff.y <= u_ad_box[i].w + 2.0) {\n"
    "          float d = length(diff);\n"
    "          if (d < best_d) { best = i; best_d = d; }\n"
    "        }\n"
    "      }\n"
    "    }\n"
    "    if (best >= 0) {\n"
    "      return mb_unpack16(texelFetch(u_ad, ivec2(best, 0), 0).rg);\n"
    "    }\n"
    "  }\n"
    "  float bgL = mb_backdrop_luma_rect(ac, vec2(max(fallback_r, 1.0)));\n"
    "  return is_dark_glass ? smoothstep(0.35, 0.85, bgL) : (1.0 - smoothstep(0.30, 0.42, bgL));\n"
    "}\n"
    "#endif\n"
    "// how much of the pixel at p its rounded clip keeps (r: the corners' radii, top left, then clockwise; s: how smooth\n"
    "// each is), its edge covered as a box's own (0.5 - d * scale), so what it cuts meets the ground of the box that cuts it\n"
    "float clip_cover(vec2 p, vec4 c, vec4 r, vec4 s, float scale) {\n"
    "  float d = mb_sd_clip(p, c, r, s, 1.0 + 2.0 / scale);\n"
    "  return clamp(0.5 - d * scale, 0.0, 1.0);\n"
    "}\n"
    "// what it shows at p, as if uncut\n"
    "void shade(vec2 p, float fade_r) {\n"
    "  int kind = (MB_LIQUID_SINGLE != 0) ? 6 : (ONE_KIND >= 0 ? ONE_KIND : int(v_p.y + 0.5));\n"
    "#if MB_HAS(9)\n"
    "  // where a native view shows: its picture (NativeViews.Picture), the part of it c2 says, cut to its corners\n"
    "  if (kind == 9) { vec2 hh = v_rect.zw * 0.5; float rr = min(mb_corner_of(p - v_rect.xy - hh, v_rr), min(hh.x, hh.y)); vec2 q = abs(p - v_rect.xy - hh) - hh + rr; float a = clamp(0.5 - (length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr) * u_scale, 0.0, 1.0); if (a <= 0.0) discard; vec2 uv = v_c2.xy + clamp((p - v_rect.xy) / v_rect.zw, 0.0, 1.0) * v_c2.zw; if (uv.y < 0.0 || uv.y > 1.0) discard; o = texture(u_img, uv) * a; return; }\n"
    "#endif\n"
    "#if ONE_KIND != 9\n"
    "  vec4 col = v_color;\n"
    "#if MB_HAS(11)\n"
    "  if (kind == 11) {\n"
    "    // a band of a shape (src/ui/shape.mbt): c2.y of its pieces from c2.x; p.x half its stroke's width (0: a fill,\n"
    "    // c2.z 1 by the even-odd rule)\n"
    "    int first = int(v_c2.x + 0.5), n = int(v_c2.y + 0.5);\n"
    "    float a;\n"
    "    if (v_p.x > 0.0) {\n"
    "      float d = 1e9;\n"
    "      for (int i = first; i < first + n; i++) { int t = (i / 6) * 15 + mb_seg_slot(i); d = min(d, mb_seg_dist(texelFetch(u_segs, ivec2(t % 2040, t / 2040), 0), v_rect, p)); }\n"
    "      a = clamp(0.5 - (d - v_p.x) * u_scale, 0.0, 1.0);\n"
    "    } else {\n"
    "      vec4 w = vec4(0.0);\n"
    "      for (int i = first; i < first + n; i++) { int t = (i / 6) * 15 + mb_seg_slot(i); w += mb_path_rows(texelFetch(u_segs, ivec2(t % 2040, t / 2040), 0), v_rect, p, u_scale); }\n"
    "      a = mb_path_cover(w, v_c2.z);\n"
    "    }\n"
    "    o = vec4(col.rgb, 1.0) * col.a * a;\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS(10)\n"
    "  if (kind == 10) {\n"
    "    // a piece of a line (scene.mbt): from c2.xy to c2.zw (shares of its rect), p.x half its width, its ends round\n"
    "    vec2 a = v_rect.xy + v_c2.xy * v_rect.zw, ab = v_rect.xy + v_c2.zw * v_rect.zw - a;\n"
    "    float h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-8), 0.0, 1.0);\n"
    "    float d = length(p - a - ab * h) - v_p.x;\n"
    "    o = vec4(col.rgb, 1.0) * col.a * clamp(0.5 - d * u_scale, 0.0, 1.0);\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS(1) || MB_HAS(3) || MB_HAS(7)\n"
    "  if (kind == 1 || kind == 3 || kind == 7) {\n"
    "    // within its own cell (c2: where in the atlas, in texels; a colour glyph's 16384 across past its place in theirs),\n"
    "    // however its rect is stretched or turned: a sample past the cell's edge texels would blend in what lies beside\n"
    "    // it (another glyph, one left there before). The words' atlas has a glyph's cover alone: white, premultiplied, as\n"
    "    // the colour one would have it\n"
    "    bool colour = v_c2.x >= 16384.0;\n"
    "    vec2 at = vec2(v_c2.x - (colour ? 16384.0 : 0.0), v_c2.y);\n"
    "    // One drawn as big as its picture, not turned, its corner on a pixel: each pixel its texel's centre, as\n"
    "    // win_render.cpp takes it (worked out of where it is across the rect, a float's division took a texel's\n"
    "    // neighbour in where its rounding fell, at 3, 2.625 and 1.5 pixels a point and far across)\n"
    "    vec2 off = abs(v_rect.zw * u_scale - v_c2.zw);\n"
    "    vec2 r0 = v_rect.xy * u_scale, r0i = floor(r0 + 0.5);\n"
    "    bool exact = v_p.x == 0.0 && max(off.x, off.y) <= 0.5 && max(abs(r0.x - r0i.x), abs(r0.y - r0i.y)) <= 0.05;\n"
    "    vec2 tex = exact ? floor(p * u_scale - r0i) + 0.5 : (p - v_rect.xy) / v_rect.zw * v_c2.zw;\n"
    "    vec2 uv = clamp(at + tex, at + 0.5, at + v_c2.zw - 0.5);\n"
    "    vec4 t = colour ? textureLod(u_catlas, uv / vec2(textureSize(u_catlas, 0)), 0.0)\n"
    "                    : vec4(textureLod(u_atlas, uv / vec2(textureSize(u_atlas, 0)), 0.0).r);\n"
    "    o = (kind == 1 || kind == 7) ? vec4(col.rgb, 1.0) * (t.a * col.a) : t * col.a;\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS_LIQUID\n"
    "  if (kind == 6) {\n"
    "    // Copyright 2025, Tim Lehmann for whynotmake.it. Adapted from flutter_liquid_glass\n"
    "    // liquid_glass_final_render_core.glsl, Apache-2.0.\n"
    "    float k = v_pad.w;\n"
    "    vec4 s_rr = max(max(v_rr.x, v_rr.y), max(v_rr.z, v_rr.w)) > 0.0 ? v_rr : vec4(v_p.x);\n"
    "    float d;\n"
    "    float halfMinor = 1e9;\n"
    "#if MB_LIQUID_SINGLE\n"
    "    d = sd_rr(p, v_rect, s_rr);\n"
    "    halfMinor = min(v_rect.z, v_rect.w) * 0.5;\n"
    "#else\n"
    "    if (k <= 0.0) {\n"
    "      d = sd_rr(p, v_rect, s_rr);\n"
    "      halfMinor = min(v_rect.z, v_rect.w) * 0.5;\n"
    "    } else {\n"
    "      d = 1e9;\n"
    "      for (int i = 0; i < 8; i++) {\n"
    "        if (i >= u_n) break;\n"
    "        float di = sd_rr(p, u_shape[i], u_rad[i]);\n"
    "        float hi = min(u_shape[i].z, u_shape[i].w) * 0.5;\n"
    "        if (i == 0) {\n"
    "          d = di;\n"
    "          halfMinor = hi;\n"
    "        } else {\n"
    "          float h = max(k - abs(d - di), 0.0) / k;\n"
    "          float w = d < di ? 0.5 * h : 1.0 - 0.5 * h;\n"
    "          d = min(d, di) - h * h * k * 0.25;\n"
    "          halfMinor = mix(halfMinor, hi, w);\n"
    "        }\n"
    "      }\n"
    "    }\n"
    "#endif\n"
    "    halfMinor = max(halfMinor, 1.0);\n"
    "    float sd_px = -d * u_scale;\n"
    "    float materialAlpha = clamp(sd_px + 0.5, 0.0, 1.0);\n"
    "    float edgeW = 0.75 * u_scale;\n"
    "    float outward = -sd_px;\n"
    "    float ext_cov = mb_contour_int(max(outward + 0.5, 0.0), edgeW)\n"
    "                  - mb_contour_int(max(outward - 0.5, 0.0), edgeW);\n"
    "    if (materialAlpha < 0.01 && ext_cov < 0.01) discard;\n"
    "    float regMix = smoothstep(0.105, 0.305, col.a);\n"
    "    bool is_clear = (regMix <= 0.0);\n"
    "    bool is_adaptive = v_c2.z < -0.5;\n"
    "    float spot_raw = is_adaptive ? (-v_c2.z - 1.0) : v_c2.z;\n"
    "    bool is_dark = (!is_clear && luma(col.rgb) < 0.35);\n"
    "    float clearVeil = is_clear ? smoothstep(0.005, 0.102, col.a) : 0.0;\n"
    "    float droplet = is_clear ? (1.0 - clearVeil) : 0.0;\n"
    "#if MB_LIQUID_SINGLE\n"
    "    bool is_drop = (droplet > 0.001);\n"
    "#else\n"
    "    bool is_drop = (droplet > 0.001) && (k <= 0.0);\n"
    "#endif\n"
    "    float inward = max(-d, 0.0);\n"
    "    float rawBevel = max(v_c2.y, 0.0);\n"
    "    float rawAmount = max(v_pad.y, 0.0);\n"
    "    float lensScale = min(1.0, halfMinor / max(rawBevel, 0.001));\n"
    "    float clearBevel = min(rawBevel * lensScale, halfMinor * 0.72);\n"
    "    float clearAmount = min(rawAmount * lensScale, halfMinor * 0.58);\n"
    "    float regBevel = min(rawBevel, 0.55 * halfMinor);\n"
    "    float regAmount = min(rawAmount, halfMinor);\n"
    "    float bevel = mix(clearBevel, regBevel, regMix);\n"
    "    float amount = mix(clearAmount, regAmount, regMix);\n"
    "    vec2 surfaceNormal = vec2(0.0, 0.0);\n"
    "    float shortening = 0.0;\n"
    "    vec2 disp = vec2(0.0, 0.0);\n"
    "    bool need_grad = (inward < max(bevel, 23.0)) || (ext_cov > 0.0) || is_drop;\n"
    "    if (need_grad) {\n"
    "      float e = 0.5;\n"
    "#if MB_LIQUID_SINGLE\n"
    "      vec2 grad = vec2(\n"
    "          sd_rr(p + vec2(e, 0.0), v_rect, s_rr) - sd_rr(p - vec2(e, 0.0), v_rect, s_rr),\n"
    "          sd_rr(p + vec2(0.0, e), v_rect, s_rr) - sd_rr(p - vec2(0.0, e), v_rect, s_rr)\n"
    "        ) / (2.0 * e);\n"
    "#else\n"
    "      vec2 grad = k <= 0.0\n"
    "        ? vec2(\n"
    "            sd_rr(p + vec2(e, 0.0), v_rect, s_rr) - sd_rr(p - vec2(e, 0.0), v_rect, s_rr),\n"
    "            sd_rr(p + vec2(0.0, e), v_rect, s_rr) - sd_rr(p - vec2(0.0, e), v_rect, s_rr)\n"
    "          ) / (2.0 * e)\n"
    "        : vec2(\n"
    "            sd_group(p + vec2(e, 0.0), k) - sd_group(p - vec2(e, 0.0), k),\n"
    "            sd_group(p + vec2(0.0, e), k) - sd_group(p - vec2(0.0, e), k)\n"
    "          ) / (2.0 * e);\n"
    "#endif\n"
    "      float gradLen = length(grad);\n"
    "      surfaceNormal = gradLen > 0.0001 ? grad / gradLen : vec2(0.0, 0.0);\n"
    "      shortening = sqrt(clamp(gradLen, 0.0, 1.0));\n"
    "      if (inward < bevel && bevel > 0.001 && amount > 0.0) {\n"
    "        float bevelX = 1.0 - clamp(inward / bevel, 0.0, 1.0);\n"
    "        float clearMag = amount * (1.0 - sqrt(max(1.0 - bevelX * bevelX, 0.0))) * shortening;\n"
    "        float regMaxR = 0.80;\n"
    "        if (bevel > 3.0) {\n"
    "          float inv = 1.0 / (1.0 - 3.0 / bevel);\n"
    "          float rCap = sqrt(max(inv * inv - 1.0, 0.0)) / (1.0 + abs(v_pad.z) * 0.5);\n"
    "          regMaxR = min(regMaxR, rCap);\n"
    "        }\n"
    "        float regMag = min(amount, regMaxR * bevel) * (1.0 - sqrt(max(1.0 - bevelX * bevelX, 0.0))) * shortening;\n"
    "        float mag = mix(clearMag, regMag, regMix);\n"
    "        disp = surfaceNormal * (-mag);\n"
    "      }\n"
    "    }\n"
    "    int dropRole = (v_p.w <= -8.0) ? int(floor((-v_p.w + 4.0) / 16.0)) : 0;\n"
    "    float rawZoomDelta = (v_p.w <= -8.0) ? ((-v_p.w) - float(dropRole) * 16.0) : ((v_p.w < 0.0) ? (-v_p.w) : 0.0);\n"
    "    float lensZoom = clamp(1.0 + rawZoomDelta, 1.0, 3.0);\n"
    "    bool isRoleSlid = (dropRole == 1);\n"
    "    bool isRoleSw = (dropRole == 2);\n"
    "    bool isRoleSeg = (dropRole == 3);\n"
    "    bool isRoleTab = (dropRole == 4);\n"
    "    bool isModernDrop = is_drop && (dropRole >= 1) && (dropRole <= 4);\n"
    "    float snellSLip = 0.0;\n"
    "    float snellDmag = 0.0;\n"
    "    vec2 sampleBase = p;\n"
    "    if (lensZoom > 1.0001) {\n"
    "#if MB_LIQUID_SINGLE\n"
    "      vec2 zoomC = v_rect.xy + v_rect.zw * 0.5;\n"
    "#else\n"
    "      vec2 zoomC = (k <= 0.0) ? (v_rect.xy + v_rect.zw * 0.5) : ((u_gb.xy + u_gb.zw) * 0.5);\n"
    "#endif\n"
    "      sampleBase = zoomC + (p - zoomC) / lensZoom;\n"
    "    }\n"
    "    float dropHairline = 0.0;\n"
    "    float pressAmt = 0.0;\n"
    "    float menAA = 0.0;\n"
    "    float barIconGate = 0.0;\n"
    "    vec2 barCaDisp = vec2(0.0, 0.0);\n"
    "    if (is_drop) {\n"
    "      pressAmt = clamp(v_c2.x, 0.0, 1.0);\n"
    "      dropHairline = (1.0 - smoothstep(0.18, 0.62, inward)) * pressAmt;\n"
    "      if (isModernDrop) {\n"
    "        vec2 sn = mb_droplet_snell(inward, rawAmount, halfMinor, dropRole, 1.52);\n"
    "        snellSLip = sn.y;\n"
    "        snellDmag = clamp(sn.x * shortening, -halfMinor, halfMinor);\n"
    "        vec2 dropDisp = surfaceNormal * snellDmag;\n"
    "        if (isRoleSlid && snellSLip > 0.6 && pressAmt > 0.001) {\n"
    "          menAA = 0.35 * smoothstep(0.6, 2.0, snellSLip) * pressAmt * droplet;\n"
    "        }\n"
    "        if (isRoleTab) {\n"
    "          float pinchWeight = smoothstep(4.5, 6.5, rawAmount);\n"
    "          vec2 lensCenter = v_rect.xy + v_rect.zw * 0.5;\n"
    "          vec2 centered = (p - lensCenter) / max(v_rect.zw, vec2(1.0));\n"
    "          vec2 absC = abs(centered) * 2.0;\n"
    "          float tipDist = (0.5 - abs(centered.x)) * v_rect.z;\n"
    "          float capAbsX = clamp(1.0 - tipDist / max(v_rect.w * 0.6514, 1.0), 0.0, 1.0);\n"
    "          float endCapX = smoothstep(0.32, 0.70, capAbsX);\n"
    "          float iconBandY = 1.0 - smoothstep(0.66, 0.79, absC.y);\n"
    "          barIconGate = iconBandY * endCapX * pressAmt * pinchWeight * droplet;\n"
    "          float iconBevelX = smoothstep(0.45, 1.15, inward) * (1.0 - smoothstep(2.60, 9.40, inward));\n"
    "          float iconBevelY = smoothstep(0.45, 1.25, inward) * (1.0 - smoothstep(2.20, 9.00, inward));\n"
    "          float signX = (centered.x >= 0.0) ? 1.0 : -1.0;\n"
    "          barCaDisp = vec2(-signX * 5.2 * iconBevelX, -centered.y * 2.0 * 4.8 * iconBevelY) * barIconGate;\n"
    "        }\n"
    "        disp = mix(disp, dropDisp, droplet);\n"
    "      } else {\n"
    "        float bevelX = (bevel > 0.001) ? (1.0 - clamp(inward / bevel, 0.0, 1.0)) : 0.0;\n"
    "        vec2 paraxialDisp = -surfaceNormal * (bevelX * bevelX * 3.6 * pressAmt);\n"
    "        vec2 dropDisp = mix(paraxialDisp, surfaceNormal * 0.85, dropHairline);\n"
    "        float dLen = length(dropDisp);\n"
    "        if (dLen > halfMinor) dropDisp *= (halfMinor / dLen);\n"
    "        disp = mix(disp, dropDisp, droplet);\n"
    "      }\n"
    "    }\n"
    "    vec3 refractColor;\n"
    "    if (isModernDrop) {\n"
    "      if (abs(v_pad.z) > 0.001 && snellSLip > 0.15 && pressAmt > 0.001) {\n"
    "        float dispR = mb_droplet_snell(inward, rawAmount, halfMinor, dropRole, 1.47).x * shortening;\n"
    "        float dispB = mb_droplet_snell(inward, rawAmount, halfMinor, dropRole, 1.58).x * shortening;\n"
    "        float caW = smoothstep(0.15, 1.20, snellSLip) * clamp(abs(v_pad.z) / 0.04, 0.0, 1.0) * droplet;\n"
    "        float dR = clamp(mix(snellDmag, dispR, caW), -halfMinor, halfMinor);\n"
    "        float dB = clamp(mix(snellDmag, dispB, caW), -halfMinor, halfMinor);\n"
    "        vec2 dispR2 = mix(disp, surfaceNormal * dR, droplet);\n"
    "        vec2 dispB2 = mix(disp, surfaceNormal * dB, droplet);\n"
    "        refractColor = vec3(\n"
    "          backdrop(sampleBase + dispR2).r,\n"
    "          backdrop(sampleBase + disp).g,\n"
    "          backdrop(sampleBase + dispB2).b\n"
    "        );\n"
    "      } else {\n"
    "        refractColor = backdrop(sampleBase + disp);\n"
    "      }\n"
    "    } else if (inward >= bevel || abs(v_pad.z) * amount * u_scale <= 0.25) {\n"
    "      refractColor = backdrop(sampleBase + disp);\n"
    "    } else {\n"
    "      float ds = v_pad.z * 0.5;\n"
    "      refractColor = vec3(\n"
    "        backdrop(sampleBase + disp * (1.0 + ds)).r,\n"
    "        backdrop(sampleBase + disp).g,\n"
    "        backdrop(sampleBase + disp * (1.0 - ds)).b\n"
    "      );\n"
    "    }\n"
    "    if (menAA > 0.01) {\n"
    "      float aaOff = isModernDrop ? 0.25 : 0.35;\n"
    "      vec2 nOff = surfaceNormal * aaOff;\n"
    "      vec2 tOff = vec2(-surfaceNormal.y, surfaceNormal.x) * aaOff;\n"
    "      vec2 mc = sampleBase + disp;\n"
    "      vec3 menAvg = (backdrop(mc + nOff + tOff) + backdrop(mc + nOff - tOff)\n"
    "                   + backdrop(mc - nOff + tOff) + backdrop(mc - nOff - tOff)) * 0.25;\n"
    "      refractColor = mix(refractColor, menAvg, menAA);\n"
    "    }\n"
    "    if (isRoleTab && barIconGate > 0.01 && dropHairline < 0.99) {\n"
    "      float bevelGate = barIconGate * smoothstep(0.45, 1.15, inward) * (1.0 - smoothstep(2.60, 9.40, inward)) * (1.0 - dropHairline);\n"
    "      if (bevelGate > 0.001) {\n"
    "        float refX = (p.x >= v_rect.x + v_rect.z * 0.5) ? 0.26 : 0.74;\n"
    "        vec3 refPlatter = backdrop(v_rect.xy + vec2(refX, 0.18) * v_rect.zw);\n"
    "        float isDarkPlatter = 1.0 - step(0.35, luma(refPlatter));\n"
    "        vec3 iconG = backdrop(p + barCaDisp);\n"
    "        float iconDiffG = length(iconG - refPlatter);\n"
    "        float iconPeakG = max(iconG.r, max(iconG.g, iconG.b));\n"
    "        float lightIconMask = smoothstep(0.24, 0.42, iconDiffG);\n"
    "        float darkIconMask = smoothstep(0.38, 0.55, iconPeakG);\n"
    "        float isInsidePlatter = mix(lightIconMask, darkIconMask * smoothstep(0.05, 0.12, luma(refractColor)), isDarkPlatter);\n"
    "        float iconCaGate = mix(smoothstep(0.22, 0.40, iconDiffG), darkIconMask, isDarkPlatter);\n"
    "        float iconDisp = 0.035 * iconCaGate;\n"
    "        vec3 iconRGB = iconG;\n"
    "        if (iconDisp > 0.002) {\n"
    "          vec3 iconR = backdrop(p + barCaDisp * (1.0 + iconDisp));\n"
    "          vec3 iconB = backdrop(p + barCaDisp * (1.0 - iconDisp));\n"
    "          float rbValid = mix(1.0, smoothstep(0.04, 0.12, min(luma(iconR), luma(iconB))), isDarkPlatter);\n"
    "          iconRGB.r = mix(iconG.r, iconR.r, rbValid);\n"
    "          iconRGB.b = mix(iconG.b, iconB.b, rbValid);\n"
    "        }\n"
    "        refractColor = mix(refractColor, iconRGB, isInsidePlatter * bevelGate);\n"
    "      }\n"
    "    }\n"
    "    vec3 emission;\n"
    "    float transmittance;\n"
    "    float lift;\n"
    "    float chromaGain;\n"
    "    float contourStr;\n"
    "    float contourDirAmt;\n"
    "    float bevelShadowStr;\n"
    "    float glintLum;\n"
    "    float glintFaceGain;\n"
    "    float glintVib;\n"
    "    float fogT = 0.0;\n"
    "    vec3 lightEmSaved = vec3(0.0);\n"
    "    vec3 darkEmSaved = vec3(0.0);\n"
    "    float darkMixSaved = 0.0;\n"
    "    float lightExtra = 0.0;\n"
    "    bool hasLightEm = false;\n"
    "    float colChroma = max(max(col.r, col.g), col.b) - min(min(col.r, col.g), col.b);\n"
    "    float applePanelGate = smoothstep(0.005, 0.02, abs(v_pad.z)) * (1.0 - smoothstep(0.035, 0.05, abs(v_pad.z))) * (1.0 - smoothstep(0.04, 0.08, colChroma));\n"
    "    if (is_clear) {\n"
    "      // iOS 27 clear liquid glass: col.a == 0.0 keeps crystal-clear zero-veil optical lens\n"
    "      // (lifted tab-bar / toggle / slider thumb & loupe), while Glass::clear() (col.a ~ 0.102)\n"
    "      // blends smoothly into the +0.126 translucent micro-veil over media.\n"
    "      emission = vec3(1.0, 1.0, 1.0) * (0.126 * clearVeil);\n"
    "      transmittance = mix(1.0, 0.90, clearVeil);\n"
    "      lift = mix(0.0, 0.10, clearVeil);\n"
    "      chromaGain = mix(1.08, 1.0, clearVeil);\n"
    "      contourStr = 0.25 * clearVeil;\n"
    "      contourDirAmt = mix(0.32, 0.77, clearVeil);\n"
    "      bevelShadowStr = 0.04 * clearVeil;\n"
    "      glintLum = mix(1.85, 1.35, clearVeil);\n"
    "      glintFaceGain = mix(0.14, 0.25, clearVeil);\n"
    "      glintVib = mix(2.4, 1.5, clearVeil);\n"
    "    } else if (is_adaptive) {\n"
    "#if MB_LIQUID_SINGLE\n"
    "      vec2 ac = v_rect.xy + v_rect.zw * 0.5;\n"
    "      float ar = max(min(v_rect.z, v_rect.w) * 0.5, 1.0) * 0.5;\n"
    "#else\n"
    "      vec2 ac = (k <= 0.0) ? (v_rect.xy + v_rect.zw * 0.5) : ((u_gb.xy + u_gb.zw) * 0.5);\n"
    "      float ar = ((k <= 0.0) ? max(min(v_rect.z, v_rect.w) * 0.5, 1.0) : max(min(u_gb.z - u_gb.x, u_gb.w - u_gb.y) * 0.5, 1.0)) * 0.5;\n"
    "#endif\n"
    "      float val = ad_sample(ac, ar, is_dark);\n"
    "      float baseDens = mix(0.30, col.a, smoothstep(0.405, 0.50, col.a));\n"
    "      if (is_dark) {\n"
    "        float brightT = val;\n"
    "        fogT = brightT;\n"
    "        float dens = max(baseDens, mix(baseDens, 0.64, brightT));\n"
    "        float extra = clamp((dens - 0.30) / (1.0 - 0.30), 0.0, 1.0);\n"
    "        emission = mix(vec3(30.0 / 255.0), vec3(24.0 / 255.0), extra);\n"
    "        transmittance = mix(0.50, 0.0, extra);\n"
    "        lift = mix(0.24, 0.0, extra);\n"
    "        chromaGain = mix(1.05, 0.0, extra);\n"
    "        contourStr = 0.88; contourDirAmt = 1.0; bevelShadowStr = 0.036;\n"
    "        glintLum = 1.6; glintFaceGain = 0.0; glintVib = 2.85;\n"
    "      } else {\n"
    "        float darkMix = val;\n"
    "        fogT = darkMix;\n"
    "        float extra = clamp((baseDens - 0.30) / (1.0 - 0.30), 0.0, 1.0);\n"
    "        float darkDens = max(baseDens, mix(baseDens, 0.52, darkMix));\n"
    "        float darkExtra = clamp((darkDens - 0.30) / (1.0 - 0.30), 0.0, 1.0);\n"
    "        vec3 lightEm = vec3(253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0) * baseDens;\n"
    "        vec3 darkEm = mix(vec3(30.0 / 255.0), vec3(24.0 / 255.0), darkExtra);\n"
    "        lightEmSaved = lightEm; darkEmSaved = darkEm; darkMixSaved = darkMix; lightExtra = extra; hasLightEm = true;\n"
    "        emission = mix(lightEm, darkEm, darkMix);\n"
    "        transmittance = mix(mix(0.70, 0.0, extra), mix(0.50, 0.0, darkExtra), darkMix);\n"
    "        lift = mix(mix(0.16, 0.0, extra), mix(0.24, 0.0, darkExtra), darkMix);\n"
    "        chromaGain = mix(mix(1.18, 0.0, extra), mix(1.05, 0.0, darkExtra), darkMix);\n"
    "        contourStr = mix(0.43, 0.88, darkMix);\n"
    "        contourDirAmt = mix(0.77, 1.0, darkMix);\n"
    "        bevelShadowStr = 0.036;\n"
    "        glintLum = 1.6; glintFaceGain = 0.0; glintVib = 2.85;\n"
    "      }\n"
    "    } else if (is_dark) {\n"
    "      float darkDens = mix(0.30, col.a, smoothstep(0.405, 0.50, col.a));\n"
    "      float extra = clamp((darkDens - 0.30) / (1.0 - 0.30), 0.0, 1.0);\n"
    "      emission = mix(vec3(30.0 / 255.0), vec3(24.0 / 255.0), extra);\n"
    "      transmittance = mix(0.50, 0.0, extra);\n"
    "      lift = mix(0.24, 0.0, extra);\n"
    "      float darkChromaFloor = 0.45 * (1.0 - smoothstep(0.72, 0.84, col.a)) * applePanelGate;\n"
    "      chromaGain = mix(1.05, darkChromaFloor, extra);\n"
    "      contourStr = 0.88; contourDirAmt = 1.0; bevelShadowStr = 0.036;\n"
    "      glintLum = 1.6; glintFaceGain = 0.0; glintVib = 2.85;\n"
    "    } else {\n"
    "      float lightDens = mix(0.30, col.a, smoothstep(0.405, 0.50, col.a));\n"
    "      float extra = clamp((lightDens - 0.30) / (1.0 - 0.30), 0.0, 1.0);\n"
    "      emission = vec3(253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0) * lightDens;\n"
    "      lightEmSaved = emission; lightExtra = extra; hasLightEm = true;\n"
    "      transmittance = mix(0.70, 0.0, extra);\n"
    "      lift = mix(0.16, 0.0, extra);\n"
    "      chromaGain = mix(1.18, 0.0, extra);\n"
    "      contourStr = 0.43; contourDirAmt = 0.77; bevelShadowStr = 0.036;\n"
    "      glintLum = 1.6; glintFaceGain = 0.0; glintVib = 2.85;\n"
    "    }\n"
    "    vec3 lowC = refractColor;\n"
    "    if (regMix > 0.001) {\n"
    "      vec2 fc = sampleBase + disp;\n"
    "      float rD = mix(3.2, 4.2, fogT);\n"
    "      vec3 s1 = backdrop(fc + vec2( rD,  rD));\n"
    "      vec3 s2 = backdrop(fc + vec2(-rD,  rD));\n"
    "      vec3 s3 = backdrop(fc + vec2( rD, -rD));\n"
    "      vec3 s4 = backdrop(fc + vec2(-rD, -rD));\n"
    "      lowC = (refractColor * 2.0 + s1 + s2 + s3 + s4) * (1.0 / 6.0);\n"
    "      float interior = (bevel > 0.001) ? smoothstep(0.30 * bevel, 0.85 * bevel, inward) : 1.0;\n"
    "      float y0 = luma(refractColor), y1 = luma(s1), y2 = luma(s2), y3 = luma(s3), y4 = luma(s4);\n"
    "      float yMean = (y0 * 2.0 + y1 + y2 + y3 + y4) * (1.0 / 6.0);\n"
    "      float yVar = ((y0 - yMean) * (y0 - yMean) * 2.0\n"
    "                  + (y1 - yMean) * (y1 - yMean) + (y2 - yMean) * (y2 - yMean)\n"
    "                  + (y3 - yMean) * (y3 - yMean) + (y4 - yMean) * (y4 - yMean)) * (1.0 / 6.0);\n"
    "      float detailAmt = smoothstep(0.020, 0.095, sqrt(max(yVar, 0.0)));\n"
    "      float dampW = interior * max(detailAmt * 0.65, fogT * 0.72) * regMix;\n"
    "      refractColor = mix(refractColor, lowC, dampW);\n"
    "    }\n"
    "    if (hasLightEm) {\n"
    "      if (!is_adaptive && lightExtra > 0.001) {\n"
    "        float brightRelax = smoothstep(0.55, 1.00, luma(lowC)) * (1.0 - smoothstep(0.80, 0.95, col.a)) * applePanelGate;\n"
    "        if (brightRelax > 0.001) {\n"
    "          float effExtra = lightExtra * mix(1.0, 0.45, brightRelax);\n"
    "          float effDens = 0.30 + 0.70 * effExtra;\n"
    "          lightEmSaved = vec3(253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0) * effDens;\n"
    "          lightExtra = effExtra;\n"
    "          transmittance = mix(0.70, 0.0, effExtra);\n"
    "          lift = mix(0.16, 0.0, effExtra);\n"
    "          chromaGain = mix(1.18, 0.0, effExtra);\n"
    "        }\n"
    "      }\n"
    "      float bgChroma = max(lowC.r, max(lowC.g, lowC.b)) - min(lowC.r, min(lowC.g, lowC.b));\n"
    "      float lightVeilScale = mix(1.0, 0.65, smoothstep(0.08, 0.40, bgChroma) * regMix * (1.0 - lightExtra));\n"
    "      emission = mix(lightEmSaved * lightVeilScale, darkEmSaved, darkMixSaved);\n"
    "    }\n"
    "    if (regMix > 0.0 && regMix < 1.0) {\n"
    "      emission = mix(vec3(0.126, 0.126, 0.126), emission, regMix);\n"
    "      transmittance = mix(0.90, transmittance, regMix);\n"
    "      lift = mix(0.10, lift, regMix);\n"
    "      chromaGain = mix(1.0, chromaGain, regMix);\n"
    "      contourStr = mix(0.25, contourStr, regMix);\n"
    "      contourDirAmt = mix(0.77, contourDirAmt, regMix);\n"
    "      bevelShadowStr = mix(0.04, bevelShadowStr, regMix);\n"
    "      glintLum = mix(1.35, glintLum, regMix);\n"
    "      glintFaceGain = mix(0.25, glintFaceGain, regMix);\n"
    "      glintVib = mix(1.5, glintVib, regMix);\n"
    "    }\n"
    "    contourStr *= (1.0 - regMix);\n"
    "    float Y = luma(refractColor);\n"
    "    float transLum = clamp(Y * (1.0 + lift * (1.0 - Y)), 0.0, 1.0);\n"
    "    vec3 chromaVec = (refractColor - vec3(Y)) * (chromaGain * v_p.z);\n"
    "    float baseLum = clamp(transLum * transmittance, 0.0, 1.0);\n"
    "    vec3 transmittedColor = vec3(baseLum) + chromaVec;\n"
    "    vec3 rawBase = emission + transmittedColor;\n"
    "    // Exact Wave 3 legacy mapping for Clear / Lifted Lenses (regMix == 0)\n"
    "    float maxC = max(rawBase.r, max(rawBase.g, rawBase.b));\n"
    "    vec3 legacyBase = rawBase;\n"
    "    if (maxC > 1.0) {\n"
    "      float lumL = clamp(luma(emission) + baseLum, 0.0, 0.999);\n"
    "      float sL = clamp((1.0 - lumL) / max(maxC - lumL, 0.0001), 0.0, 1.0);\n"
    "      legacyBase = vec3(lumL) + (rawBase - vec3(lumL)) * sL;\n"
    "    }\n"
    "    legacyBase = clamp(legacyBase, 0.0, 1.0);\n"
    "    vec3 baseColor = legacyBase;\n"
    "    if (regMix > 0.001) {\n"
    "      float lumR = clamp(luma(emission) + baseLum, 0.001, 0.999);\n"
    "      vec3 dC = rawBase - vec3(lumR);\n"
    "      float s = 1.0;\n"
    "      if (dC.r > 0.0001) s = min(s, (1.0 - lumR) / dC.r);\n"
    "      else if (dC.r < -0.0001) s = min(s, lumR / (-dC.r));\n"
    "      if (dC.g > 0.0001) s = min(s, (1.0 - lumR) / dC.g);\n"
    "      else if (dC.g < -0.0001) s = min(s, lumR / (-dC.g));\n"
    "      if (dC.b > 0.0001) s = min(s, (1.0 - lumR) / dC.b);\n"
    "      else if (dC.b < -0.0001) s = min(s, lumR / (-dC.b));\n"
    "      vec3 regProjected = clamp(vec3(lumR) + dC * clamp(s, 0.0, 1.0), 0.0, 1.0);\n"
    "      baseColor = mix(legacyBase, regProjected, regMix);\n"
    "    }\n"
    "    // Honor explicit chromatic tints (non-neutral) if a caller requests colored liquid glass\n"
    "    if (colChroma > 0.08 && col.a > 0.001) {\n"
    "      float tintW = col.a <= 0.45\n"
    "        ? col.a * 0.5\n"
    "        : mix(0.225, 0.86, smoothstep(0.45, 0.80, col.a));\n"
    "      baseColor = mix(baseColor, col.rgb, tintW);\n"
    "    }\n"
    "    float spot = 0.0;\n"
    "    if (spot_raw > 0.5) {\n"
    "      float q = spot_raw - 1.0;\n"
    "      float qx = floor(q * 0.000244140625);\n"
    "      float qy = q - qx * 4096.0;\n"
    "      vec2 gp = v_rect.xy + vec2(qx * 0.5 - 256.0, qy * 0.5 - 256.0);\n"
    "      float gr = max(min(v_rect.z, v_rect.w) * 1.5, 64.0);\n"
    "      spot = 1.0 - smoothstep(gr * 0.1, gr, length(p - gp));\n"
    "      baseColor = clamp(baseColor + vec3(0.08 * spot), 0.0, 1.0);\n"
    "    }\n"
    "    vec2 rn = vec2(0.0, 0.0);\n"
    "    float tangency = 0.0;\n"
    "    if (need_grad) {\n"
    "      vec2 la = u_glight;\n"
    "      rn = vec2(\n"
    "        surfaceNormal.x * la.x + surfaceNormal.y * la.y,\n"
    "        -surfaceNormal.x * la.y + surfaceNormal.y * la.x\n"
    "      );\n"
    "      tangency = abs(rn.x);\n"
    "    }\n"
    "    vec3 result = baseColor;\n"
    "    // (a) Inner bevel shadow (subtracts only transmittedColor; lightFacing = -rn.y)\n"
    "    if (bevelShadowStr >= 0.001 && inward < 23.0) {\n"
    "      float lightFacing = -rn.y;\n"
    "      float shadowShift = 6.0 * lightFacing;\n"
    "      float penumbra = 2.0 * shadowShift;\n"
    "      float bevelLeading = penumbra > 0.001 ? smoothstep(0.0, penumbra, inward) : 1.0;\n"
    "      float bevelFalloff = 1.0 - smoothstep(0.0, 16.0, inward - shadowShift);\n"
    "      float wrappedFacing = smoothstep(0.0, 1.0, lightFacing * 0.5 + 0.5);\n"
    "      float bevelDir = mix(1.0, wrappedFacing, 0.5);\n"
    "      float bevelShadow = clamp(bevelLeading * bevelFalloff * bevelDir * bevelShadowStr, 0.0, 1.0);\n"
    "      result = max(result - transmittedColor * bevelShadow, vec3(0.0));\n"
    "    }\n"
    "    // (b) Glint (clear glass diagonal glint + Native iOS 27 vertical 1pt rimLight & 0.5pt inner hairline for Regular Glass)\n"
    "    if (v_c2.x > 0.01 && inward < 4.8 && regMix < 0.999) {\n"
    "      float glintProfile = clamp(1.0 - inward / 1.2, 0.0, 1.0)\n"
    "                         + 0.21 * clamp(1.0 - inward / 4.8, 0.0, 1.0);\n"
    "      float dirLobe = pow(max(1.0 - tangency, 0.0), 0.85);\n"
    "      float lobe = mix(is_clear ? 0.30 : 0.18, 1.0, dirLobe);\n"
    "      float glintGain = is_clear ? (0.34 * clearVeil) : 0.28;\n"
    "      float glint = clamp(v_c2.x * glintGain * lobe * glintProfile + spot * 0.08 * glintProfile, 0.0, 1.0) * (1.0 - regMix);\n"
    "      float resLum = luma(result);\n"
    "      vec3 glintTarget = vec3(glintLum) + result * glintFaceGain + (result - vec3(resLum)) * glintVib;\n"
    "      result = clamp(mix(result, glintTarget, glint), 0.0, 1.0);\n"
    "    }\n"
    "    if (regMix > 0.001) {\n"
    "      float regHairline;\n"
    "      if (is_dark) {\n"
    "        float regHw = min(0.50, 1.15 / max(u_scale, 1.0));\n"
    "        regHairline = (1.0 - smoothstep(regHw * 0.35, regHw, inward)) * materialAlpha * regMix;\n"
    "      } else {\n"
    "        float regHairWpx = max(0.85 * u_scale, 1.70);\n"
    "        float regA = clamp(sd_px - 0.5, 0.0, regHairWpx);\n"
    "        float regB = clamp(sd_px + 0.5, 0.0, regHairWpx);\n"
    "        float regBandCov = mb_para_int(regB, regHairWpx) - mb_para_int(regA, regHairWpx);\n"
    "        regHairline = clamp(regBandCov / max(materialAlpha, 0.001), 0.0, 1.0) * regMix;\n"
    "      }\n"
    "      float regAcross = pow(max(1.0 - rn.y * rn.y, 0.0), 1.75);\n"
    "      float regShadeMask = is_dark ? regAcross : mix(0.28, 1.0, regAcross);\n"
    "      if (v_c2.x > 0.01 && inward < 12.0) {\n"
    "        float along = is_dark ? rn.y : -rn.y;\n"
    "        float lit = max(along, 0.0);\n"
    "        float opp = max(-along, 0.0);\n"
    "        float lit2 = lit * lit;\n"
    "        float opp2 = opp * opp;\n"
    "        float diag = abs(rn.x * rn.y) * 2.0;\n"
    "        float regLobe = 1.0 * (lit2 * lit2) + (is_dark ? 0.80 : 0.85) * (opp2 * opp2) + 0.10 * (diag * diag * diag) + 0.03;\n"
    "        float regInset = max(0.0, inward - 0.30);\n"
    "        float regCore = exp(-regInset / 0.55);\n"
    "        float regTail = exp(-inward / 2.0);\n"
    "        float regEase = pow(max(1.0 - luma(result), 0.0), 0.3);\n"
    "        float regRimGain = 1.0 * clamp(v_c2.x / 0.6, 0.0, 1.5);\n"
    "        float regRim = (regRimGain * regLobe * regEase * (0.185 * regCore + 0.020 * regTail) * (1.0 - regHairline * regShadeMask) + spot * 0.10 * regCore) * regMix;\n"
    "        vec3 rimTarget = clamp(vec3(1.0) + (refractColor - vec3(Y)) * 1.0, 0.0, 1.0);\n"
    "        result = mix(result, rimTarget, clamp(regRim, 0.0, 1.0));\n"
    "        float panelRimGate = smoothstep(0.48, 0.65, col.a) * (1.0 - smoothstep(0.85, 0.98, col.a)) * applePanelGate;\n"
    "        if (panelRimGate > 0.001) {\n"
    "          float cushionEnv = smoothstep(0.55, 1.35, inward) * exp(-max(0.0, inward - 1.0) / 3.0);\n"
    "          float cushionLobe = max(regLobe, 0.42);\n"
    "          float cushionStr = (is_dark ? 0.06 : 0.62) * cushionLobe * cushionEnv * panelRimGate * regMix;\n"
    "          result = mix(result, vec3(1.0), clamp(cushionStr, 0.0, 1.0));\n"
    "        }\n"
    "      }\n"
    "      if (regHairline > 0.001) {\n"
    "        float regShade = (is_dark ? 0.0 : 0.13) * regShadeMask;\n"
    "        result *= (1.0 - regShade * regHairline);\n"
    "      }\n"
    "    }\n"
    "    if (isModernDrop) {\n"
    "      float backdropLuma = clamp(Y, 0.0, 1.0);\n"
    "      float brightBg = smoothstep(0.35, 0.75, backdropLuma);\n"
    "      float liftGain = isRoleTab ? 0.025 : (isRoleSeg ? 0.014 : 0.098);\n"
    "      vec3 dropRes = clamp(refractColor + vec3(liftGain * pressAmt * (1.0 - backdropLuma)), 0.0, 1.0);\n"
    "      float domeScale = clamp(v_rect.w / 38.4, 0.80, 1.35);\n"
    "      float sizeGate = smoothstep(28.0, 36.0, v_rect.w);\n"
    "      float roleVol = isRoleSeg ? 0.65 : (isRoleTab ? 0.55 : 1.0);\n"
    "      float upperFace = smoothstep(-0.15, 0.85, -surfaceNormal.y);\n"
    "      float qTop = (inward - 8.5 * domeScale) / (6.2 * domeScale);\n"
    "      float topEnv = exp(-qTop * qTop) * upperFace * smoothstep(0.55, 1.80, inward);\n"
    "      dropRes *= (1.0 - mix(0.20, 0.082, brightBg) * roleVol * sizeGate * pressAmt * topEnv);\n"
    "      float sideArc = pow(max(abs(surfaceNormal.x), 0.0), 1.6);\n"
    "      float sideEnv = exp(-max(inward - 1.5, 0.0) / 4.2) * smoothstep(0.25, 1.20, inward);\n"
    "      dropRes *= (1.0 - mix(0.16, 0.065, brightBg) * (isRoleSeg ? 0.55 : (isRoleTab ? 0.45 : 1.0)) * sizeGate * pressAmt * sideArc * sideEnv);\n"
    "      float lowerFace = smoothstep(0.10, 0.85, surfaceNormal.y);\n"
    "      float lowEnv = exp(-max(inward - 2.0, 0.0) / 5.5) * smoothstep(0.50, 1.60, inward);\n"
    "      dropRes = clamp(dropRes + vec3(mix(0.032, 0.025, brightBg) * lowerFace * lowEnv * (isRoleSeg ? 0.45 : (isRoleTab ? 0.35 : 1.0)) * sizeGate * pressAmt), 0.0, 1.0);\n"
    "      // Stage A: Razor-sharp inner 3D specular rim\n"
    "      if (pressAmt > 0.001 && inward < 12.0) {\n"
    "        float litTop = max(-surfaceNormal.y, 0.0);\n"
    "        float litBot = max(surfaceNormal.y, 0.0);\n"
    "        float dirLobe = 0.96 * (litTop * litTop * litTop) + 1.00 * (litBot * litBot * litBot) + 0.05;\n"
    "        float rimStart = isRoleSw ? 0.60 : 0.45;\n"
    "        float rimPeak  = isRoleSw ? 0.95 : 0.75;\n"
    "        float rimRise = smoothstep(rimStart, rimPeak, inward);\n"
    "        float rimInset = max(inward - rimPeak, 0.0);\n"
    "        float rimEnv = rimRise * (0.90 * exp(-rimInset / 0.38) + 0.14 * exp(-rimInset / 1.50));\n"
    "        float rimStr = mix(0.24, 0.14, brightBg) * dirLobe * rimEnv * pressAmt;\n"
    "        dropRes = mix(dropRes, vec3(1.0), clamp(rimStr, 0.0, 1.0));\n"
    "      }\n"
    "      // Stage B: Slim Apple-exact closed-form analytic 3D bevel wall\n"
    "      float across = pow(max(1.0 - surfaceNormal.y * surfaceNormal.y, 0.0), 1.35);\n"
    "      float invS = 1.0 / max(u_scale, 1.0);\n"
    "      float hsWall = clamp(halfMinor / 19.2, 0.72, 1.25);\n"
    "      float w0_top = (isRoleSw ? 0.30 : 0.24) * hsWall;\n"
    "      float w0_side = max(0.52 * hsWall, 1.55 * invS);\n"
    "      float w0_eff = mix(w0_top, w0_side, across);\n"
    "      float L_eff  = mix(0.12, 0.42, across) * hsWall;\n"
    "      float wallCov = mb_bevel_cov(sd_px, u_scale, w0_eff, L_eff);\n"
    "      float wallBlend = clamp(wallCov / max(materialAlpha, 0.001), 0.0, 1.0) * 0.94 * pressAmt;\n"
    "      if (wallBlend > 0.001) {\n"
    "        vec3 envBg = backdrop(p + surfaceNormal * 1.2);\n"
    "        float envY = luma(envBg);\n"
    "        float envChroma = max(envBg.r, max(envBg.g, envBg.b)) - min(envBg.r, min(envBg.g, envBg.b));\n"
    "        float brightEnv = smoothstep(0.35, 0.75, envY);\n"
    "        float satEnv = smoothstep(0.10, 0.35, envChroma);\n"
    "        float neutralMul = mix(0.26, mix(0.80, 0.72, across), brightEnv);\n"
    "        vec3 neutralTint = envBg * neutralMul;\n"
    "        vec3 satTint = pow(max(envBg, vec3(0.0001)), vec3(1.25)) * 0.72;\n"
    "        dropRes = mix(dropRes, mix(neutralTint, satTint, satEnv), wallBlend);\n"
    "      }\n"
    "      // Stage C: Segmented prismatic edge dispersion AFTER Stage B\n"
    "      if (pressAmt > 0.001 && inward < 12.0 && abs(v_pad.z) > 0.005) {\n"
    "        float chromaGate = smoothstep(0.005, 0.04, abs(v_pad.z));\n"
    "        float pBand = smoothstep(0.45, 0.75, inward) * (1.0 - smoothstep(1.35, 2.20, inward)) * pressAmt * chromaGate;\n"
    "        float hw = smoothstep(0.35, 0.85, abs(surfaceNormal.x));\n"
    "        vec3 pDark = mix(vec3(-0.025, 0.015, 0.045), vec3(0.048, 0.012, -0.032), hw);\n"
    "        vec3 pLight = mix(vec3(-0.085, 0.0, 0.0), vec3(-0.015, -0.075, -0.135), hw);\n"
    "        vec3 pAdd = mix(pDark, pLight, brightBg);\n"
    "        dropRes = clamp(dropRes + pAdd * pBand, 0.0, 1.0);\n"
    "      }\n"
    "      result = mix(result, dropRes, droplet);\n"
    "    } else if (is_drop) {\n"
    "      float backdropLuma = clamp(Y, 0.0, 1.0);\n"
    "      float brightBg = smoothstep(0.35, 0.75, backdropLuma);\n"
    "      float liftGain = isRoleTab ? 0.025 : (isRoleSeg ? 0.008 : 0.101);\n"
    "      float lensLift = liftGain * pressAmt * (1.0 - backdropLuma) * (1.0 - dropHairline);\n"
    "      result = clamp(result + vec3(lensLift), 0.0, 1.0);\n"
    "      float domeScale = clamp(v_rect.w / 38.0, 0.85, 1.35);\n"
    "      float sizeGate = smoothstep(28.0, 36.0, v_rect.w);\n"
    "      float upperFace = smoothstep(0.0, 0.75, -surfaceNormal.y);\n"
    "      float qDome = (inward - 9.2 * domeScale) / (5.6 * domeScale);\n"
    "      float domeEnv = exp(-qDome * qDome) * upperFace * smoothstep(0.65, 1.85, inward);\n"
    "      float domeStr = mix(0.196, 0.086, brightBg) * sizeGate;\n"
    "      result *= (1.0 - domeStr * domeEnv * pressAmt);\n"
    "      float lightSh = smoothstep(0.75, 1.80, inward) * (1.0 - smoothstep(4.5, 8.5, inward))\n"
    "                    * upperFace * brightBg * sizeGate;\n"
    "      result *= (1.0 - 0.032 * lightSh * pressAmt);\n"
    "      if (pressAmt > 0.001 && inward < 12.0) {\n"
    "        float along = surfaceNormal.y;\n"
    "        float lit = max(along, 0.0);\n"
    "        float opp = max(-along, 0.0);\n"
    "        float lobe = 1.0 * (lit * lit * lit) + 1.0 * (opp * opp * opp) + 0.14;\n"
    "        float insetPt = max(0.0, inward - 0.60);\n"
    "        float core = exp(-insetPt / 0.48);\n"
    "        float shoulder = exp(-insetPt / 1.8);\n"
    "        float ease = pow(max(1.0 - clamp(luma(result), 0.0, 1.0), 0.0), 0.30);\n"
    "        float rimGain = isRoleSeg ? 0.85 : (isRoleTab ? 0.75 : 1.0);\n"
    "        float rimLight = pressAmt * rimGain * lobe * ease * (0.205 * core + 0.025 * shoulder) * (1.0 - dropHairline);\n"
    "        result = mix(result, vec3(1.0), clamp(rimLight, 0.0, 1.0));\n"
    "      }\n"
    "      if (isRoleSeg && pressAmt > 0.01) {\n"
    "        float prismBand = smoothstep(0.40, 0.80, inward) * (1.0 - smoothstep(1.15, 1.85, inward))\n"
    "                        * (1.0 - dropHairline) * pressAmt;\n"
    "        if (prismBand > 0.001) {\n"
    "          float hW = smoothstep(0.35, 0.85, abs(surfaceNormal.x));\n"
    "          vec3 rawD = mix(vec3(-0.045, 0.015, 0.030), vec3(0.075, -0.015, -0.060), hW);\n"
    "          vec3 darkPrism = (rawD - vec3(luma(rawD))) * 0.60 * prismBand;\n"
    "          vec3 lightPrism = mix(vec3(-0.068, 0.0, 0.0), vec3(-0.055, -0.148, -0.188), hW) * prismBand;\n"
    "          vec3 pD = mix(darkPrism, lightPrism, brightBg);\n"
    "          float sP = 1.0;\n"
    "          if (pD.r > 0.0001) sP = min(sP, (1.0 - result.r) / pD.r); else if (pD.r < -0.0001) sP = min(sP, result.r / (-pD.r));\n"
    "          if (pD.g > 0.0001) sP = min(sP, (1.0 - result.g) / pD.g); else if (pD.g < -0.0001) sP = min(sP, result.g / (-pD.g));\n"
    "          if (pD.b > 0.0001) sP = min(sP, (1.0 - result.b) / pD.b); else if (pD.b < -0.0001) sP = min(sP, result.b / (-pD.b));\n"
    "          result = clamp(result + pD * clamp(sP, 0.0, 1.0), 0.0, 1.0);\n"
    "        }\n"
    "      }\n"
    "      if (dropHairline > 0.001) {\n"
    "        float across = pow(max(1.0 - surfaceNormal.y * surfaceNormal.y, 0.0), 1.75);\n"
    "        float shadeTB = mix(0.047, 0.161, brightBg);\n"
    "        float shadeEnds = mix(0.063, 0.239, brightBg);\n"
    "        float shade = mix(shadeTB, shadeEnds, across) * pressAmt;\n"
    "        result = max(result - vec3(shade * dropHairline), vec3(0.0));\n"
    "      }\n"
    "    }\n"
    "    result = clamp(result + mb_dither(p * u_scale) / 255.0, 0.0, 1.0);\n"
    "    // (c) External 0.75pt dark contour (concentrated perpendicular to light axis where glint fades)\n"
    "    float contourDir = mix(1.0, tangency, contourDirAmt);\n"
    "    float extA = ext_cov * contourStr * contourDir * v_c2.w;\n"
    "    float visA = materialAlpha * v_c2.w;\n"
    "    o = vec4(result * visA, clamp(visA + extA, 0.0, 1.0));\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS(8)\n"
    "  if (kind == 8) {\n"
    "    vec4 s_rr = max(max(v_rr.x, v_rr.y), max(v_rr.z, v_rr.w)) > 0.0 ? v_rr : vec4(v_p.x);\n"
    "    float d = sd_rr(p, v_rect, s_rr);\n"
    "    float materialAlpha = clamp(0.5 - d * u_scale, 0.0, 1.0);\n"
    "    if (materialAlpha < 0.005) discard;\n"
    "    float halfMinor = max(min(v_rect.z, v_rect.w) * 0.5, 1.0);\n"
    "    float inward = max(-d, 0.0);\n"
    "    float rawBevel = max(v_c2.y, 0.0);\n"
    "    float rawAmount = max(v_c2.z, 0.0);\n"
    "    float lensScale = min(1.0, halfMinor / max(rawBevel, 0.001));\n"
    "    float bevel = rawBevel * lensScale;\n"
    "    float amount = rawAmount * lensScale;\n"
    "    vec2 disp = vec2(0.0, 0.0);\n"
    "    if (inward < bevel && bevel > 0.001 && amount > 0.001) {\n"
    "      float e = 0.5;\n"
    "      vec2 grad = vec2(\n"
    "        sd_rr(p + vec2(e, 0.0), v_rect, s_rr) - sd_rr(p - vec2(e, 0.0), v_rect, s_rr),\n"
    "        sd_rr(p + vec2(0.0, e), v_rect, s_rr) - sd_rr(p - vec2(0.0, e), v_rect, s_rr)\n"
    "      ) / (2.0 * e);\n"
    "      float gradLen = length(grad);\n"
    "      vec2 surfaceNormal = gradLen > 0.0001 ? grad / gradLen : vec2(0.0, 0.0);\n"
    "      float shortening = sqrt(clamp(gradLen, 0.0, 1.0));\n"
    "      float bevelX = 1.0 - clamp(inward / bevel, 0.0, 1.0);\n"
    "      float mag = amount * (1.0 - sqrt(max(1.0 - bevelX * bevelX, 0.0))) * shortening;\n"
    "      disp = surfaceNormal * (-mag);\n"
    "    }\n"
    "    vec2 uv = (p + disp) * u_map.xy + u_map.zw;\n"
    "    vec4 fg = vec4(0.0);\n"
    "    if (uv.x >= u_uvc.x && uv.x <= u_uvc.z && uv.y >= u_uvc.y && uv.y <= u_uvc.w) {\n"
    "      fg = texture(u_bd, uv);\n"
    "    }\n"
    "    o = fg * (materialAlpha * col.a);\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS_BOX\n"
    "  vec2 hs = v_rect.zw * 0.5;\n"
    "  vec2 c = v_rect.xy + hs;\n"
    "  // worked out as near the curve as its cover, its edge or its blur reaches\n"
    "  float band = 1.0 + 2.0 / u_scale + (kind == 2 ? max(v_p.w, 0.5) : max(v_p.z, 0.0));\n"
    "  // (its corner by p: v_rr, each its own)\n"
    "  float rad = mb_corner_of(p - c, v_rr);\n"
    "  float d = mb_sd_box(p - c, hs, rad, band);\n"
    "#if MB_HAS(0) || MB_HAS(5)\n"
    "  if ((kind == 0 && v_pad.w >= 0.0) || kind == 5) d = notch_cut(d, p, v_rect, v_pad);\n"
    "#endif\n"
    "#if MB_HAS(4)\n"
    "  if (kind == 4) {\n"
    "    vec2 uv = v_c2.xy + clamp((p - v_rect.xy) / v_rect.zw, 0.0, 1.0) * v_c2.zw;\n"
    "    vec4 pic = texture(u_img, clamp(uv, 0.0, 1.0));\n"
    "    float edge = clamp(0.5 - d * u_scale, 0.0, 1.0);\n"
    "    if (v_pad.z > 0.5) {\n"
    "      // Only picture edges inside the frame cut it; the frame's clip covers shared edges once.\n"
    "      vec2 size = v_rect.zw / v_c2.zw, lo = v_rect.xy - v_c2.xy * size, hi = lo + size;\n"
    "      vec2 a = lo - p, b = p - hi;\n"
    "      if (v_c2.x >= 0.0) a.x = -1e9; if (v_c2.y >= 0.0) a.y = -1e9;\n"
    "      if (v_c2.x + v_c2.z <= 1.0) b.x = -1e9; if (v_c2.y + v_c2.w <= 1.0) b.y = -1e9;\n"
    "      vec2 q = max(a, b);\n"
    "      float pd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);\n"
    "      pic *= v_pad.w * clamp(0.5 - pd * u_scale, 0.0, 1.0);\n"
    "      pic += vec4(col.rgb * v_pad.y, v_pad.y) * (1.0 - pic.a);\n"
    "      if (v_pad.x < 0.5 && max(max(v_rr.x, v_rr.y), max(v_rr.z, v_rr.w)) <= 0.0 &&\n"
    "          max(max(v_rc.x, v_rc.y), max(v_rc.z, v_rc.w)) > 0.0 &&\n"
    "          all(greaterThanEqual(v_clip.xy, v_rect.xy)) && all(lessThanEqual(v_clip.zw, v_rect.xy + v_rect.zw))) edge = 1.0;\n"
    "    }\n"
    "    o = pic * (col.a * edge);\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS(2)\n"
    "  if (kind == 2) {\n"
    "    // as Core Animation's: the shape blurred, sigma its radius (corner.sl mb_shadow)\n"
    "    float a = mb_shadow(p - c, hs, rad, max(v_p.w, 0.25));\n"
    "    // glass's: only outside its box (c2.y above it)\n"
    "    if (v_c2.x > 0.5) {\n"
    "      vec2 q = p - c + vec2(0.0, v_c2.y);\n"
    "      float db = mb_sd_box(q, hs, mb_corner_of(q, v_rr), band);\n"
    "      a *= clamp(0.5 + db * u_scale, 0.0, 1.0);\n"
    "    }\n"
    "    o = vec4(col.rgb, 1.0) * col.a * a;\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS(0) || MB_HAS(5)\n"
    "  float a = clamp(0.5 - d * u_scale, 0.0, 1.0);\n"
    "#endif\n"
    "#if MB_HAS(5)\n"
    "  if (kind == 5) {\n"
    "    // frosted: the blurred copy, saturated, the tint over it; the rim (a hairline inside the edge, the top left lit,\n"
    "    // the foot and right less), 0.5 wide\n"
    "    bool prog_glass = (v_pad.z < -0.5);\n"
    "    vec3 g3 = backdrop(p);\n"
    "    float fr_s = fade_r * fade_r * (3.0 - 2.0 * fade_r);\n"
    "    float ps = prog_glass ? fr_s : 1.0;\n"
    "    float ts = prog_glass ? fr_s : 1.0;\n"
    "    float sat = prog_glass ? mix(1.0, v_p.z, ps) : v_p.z;\n"
    "    float bg_diff = (prog_glass && col.a > 0.001) ? smoothstep(0.22, 0.72, abs(luma(col.rgb) - luma(g3))) : 0.0;\n"
    "    float base_a = (prog_glass && col.a > 0.001) ? mix(col.a, min(0.86, col.a + 0.34), bg_diff) : col.a;\n"
    "    float ta = prog_glass ? (base_a * ts) : col.a;\n"
    "    g3 = max(mix(vec3(luma(g3)), g3, sat), 0.0);\n"
    "    g3 = g3 * (1.0 - ta) + col.rgb * ta;\n"
    "    if (v_c2.x + v_c2.y + v_c2.z > 0.0) {\n"
    "      float edge = clamp(0.5 + (d + 0.5) * u_scale, 0.0, 1.0);\n"
    "      float lit = clamp(0.5 + notch_cut(sd_rr(p - 0.5, v_rect, v_rr), p - 0.5, v_rect, v_pad) * u_scale, 0.0, 1.0);\n"
    "      float back = clamp(0.5 + notch_cut(sd_rr(p + 0.5, v_rect, v_rr), p + 0.5, v_rect, v_pad) * u_scale, 0.0, 1.0);\n"
    "      g3 = mix(g3, vec3(1.0), v_c2.x * edge);\n"
    "      g3 = mix(g3, vec3(1.0), v_c2.y * lit);\n"
    "      g3 = mix(g3, vec3(1.0), v_c2.z * back);\n"
    "    }\n"
    "    // dithered as it is written to 8 bits, so its slopes do not band (corner.sl mb_dither)\n"
    "    g3 += mb_dither(p * u_scale) * ps / 255.0;\n"
    "    float edge_a = prog_glass ? smoothstep(0.0, 0.04, fade_r) : 1.0;\n"
    "    o = vec4(g3, 1.0) * (a * v_c2.w * edge_a);\n"
    "    return;\n"
    "  }\n"
    "#endif\n"
    "#if MB_HAS(0)\n"
    "  vec4 fill = vec4(col.rgb, 1.0) * col.a;\n"
    "  if (v_p.z > 0.0) {\n"
    "    float inner = clamp(0.5 - (d + v_p.z) * u_scale, 0.0, 1.0);\n"
    "    vec4 bc = vec4(v_c2.rgb, 1.0) * v_c2.a;\n"
    "    fill = mix(bc, fill, inner);\n"
    "  }\n"
    "  o = fill * a;\n"
    "#endif\n"
    "#endif\n"
    "#endif\n"
    "}\n"
    "// cut to its clip: a rect's, hard; a rounded one's, covered as edges are\n"
    "void main() {\n"
    "  vec2 p = v_pos, cp = v_cpos;\n"
    "  float cover = 1.0;\n"
    "  if (max(max(v_rc.x, v_rc.y), max(v_rc.z, v_rc.w)) > 0.0) {\n"
    "    cover = clip_cover(cp, v_clip, v_rc, v_rs, u_scale);\n"
    "    if (cover <= 0.0) discard;\n"
    "  } else if (cp.x < v_clip.x || cp.y < v_clip.y || cp.x > v_clip.z || cp.y > v_clip.w) discard;\n"
    "  // and by the clip outside it, where it has one (scene.mbt 40-51: a pane round an image's frame in its corner)\n"
    "  if (max(max(v_orc.x, v_orc.y), max(v_orc.z, v_orc.w)) > 0.0) {\n"
    "    cover *= clip_cover(cp, v_oclip, v_orc, v_ors, u_scale);\n"
    "    if (cover <= 0.0) discard;\n"
    "  }\n"
    "  // and faded out towards a cut, each pixel by where it is (scene.mbt 52-59)\n"
    "  vec4 ramp = clamp(v_ramp, 0.0, 1.0);\n"
    "  float fade_r = ramp.x * ramp.y * ramp.z * ramp.w;\n"
    "  if (fade_r <= 0.0) discard;\n"
    "#if MB_HAS(5)\n"
    "  int kind = ONE_KIND >= 0 ? ONE_KIND : int(v_p.y + 0.5);\n"
    "  bool prog_glass = (kind == 5 && v_pad.z < -0.5);\n"
    "  if (!prog_glass) {\n"
    "    cover *= fade_r;\n"
    "    if (cover <= 0.0) discard;\n"
    "  }\n"
    "#else\n"
    "  cover *= fade_r;\n"
    "  if (cover <= 0.0) discard;\n"
    "#endif\n"
    "  shade(p, fade_r);\n"
    "  o *= cover;\n"
    "}\n";

// glass's passes over its copy of what is under it
// the flat pipeline: a ground's colour where it is covered whole, cut by straight clips alone (bands.h mb_pieces): what
// FS writes there, nothing worked out
static const char *FS_FLAT =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp int;\n"
    "flat in vec4 v_color;\n"
    "out vec4 o;\n"
    "void main() { o = vec4(v_color.rgb, 1.0) * v_color.a; }\n";

static const char *PVS =
    "#version 300 es\n"
    "void main() {\n"
    "  gl_Position = vec4(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0, 0.0, 1.0);\n"
    "}\n";

static const char *PFS =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp int;\n"
    "#define float2 vec2\n"
    "#define float4 vec4\n"
    MB_CORNER_SL
    "// The backdrop's passes: u_a.xy the source's texel, u_a.z 1 halving (dual Kawase's down), 2 a Gaussian along u_b.zw\n"
    "// of deviation u_a.w (texels); u_b.xy the last texel's centre of what the source holds\n"
    "uniform highp sampler2D u_src;\n"
    "uniform highp sampler2D u_lv1;\n"
    "uniform highp sampler2D u_lv2;\n"
    "uniform highp sampler2D u_lv3;\n"
    "uniform vec4 u_a;\n"
    "uniform vec4 u_b;\n"
    "uniform vec4 u_c[9];\n"
    "out vec4 o;\n"
    "void main() {\n"
    "  vec2 ts = u_a.xy;\n"
    "  vec2 lo = ts * 0.5, hi = u_b.xy;\n"
    "  if (u_a.z > 3.5) {\n"
    "    vec2 p = u_c[0].xy + gl_FragCoord.xy * u_c[0].zw;\n"
    "    float ramp = 1.0;\n"
    "    if (u_c[1].y > 0.0) ramp *= clamp((p.y - u_c[1].x) / u_c[1].y, 0.0, 1.0);\n"
    "    if (u_c[1].w > 0.0) ramp *= clamp((u_c[1].z - p.y) / u_c[1].w, 0.0, 1.0);\n"
    "    if (u_c[2].y > 0.0) ramp *= clamp((p.x - u_c[2].x) / u_c[2].y, 0.0, 1.0);\n"
    "    if (u_c[2].w > 0.0) ramp *= clamp((u_c[2].z - p.x) / u_c[2].w, 0.0, 1.0);\n"
    "    float sp = max(u_c[3].x, 1.0);\n"
    "    float kf = u_c[3].y;\n"
    "    vec4 m0 = u_c[4], m1 = u_c[5], m2 = u_c[6], m3 = u_c[7];\n"
    "    if (kf < 0.5) { o = texture(u_src, clamp(gl_FragCoord.xy * m0.xy, m0.xy * 0.5, m0.zw)); return; }\n"
    "    float r = clamp(ramp, 0.0, 1.0);\n"
    "    if (r <= 0.0) { o = texture(u_src, clamp(gl_FragCoord.xy * m0.xy, m0.xy * 0.5, m0.zw)); return; }\n"
    "    if (r >= 1.0) {\n"
    "      int ki = int(kf + 0.5);\n"
    "      if (ki <= 1) o = texture(u_lv1, clamp(gl_FragCoord.xy * m1.xy, m1.xy * 1.0, m1.zw));\n"
    "      else if (ki == 2) o = texture(u_lv2, clamp(gl_FragCoord.xy * m2.xy, m2.xy * 2.0, m2.zw));\n"
    "      else o = texture(u_lv3, clamp(gl_FragCoord.xy * m3.xy, m3.xy * 4.0, m3.zw));\n"
    "      return;\n"
    "    }\n"
    "    float sig1 = pow(sp, 1.0 / kf);\n"
    "    // the blur grows as the square of the way into the fade, not smoothstep's 3r^2 - 2r^3: words are unreadable from\n"
    "    // a deviation of 1-2 pt, so smoothstep's quick start left two thirds of the band one flat frost\n"
    "    float rs = r * r;\n"
    "    float target_px = sp * rs;\n"
    "    if (target_px <= sig1 || kf <= 1.05) {\n"
    "      vec2 uv0_min = m0.xy * 0.5, uv0_max = m0.zw;\n"
    "      vec2 c_uv = gl_FragCoord.xy * m0.xy;\n"
    "      vec4 g_small;\n"
    "      if (target_px <= 0.01) {\n"
    "        g_small = texture(u_src, clamp(c_uv, uv0_min, uv0_max));\n"
    "      } else if (target_px <= 0.55) {\n"
    "        // Exact separable 3x3 Gaussian via 2x2 bilinear taps (center weight 0.5 split across +-o1)\n"
    "        float inv2 = -0.5 / (target_px * target_px);\n"
    "        float w1 = exp(inv2);\n"
    "        float o1 = w1 / (0.5 + w1);\n"
    "        vec2 ox = vec2(o1, 0.0) * m0.xy;\n"
    "        vec2 oy = vec2(0.0, o1) * m0.xy;\n"
    "        g_small = (texture(u_src, clamp(c_uv - ox - oy, uv0_min, uv0_max)) +\n"
    "                   texture(u_src, clamp(c_uv + ox - oy, uv0_min, uv0_max)) +\n"
    "                   texture(u_src, clamp(c_uv - ox + oy, uv0_min, uv0_max)) +\n"
    "                   texture(u_src, clamp(c_uv + ox + oy, uv0_min, uv0_max))) * 0.25;\n"
    "      } else {\n"
    "        // Exact separable 7x7 Gaussian via 4x4 bilinear taps (zero gaps, zero comb ghosting)\n"
    "        float inv2 = -0.5 / (target_px * target_px);\n"
    "        float w1 = exp(inv2);\n"
    "        float w2 = exp(4.0 * inv2);\n"
    "        float w3 = exp(9.0 * inv2);\n"
    "        float W1 = 0.5 + w1;\n"
    "        float W2 = w2 + w3;\n"
    "        float o1 = w1 / W1;\n"
    "        float o2 = (2.0 * w2 + 3.0 * w3) / max(W2, 1e-6);\n"
    "        float inv_sum = 0.5 / (W1 + W2);\n"
    "        float p1 = W1 * inv_sum;\n"
    "        float p2 = W2 * inv_sum;\n"
    "        float ox[4] = float[4](-o2, -o1, o1, o2);\n"
    "        float pw[4] = float[4](p2, p1, p1, p2);\n"
    "        g_small = vec4(0.0);\n"
    "        for (int iy = 0; iy < 4; iy++) {\n"
    "          vec4 row = vec4(0.0);\n"
    "          float uy = clamp(c_uv.y + ox[iy] * m0.y, uv0_min.y, uv0_max.y);\n"
    "          for (int ix = 0; ix < 4; ix++) {\n"
    "            float ux = clamp(c_uv.x + ox[ix] * m0.x, uv0_min.x, uv0_max.x);\n"
    "            row += texture(u_src, vec2(ux, uy)) * pw[ix];\n"
    "          }\n"
    "          g_small += row * pw[iy];\n"
    "        }\n"
    "      }\n"
    "      float blend_lo = min(1.1, sig1 * 0.45);\n"
    "      float bt = clamp((target_px - blend_lo) / max(sig1 - blend_lo, 1e-4), 0.0, 1.0);\n"
    "      float blend1 = bt > 0.0 ? pow(bt, 1.8) : 0.0;\n"
    "      if (blend1 > 0.0) {\n"
    "        vec4 c_lv1 = texture(u_lv1, clamp(gl_FragCoord.xy * m1.xy, m1.xy * 1.0, m1.zw));\n"
    "        o = mix(g_small, c_lv1, blend1);\n"
    "      } else {\n"
    "        o = g_small;\n"
    "      }\n"
    "      return;\n"
    "    }\n"
    "    float lv_u = clamp(1.0 + (kf - 1.0) * log(target_px / sig1) / max(log(sp / sig1), 1e-4), 1.0, kf);\n"
    "    int idx = min(int(floor(lv_u)), int(kf + 0.5) - 1);\n"
    "    if (idx < 0) idx = 0;\n"
    "    float f = lv_u - float(idx);\n"
    "    vec4 c0, c1;\n"
    "    if (idx == 0) {\n"
    "      c0 = texture(u_src, clamp(gl_FragCoord.xy * m0.xy, m0.xy * 0.5, m0.zw));\n"
    "      c1 = texture(u_lv1, clamp(gl_FragCoord.xy * m1.xy, m1.xy * 1.0, m1.zw));\n"
    "    } else if (idx == 1) {\n"
    "      c0 = texture(u_lv1, clamp(gl_FragCoord.xy * m1.xy, m1.xy * 1.0, m1.zw));\n"
    "      c1 = texture(u_lv2, clamp(gl_FragCoord.xy * m2.xy, m2.xy * 2.0, m2.zw));\n"
    "    } else {\n"
    "      c0 = texture(u_lv2, clamp(gl_FragCoord.xy * m2.xy, m2.xy * 2.0, m2.zw));\n"
    "      c1 = texture(u_lv3, clamp(gl_FragCoord.xy * m3.xy, m3.xy * 4.0, m3.zw));\n"
    "    }\n"
    "    o = mix(c0, c1, f);\n"
    "    return;\n"
    "  }\n"
    "  if (u_a.z > 2.5) {\n"
    "    vec2 p = u_c[0].xy + gl_FragCoord.xy * u_c[0].zw;\n"
    "    p = mb_contained_point(p, u_c[1], u_c[2], u_c[3], u_c[4], u_c[5], u_c[6], u_c[7], u_c[8], u_c[0].z);\n"
    "    o = texture(u_src, clamp((p - u_c[0].xy) / u_c[0].zw * ts, lo, hi));\n"
    "    return;\n"
    "  }\n"
    "  if (u_a.z < 1.5) {\n"
    "    vec2 uv = gl_FragCoord.xy * 2.0 * ts;\n"
    "    vec4 s = texture(u_src, clamp(uv, lo, hi)) * 4.0;\n"
    "    s += texture(u_src, clamp(uv - ts, lo, hi));\n"
    "    s += texture(u_src, clamp(uv + ts, lo, hi));\n"
    "    s += texture(u_src, clamp(uv + vec2(ts.x, -ts.y), lo, hi));\n"
    "    s += texture(u_src, clamp(uv + vec2(-ts.x, ts.y), lo, hi));\n"
    "    o = s / 8.0;\n"
    "    return;\n"
    "  }\n"
    "  vec2 uv = gl_FragCoord.xy * ts;\n"
    "  vec2 dir = u_b.zw * ts;\n"
    "  float sg = u_a.w;\n"
    "  float k = -0.5 / (sg * sg);\n"
    "  vec4 s = texture(u_src, clamp(uv, lo, hi));\n"
    "  float wsum = 1.0;\n"
    "  int n = int(ceil(sg * 3.0));\n"
    "  for (int i = 1; i <= 64; i += 2) {\n"
    "    if (i > n) break;\n"
    "    float w1 = exp(float(i * i) * k), w2 = exp(float((i + 1) * (i + 1)) * k);\n"
    "    float w = w1 + w2;\n"
    "    float off = (float(i) * w1 + float(i + 1) * w2) / w;\n"
    "    s += (texture(u_src, clamp(uv + dir * off, lo, hi)) + texture(u_src, clamp(uv - dir * off, lo, hi))) * w;\n"
    "    wsum += 2.0 * w;\n"
    "  }\n"
    "  o = s / wsum;\n"
    "}\n";

static const char *AD_FS =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp int;\n"
    "uniform highp sampler2D u_bd;\n"
    "uniform highp sampler2D u_prev;\n"
    "uniform vec4 u_map;\n"
    "uniform vec4 u_uvc;\n"
    "uniform vec4 u_box;\n"
    "uniform vec4 u_param;\n"
    "out vec4 o;\n"
    "float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    "float mb_ink_luma(vec3 c) { return dot(c * c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    "float mb_unpack16(vec2 rg) {\n"
    "  float hi = floor(clamp(rg.x, 0.0, 1.0) * 255.0 + 0.5);\n"
    "  float lo = floor(clamp(rg.y, 0.0, 1.0) * 255.0 + 0.5);\n"
    "  return (hi * 256.0 + lo) / 65535.0;\n"
    "}\n"
    "vec2 mb_pack16(float v) {\n"
    "  float q = floor(clamp(v, 0.0, 1.0) * 65535.0 + 0.5);\n"
    "  float hi = floor(q / 256.0);\n"
    "  float lo = q - hi * 256.0;\n"
    "  return vec2(hi / 255.0, lo / 255.0);\n"
    "}\n"
    "void main() {\n"
    "  vec2 c = u_box.xy, h = u_box.zw;\n"
    "  float sum = 0.0, mx1 = -1.0, mx2 = -1.0, mn1 = 2.0, mn2 = 2.0;\n"
    "  for (int iy = -1; iy <= 1; iy++) {\n"
    "    float py = c.y + float(iy) * (h.y * 0.60);\n"
    "    for (int ix = -2; ix <= 2; ix++) {\n"
    "      float px = c.x + float(ix) * (h.x * 0.38);\n"
    "      vec2 uv = clamp(vec2(px, py) * u_map.xy + u_map.zw, u_uvc.xy, u_uvc.zw);\n"
    "      float y = mb_ink_luma(texture(u_bd, uv).rgb);\n"
    "      sum += y;\n"
    "      if (y > mx1) { mx2 = mx1; mx1 = y; } else if (y > mx2) { mx2 = y; }\n"
    "      if (y < mn1) { mn2 = mn1; mn1 = y; } else if (y < mn2) { mn2 = y; }\n"
    "    }\n"
    "  }\n"
    "  float bgL = (sum - mx1 - mx2 - mn1 - mn2) / 11.0;\n"
    "  int sid = int(u_param.w + 0.5);\n"
    "  vec4 prev = texelFetch(u_prev, ivec2(sid, 0), 0);\n"
    "  float prevT = mb_unpack16(prev.rg);\n"
    "  float is_dark = u_param.x, is_new = u_param.y, dt = u_param.z;\n"
    "  float latch, target;\n"
    "  if (is_dark > 0.5) {\n"
    "    target = smoothstep(0.35, 0.85, bgL);\n"
    "    latch = target;\n"
    "  } else {\n"
    "    if (is_new > 0.5) latch = (bgL < 0.36) ? 1.0 : 0.0;\n"
    "    else if (prev.b > 0.5) latch = (bgL > 0.46) ? 0.0 : 1.0;\n"
    "    else latch = (bgL < 0.36) ? 1.0 : 0.0;\n"
    "    target = latch;\n"
    "  }\n"
    "  float nextT;\n"
    "  if (is_new > 0.5 || dt >= 1.0) nextT = target;\n"
    "  else if (dt <= 0.0) nextT = prevT;\n"
    "  else {\n"
    "    nextT = mix(prevT, target, 1.0 - exp(-dt / 0.070));\n"
    "    if (abs(nextT - target) < 0.003) nextT = target;\n"
    "  }\n"
    "  o = vec4(mb_pack16(nextT), latch, clamp(bgL, 0.0, 1.0));\n"
    "}\n";

static GLuint vao, vbo, atlas, catlas, post, ad_prog;
static GLuint vs_main, vs_main_ad, vs_post;
// a ground's flat middle (bands.h mb_pieces), and where its window's size goes
static GLuint prog_flat;
static GLint uf_vp;
static GLint pu_src, pu_lv1, pu_lv2, pu_lv3, pu_a, pu_b, pu_c;
static GLint adu_bd, adu_prev, adu_map, adu_uvc, adu_box, adu_param;

// Compact program groups: all regular UI primitives (rect, text, shadow, colour glyph, image, adaptive text,
// native-view hole, line) share one lean FS (zero glass/backdrop/adaptive/path-loop code; adaptive ink runs
// per-instance in the VS), keeping draw calls batched across mixed kinds while isolating the path-segment loop
// (kind 11) and heavy glass/lens shaders in their own specialized programs.
enum {
  MB_PROG_UI = 0,
  MB_PROG_PATH = 1,
  MB_PROG_FROSTED = 2,
  MB_PROG_LIQUID_MERGED = 3,
  MB_PROG_LIQUID_SINGLE = 4,
  MB_PROG_LENS = 5,
  MB_PROGS = 6
};

static int prog_group_of(int kind, float pad_w) {
  if (kind == 11) return MB_PROG_PATH;
  if (kind == 5) return MB_PROG_FROSTED;
  if (kind == 6) return pad_w > 0.0f ? MB_PROG_LIQUID_MERGED : MB_PROG_LIQUID_SINGLE;
  if (kind == 13) return MB_PROG_LIQUID_SINGLE;
  if (kind == 8) return MB_PROG_LENS;
  return MB_PROG_UI;
}

typedef struct {
  GLuint p;
  GLint vp, origin, scale, map, uvc, gb, shape, rad, n, glight, ad_box, ad_n;
  unsigned gen;
} kprog;
static kprog progs[MB_PROGS];
static unsigned prog_gen;
static GLuint prog_now;

// Optional on-disk GLES 3.0 program binary cache (glGetProgramBinary / glProgramBinary), keyed by driver strings,
// program group, and full VS/FS source SHA-256 so driver updates or shader edits invalidate automatically.
static char prog_cache_dir[512];
static int prog_bin_checked;
static int prog_bin_ok;
// (GL thread) what the cache did: programs loaded from it, compiled for want of one, written to it
static int prog_cache_hits;
static int prog_cache_misses;
static int prog_cache_stores;

static void gl_set_prog_cache_dir(const char *dir) {
  if (!dir || !dir[0]) {
    prog_cache_dir[0] = '\0';
    return;
  }
  snprintf(prog_cache_dir, sizeof prog_cache_dir, "%s", dir);
}

static int prog_bin_capable(void) {
  if (!prog_bin_checked) {
    GLint nfmt = 0;
    glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &nfmt);
    prog_bin_ok = nfmt > 0;
    prog_bin_checked = 1;
  }
  return prog_bin_ok;
}

typedef struct {
  uint32_t h[8];
  uint64_t len;
  uint8_t buf[64];
  size_t fill;
} mb_sha256_ctx;

static uint32_t mb_rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void mb_sha256_block(mb_sha256_ctx *c, const uint8_t b[64]) {
  static const uint32_t k[64] = {
      0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
      0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
      0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
      0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
      0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
      0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
      0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
      0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = ((uint32_t)b[i * 4] << 24) | ((uint32_t)b[i * 4 + 1] << 16) | ((uint32_t)b[i * 4 + 2] << 8) | b[i * 4 + 3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = mb_rotr32(w[i - 15], 7) ^ mb_rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = mb_rotr32(w[i - 2], 17) ^ mb_rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = c->h[0], bb = c->h[1], cc = c->h[2], d = c->h[3];
  uint32_t e = c->h[4], f = c->h[5], g = c->h[6], hh = c->h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = mb_rotr32(e, 6) ^ mb_rotr32(e, 11) ^ mb_rotr32(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    uint32_t t1 = hh + S1 + ch + k[i] + w[i];
    uint32_t S0 = mb_rotr32(a, 2) ^ mb_rotr32(a, 13) ^ mb_rotr32(a, 22);
    uint32_t maj = (a & bb) ^ (a & cc) ^ (bb & cc);
    uint32_t t2 = S0 + maj;
    hh = g; g = f; f = e; e = d + t1;
    d = cc; cc = bb; bb = a; a = t1 + t2;
  }
  c->h[0] += a; c->h[1] += bb; c->h[2] += cc; c->h[3] += d;
  c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += hh;
}

static void mb_sha256_init(mb_sha256_ctx *c) {
  c->h[0] = 0x6a09e667u; c->h[1] = 0xbb67ae85u; c->h[2] = 0x3c6ef372u; c->h[3] = 0xa54ff53au;
  c->h[4] = 0x510e527fu; c->h[5] = 0x9b05688cu; c->h[6] = 0x1f83d9abu; c->h[7] = 0x5be0cd19u;
  c->len = 0;
  c->fill = 0;
}

static void mb_sha256_update(mb_sha256_ctx *c, const void *data, size_t n) {
  const uint8_t *p = (const uint8_t *)data;
  c->len += n;
  while (n > 0) {
    size_t take = 64 - c->fill;
    if (take > n) take = n;
    memcpy(c->buf + c->fill, p, take);
    c->fill += take;
    p += take;
    n -= take;
    if (c->fill == 64) {
      mb_sha256_block(c, c->buf);
      c->fill = 0;
    }
  }
}

static void mb_sha256_str(mb_sha256_ctx *c, const char *s) {
  if (!s) s = "";
  mb_sha256_update(c, s, strlen(s) + 1);
}

static void mb_sha256_hex(mb_sha256_ctx *c, char out[65]) {
  uint64_t bits = c->len * 8;
  uint8_t pad = 0x80;
  mb_sha256_update(c, &pad, 1);
  uint8_t zero = 0;
  while (c->fill != 56) mb_sha256_update(c, &zero, 1);
  uint8_t be[8];
  for (int i = 0; i < 8; i++) be[i] = (uint8_t)(bits >> (56 - i * 8));
  mb_sha256_update(c, be, 8);
  static const char hex[] = "0123456789abcdef";
  for (int i = 0; i < 8; i++) {
    for (int j = 0; j < 8; j++) out[i * 8 + j] = hex[(c->h[i] >> (28 - j * 4)) & 0xfu];
  }
  out[64] = '\0';
}

#define MB_GLBIN_MAGIC 0x4D424742u
#define MB_GLBIN_MAX_BYTES (16u * 1024u * 1024u)

static void prog_cache_path(char *out, size_t out_sz, const char *tag, const char *vs_head, const char *vs_body,
                            const char *fs_head, const char *fs_body) {
  mb_sha256_ctx ctx;
  mb_sha256_init(&ctx);
  mb_sha256_str(&ctx, "mbui-glbin-v1");
  mb_sha256_str(&ctx, (const char *)glGetString(GL_VENDOR));
  mb_sha256_str(&ctx, (const char *)glGetString(GL_RENDERER));
  mb_sha256_str(&ctx, (const char *)glGetString(GL_VERSION));
  mb_sha256_str(&ctx, tag);
  mb_sha256_str(&ctx, vs_head);
  mb_sha256_str(&ctx, vs_body);
  mb_sha256_str(&ctx, fs_head);
  mb_sha256_str(&ctx, fs_body);
  char digest[65];
  mb_sha256_hex(&ctx, digest);
  snprintf(out, out_sz, "%s/%s.glbin", prog_cache_dir, digest);
}

static GLuint prog_cache_load(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  uint32_t hdr[3] = {0, 0, 0};
  if (fread(hdr, sizeof(uint32_t), 3, f) != 3 || hdr[0] != MB_GLBIN_MAGIC || hdr[2] == 0 ||
      hdr[2] > MB_GLBIN_MAX_BYTES) {
    fclose(f);
    unlink(path);
    return 0;
  }
  uint8_t *buf = (uint8_t *)malloc(hdr[2]);
  if (!buf) {
    fclose(f);
    return 0;
  }
  size_t got = fread(buf, 1, hdr[2], f);
  int extra = fgetc(f);
  fclose(f);
  if (got != hdr[2] || extra != EOF) {
    free(buf);
    unlink(path);
    return 0;
  }
  GLuint p = glCreateProgram();
  glProgramBinary(p, (GLenum)hdr[1], buf, (GLsizei)hdr[2]);
  free(buf);
  GLint ok = 0;
  glGetProgramiv(p, GL_LINK_STATUS, &ok);
  while (glGetError() != GL_NO_ERROR) {
  }
  if (ok != GL_TRUE) {
    glDeleteProgram(p);
    unlink(path);
    return 0;
  }
  prog_cache_hits++;
  return p;
}

// (1: written)
static int prog_cache_save(const char *path, GLuint p) {
  GLint blen = 0;
  glGetProgramiv(p, GL_PROGRAM_BINARY_LENGTH, &blen);
  if (blen <= 0 || (uint32_t)blen > MB_GLBIN_MAX_BYTES) return 0;
  uint8_t *buf = (uint8_t *)malloc((size_t)blen);
  if (!buf) return 0;
  GLsizei got = 0;
  GLenum fmt = 0;
  glGetProgramBinary(p, blen, &got, &fmt, buf);
  if (got <= 0 || (uint32_t)got > MB_GLBIN_MAX_BYTES) {
    free(buf);
    return 0;
  }
  mkdir(prog_cache_dir, 0700);
  // (a name of its own: the GL thread and the one making programs ahead may write the same program's at once)
  static unsigned tmp_seq;
  char tmp[700];
  snprintf(tmp, sizeof tmp, "%s.%ld.%u.tmp", path, (long)getpid(), __atomic_fetch_add(&tmp_seq, 1, __ATOMIC_RELAXED));
  FILE *f = fopen(tmp, "wb");
  int saved = 0;
  if (f) {
    uint32_t hdr[3] = {MB_GLBIN_MAGIC, (uint32_t)fmt, (uint32_t)got};
    int ok = fwrite(hdr, sizeof(uint32_t), 3, f) == 3 && fwrite(buf, 1, (size_t)got, f) == (size_t)got;
    saved = fclose(f) == 0 && ok && rename(tmp, path) == 0;
    if (!saved) unlink(tmp);
  }
  free(buf);
  return saved;
}

static float *fbuf;
// the pieces of the frame's shapes (src/ui/shape.mbt: the instances of kind 12 after every one drawn), for the shader
// to read (u_segs): a float texture of SEGS_ROW fours a row (136 instances' 15), as many rows as they take
#define SEGS_ROW 2040
static GLuint segs_tex;
static int segs_rows;
// the pieces segs_tex holds (as they were uploaded): a frame whose pieces are the same (a part drawn again, a mark's
// look moving on) uploads none, the texture the GPU may still be drawing the last frame from not written again
static float *segs_had;
static size_t segs_had_n, segs_had_cap;
static size_t fcap;
static int fb_w, fb_h;
static double cur_w, cur_h, cur_scale;
// what is drawn into: the surface (0), or mbui-render's offscreen framebuffer (mb_render_init_offscreen)
static GLuint target_fb;

static void glass_lost(void);
static void canvas_lost(void);

// What the app does not paint left clear, what is under the surface showing (Android's over another app: OverActivity,
// Native.overOther).
static volatile int over_other;

static GLuint compile2(GLenum type, const char *head, const char *body, const char *label) {
  GLuint s = glCreateShader(type);
  if (head) {
    const char *srcs[2] = {head, body + strlen("#version 300 es\n")};
    glShaderSource(s, 2, srcs, NULL);
  } else {
    glShaderSource(s, 1, &body, NULL);
  }
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[2048];
    glGetShaderInfoLog(s, sizeof log, NULL, log);
    LOG("shader (%s): %s", label, log);
  }
  return s;
}

// The programs the renderer draws with: its groups (MB_PROG_*), then a ground's flat middle, the glass's passes' and the
// adaptive ink's; a slot each.
#define MB_SLOT_FLAT MB_PROGS
#define MB_SLOT_POST (MB_PROGS + 1)
#define MB_SLOT_ADAPTIVE (MB_PROGS + 2)
#define MB_SLOTS (MB_PROGS + 3)

// What the program of a slot is made of: its vertex shader (vs: 0 vs_main, 1 vs_main_ad, 2 vs_post, the one shared by
// the programs that have the same) and its fragment shader, each a head (NULL: none, the body's own #version) and body.
typedef struct {
  const char *tag, *vs_head, *vs_body, *fs_head, *fs_body;
  int vs;
} prog_src;

static prog_src prog_src_of(int slot, char *fs_head, size_t fs_head_n) {
  static const char *head_plain = "#version 300 es\n#define MB_VS_ADAPTIVE 0\n";
  static const char *head_ad = "#version 300 es\n#define MB_VS_ADAPTIVE 1\n";
  prog_src s = {"ui", head_plain, VS, fs_head, FS, 0};
  switch (slot) {
    case MB_SLOT_FLAT: {
      prog_src f = {"flat", head_plain, VS, NULL, FS_FLAT, 0};
      return f;
    }
    case MB_SLOT_POST: {
      prog_src f = {"post", NULL, PVS, NULL, PFS, 2};
      return f;
    }
    case MB_SLOT_ADAPTIVE: {
      prog_src f = {"adaptive", NULL, PVS, NULL, AD_FS, 2};
      return f;
    }
    case MB_PROG_FROSTED:
      s.tag = "frosted";
      snprintf(fs_head, fs_head_n,
               "#version 300 es\n"
               "#define ONE_KIND 5\n"
               "#define MB_HAS(K) ((K) == 5)\n"
               "#define MB_HAS_LIQUID 0\n"
               "#define MB_HAS_ADAPTIVE 0\n"
               "#define MB_HAS_BACKDROP 1\n"
               "#define MB_HAS_BOX 1\n"
               "#define MB_HAS_GROUP 0\n"
               "#define MB_LIQUID_SINGLE 0\n");
      break;
    case MB_PROG_LIQUID_MERGED:
      s.tag = "liquid_merged";
      snprintf(fs_head, fs_head_n,
               "#version 300 es\n"
               "#define ONE_KIND 6\n"
               "#define MB_HAS(K) ((K) == 6)\n"
               "#define MB_HAS_LIQUID 1\n"
               "#define MB_HAS_ADAPTIVE 1\n"
               "#define MB_HAS_BACKDROP 1\n"
               "#define MB_HAS_BOX 0\n"
               "#define MB_HAS_GROUP 1\n"
               "#define MB_LIQUID_SINGLE 0\n");
      break;
    case MB_PROG_LIQUID_SINGLE:
      s.tag = "liquid_single";
      snprintf(fs_head, fs_head_n,
               "#version 300 es\n"
               "#define ONE_KIND 13\n"
               "#define MB_HAS(K) ((K) == 6)\n"
               "#define MB_HAS_LIQUID 1\n"
               "#define MB_HAS_ADAPTIVE 1\n"
               "#define MB_HAS_BACKDROP 1\n"
               "#define MB_HAS_BOX 0\n"
               "#define MB_HAS_GROUP 0\n"
               "#define MB_LIQUID_SINGLE 1\n");
      break;
    case MB_PROG_LENS:
      s.tag = "lens";
      snprintf(fs_head, fs_head_n,
               "#version 300 es\n"
               "#define ONE_KIND 8\n"
               "#define MB_HAS(K) ((K) == 8)\n"
               "#define MB_HAS_LIQUID 0\n"
               "#define MB_HAS_ADAPTIVE 0\n"
               "#define MB_HAS_BACKDROP 1\n"
               "#define MB_HAS_BOX 0\n"
               "#define MB_HAS_GROUP 0\n"
               "#define MB_LIQUID_SINGLE 0\n");
      break;
    case MB_PROG_PATH:
      s.tag = "path";
      s.vs_head = head_ad;
      s.vs = 1;
      snprintf(fs_head, fs_head_n,
               "#version 300 es\n"
               "#define ONE_KIND 11\n"
               "#define MB_HAS(K) ((K) == 11)\n"
               "#define MB_HAS_LIQUID 0\n"
               "#define MB_HAS_ADAPTIVE 0\n"
               "#define MB_HAS_BACKDROP 0\n"
               "#define MB_HAS_BOX 0\n"
               "#define MB_HAS_GROUP 0\n"
               "#define MB_LIQUID_SINGLE 0\n");
      break;
    case MB_PROG_UI:
    default:
      s.vs_head = head_ad;
      s.vs = 1;
      snprintf(fs_head, fs_head_n,
               "#version 300 es\n"
               "#define ONE_KIND -1\n"
               "#define MB_HAS(K) ((K) == 0 || (K) == 1 || (K) == 2 || (K) == 3 || (K) == 4 || (K) == 7 || (K) == 9 || (K) == 10)\n"
               "#define MB_HAS_LIQUID 0\n"
               "#define MB_HAS_ADAPTIVE 0\n"
               "#define MB_HAS_BACKDROP 0\n"
               "#define MB_HAS_BOX 1\n"
               "#define MB_HAS_GROUP 0\n"
               "#define MB_LIQUID_SINGLE 0\n");
      break;
  }
  return s;
}

// Programs made ahead (a host that defines MB_PROGS_AHEAD: Android's). A new context draws its first frame, then the
// host starts a thread of its own with a context sharing this one's objects (progs_ahead_start), which links what the
// GL thread has none of yet (gl_progs_ahead below), the heavy glass first, and hands each over here as it is linked:
// a program the GL thread first needs (liquid glass bonding as it is first dragged, frosted glass as a panel first
// opens) is taken from here (ahead_take), not compiled in that frame, which a fresh install's or an update's first
// drag would wait a large share of a second for (the binary cache, prog_cache_load, keeps only what was linked before).
// A slot the GL thread made itself, or took, is claimed: the thread skips it, or lets go of what it made of it.
static pthread_mutex_t ahead_mu = PTHREAD_MUTEX_INITIALIZER;
// the context the programs are made ahead for (gl_setup's, counted), what of it was handed over, and claimed
static unsigned ahead_gen;
static GLuint ahead_progs[MB_SLOTS];
static unsigned ahead_claimed;
// (GL thread) a new context's: the thread started after its first frame (gl_present_kept)
static int ahead_due;

#ifdef MB_PROGS_AHEAD
// (the host's; GL thread, the context current) a thread started that makes the programs of `gen` ahead, in a context of
// its own sharing the current one's objects, by gl_progs_ahead
static void progs_ahead_start(unsigned gen);
#endif

// (GL thread) a new context's: what was handed over of the old one let go with it (made in the old context's objects)
static void ahead_reset(void) {
  pthread_mutex_lock(&ahead_mu);
  ahead_gen++;
  memset(ahead_progs, 0, sizeof ahead_progs);
  ahead_claimed = 0;
  pthread_mutex_unlock(&ahead_mu);
  ahead_due = 1;
}

// (GL thread) the program of `slot` made ahead, taken (0: none yet); the slot claimed either way
static GLuint ahead_take(int slot) {
  pthread_mutex_lock(&ahead_mu);
  GLuint p = ahead_progs[slot];
  ahead_progs[slot] = 0;
  ahead_claimed |= 1u << slot;
  pthread_mutex_unlock(&ahead_mu);
  return p;
}

static GLuint link_prog_impl(const char *tag, GLuint *vs_slot, const char *vs_head, const char *vs_body,
                             const char *fs_head, const char *fs_body, int cache_only) {
  char path[640];
  int use_cache = prog_cache_dir[0] != '\0' && prog_bin_capable();
  if (use_cache) {
    prog_cache_path(path, sizeof path, tag, vs_head, vs_body, fs_head, fs_body);
    GLuint cached = prog_cache_load(path);
    if (cached) return cached;
    if (cache_only) return 0;
    prog_cache_misses++;
  } else if (cache_only) {
    return 0;
  }
  if (!*vs_slot) *vs_slot = compile2(GL_VERTEX_SHADER, vs_head, vs_body, tag);
  GLuint fs = compile2(GL_FRAGMENT_SHADER, fs_head, fs_body, tag);
  GLuint p = glCreateProgram();
  if (use_cache) glProgramParameteri(p, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE);
  glAttachShader(p, *vs_slot);
  glAttachShader(p, fs);
  glLinkProgram(p);
  glDeleteShader(fs);
  if (use_cache) {
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (ok == GL_TRUE && prog_cache_save(path, p)) prog_cache_stores++;
  }
  return p;
}

// (GL thread) the program of `slot`: made ahead and handed over, else loaded from the binary cache, else (unless
// `cache_only`: 0) compiled now; claimed (ahead_take) when not only looked for in the cache
static GLuint slot_prog(int slot, int cache_only) {
  char fs_head[1024];
  prog_src s = prog_src_of(slot, fs_head, sizeof fs_head);
  if (!cache_only) {
    GLuint p = ahead_take(slot);
    if (p) {
      LOG("program %s taken as made ahead", s.tag);
      return p;
    }
  }
  GLuint *vs_slots[3] = {&vs_main, &vs_main_ad, &vs_post};
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  GLuint p = link_prog_impl(s.tag, vs_slots[s.vs], s.vs_head, s.vs_body, s.fs_head, s.fs_body, cache_only);
  if (p && cache_only) ahead_take(slot);
  // (what a frame waited for a program, in the host's log: a stall to be found there, not guessed at)
  if (p && !cache_only) {
    clock_gettime(CLOCK_MONOTONIC, &t1);
    LOG("program %s made on the GL thread in %.1f ms", s.tag,
        (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
  }
  return p;
}

// The program for `group` (MB_PROG_*), compiled (or loaded from binary cache, or taken as made ahead) on first use, its
// textures' units set.
static kprog make_prog_impl(int group, int cache_only) {
  GLuint p = slot_prog(group, cache_only);
  if (!p) {
    kprog empty = {0};
    return empty;
  }
  kprog k = {p};
  k.vp = glGetUniformLocation(k.p, "u_vp");
  k.origin = glGetUniformLocation(k.p, "u_origin");
  k.scale = glGetUniformLocation(k.p, "u_scale");
  k.map = glGetUniformLocation(k.p, "u_map");
  k.uvc = glGetUniformLocation(k.p, "u_uvc");
  k.gb = glGetUniformLocation(k.p, "u_gb");
  k.shape = glGetUniformLocation(k.p, "u_shape");
  k.rad = glGetUniformLocation(k.p, "u_rad");
  k.n = glGetUniformLocation(k.p, "u_n");
  k.glight = glGetUniformLocation(k.p, "u_glight");
  k.ad_box = glGetUniformLocation(k.p, "u_ad_box");
  k.ad_n = glGetUniformLocation(k.p, "u_ad_n");
  k.gen = prog_gen - 1;
  prog_now = k.p;
  glUseProgram(k.p);
  GLint loc;
  if ((loc = glGetUniformLocation(k.p, "u_atlas")) >= 0) glUniform1i(loc, 0);
  if ((loc = glGetUniformLocation(k.p, "u_img")) >= 0) glUniform1i(loc, 1);
  if ((loc = glGetUniformLocation(k.p, "u_bd")) >= 0) glUniform1i(loc, 2);
  if ((loc = glGetUniformLocation(k.p, "u_segs")) >= 0) glUniform1i(loc, 3);
  if ((loc = glGetUniformLocation(k.p, "u_catlas")) >= 0) glUniform1i(loc, 4);
  if ((loc = glGetUniformLocation(k.p, "u_ad")) >= 0) glUniform1i(loc, 5);
  return k;
}

static kprog make_prog(int group) { return make_prog_impl(group, 0); }

static void ensure_prog_flat_impl(int cache_only) {
  if (prog_flat) return;
  GLuint p = slot_prog(MB_SLOT_FLAT, cache_only);
  if (!p) return;
  prog_flat = p;
  uf_vp = glGetUniformLocation(prog_flat, "u_vp");
}

static void ensure_prog_flat(void) { ensure_prog_flat_impl(0); }

static void ensure_post_impl(int cache_only) {
  if (post) return;
  GLuint p = slot_prog(MB_SLOT_POST, cache_only);
  if (!p) return;
  post = p;
  pu_src = glGetUniformLocation(post, "u_src");
  pu_lv1 = glGetUniformLocation(post, "u_lv1");
  pu_lv2 = glGetUniformLocation(post, "u_lv2");
  pu_lv3 = glGetUniformLocation(post, "u_lv3");
  pu_a = glGetUniformLocation(post, "u_a");
  pu_b = glGetUniformLocation(post, "u_b");
  pu_c = glGetUniformLocation(post, "u_c");
}

static void ensure_post(void) { ensure_post_impl(0); }

static void ensure_ad_prog_impl(int cache_only) {
  if (ad_prog) return;
  GLuint p = slot_prog(MB_SLOT_ADAPTIVE, cache_only);
  if (!p) return;
  ad_prog = p;
  adu_bd = glGetUniformLocation(ad_prog, "u_bd");
  adu_prev = glGetUniformLocation(ad_prog, "u_prev");
  adu_map = glGetUniformLocation(ad_prog, "u_map");
  adu_uvc = glGetUniformLocation(ad_prog, "u_uvc");
  adu_box = glGetUniformLocation(ad_prog, "u_box");
  adu_param = glGetUniformLocation(ad_prog, "u_param");
}

static void ensure_ad_prog(void) { ensure_ad_prog_impl(0); }

#ifdef MB_PROGS_AHEAD
// (the host's thread that makes programs ahead, its own context current, sharing the objects of the GL thread's of
// `gen`) the programs of the slots the GL thread has none of linked, the heavy glass first, each kept in the binary
// cache for the next start and handed over (ahead_progs) once it is whole (glFinish: another context draws with it):
// how many. Stops when the GL thread's context is no longer `gen`'s.
static int gl_progs_ahead(unsigned gen) {
  static const int order[MB_SLOTS] = {MB_PROG_LIQUID_MERGED, MB_PROG_LIQUID_SINGLE, MB_SLOT_ADAPTIVE,
                                      MB_PROG_FROSTED,       MB_PROG_LENS,          MB_SLOT_POST,
                                      MB_PROG_PATH,          MB_SLOT_FLAT,          MB_PROG_UI};
  GLint nfmt = 0;
  glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &nfmt);
  int use_cache = prog_cache_dir[0] != '\0' && nfmt > 0;
  GLuint vs[3] = {0, 0, 0};
  int made = 0;
  for (int i = 0; i < MB_SLOTS; i++) {
    int slot = order[i];
    pthread_mutex_lock(&ahead_mu);
    int gone = ahead_gen != gen, claimed = (ahead_claimed >> slot) & 1;
    pthread_mutex_unlock(&ahead_mu);
    if (gone) break;
    if (claimed) continue;
    char fs_head[1024];
    prog_src s = prog_src_of(slot, fs_head, sizeof fs_head);
    if (!vs[s.vs]) vs[s.vs] = compile2(GL_VERTEX_SHADER, s.vs_head, s.vs_body, s.tag);
    GLuint fs = compile2(GL_FRAGMENT_SHADER, s.fs_head, s.fs_body, s.tag);
    GLuint p = glCreateProgram();
    if (use_cache) glProgramParameteri(p, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE);
    glAttachShader(p, vs[s.vs]);
    glAttachShader(p, fs);
    glLinkProgram(p);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
      glDeleteProgram(p);
      continue;
    }
    if (use_cache) {
      char path[640];
      prog_cache_path(path, sizeof path, s.tag, s.vs_head, s.vs_body, s.fs_head, s.fs_body);
      prog_cache_save(path, p);
    }
    glFinish();
    pthread_mutex_lock(&ahead_mu);
    int keep = ahead_gen == gen && !((ahead_claimed >> slot) & 1);
    if (keep) ahead_progs[slot] = p;
    pthread_mutex_unlock(&ahead_mu);
    if (keep) made++;
    else glDeleteProgram(p);
  }
  for (int i = 0; i < 3; i++)
    if (vs[i]) glDeleteShader(vs[i]);
  return made;
}
#endif

// Preload any already-cached .glbin program binaries on context setup without compiling.
static void gl_preload_cached_progs(void) {
  if (prog_cache_dir[0] == '\0' || !prog_bin_capable()) return;
  for (int g = 0; g < MB_PROGS; g++) {
    if (!progs[g].p) progs[g] = make_prog_impl(g, 1);
  }
  ensure_prog_flat_impl(1);
  ensure_post_impl(1);
  ensure_ad_prog_impl(1);
  prog_now = 0;
  glUseProgram(0);
}

// The instances' buffer and the glyphs' atlases made in the context now current; programs are compiled on first use,
// or made ahead (ahead_reset) (a new context has none of the old: handles are cleared here, as glass_lost and
// canvas_lost do).
static void gl_setup(void) {
  ahead_reset();
  vs_main = vs_main_ad = vs_post = 0;
  memset(progs, 0, sizeof progs);
  prog_flat = 0;
  uf_vp = -1;
  post = 0;
  ad_prog = 0;
  prog_now = 0;
  prog_bin_checked = 0;
  prog_bin_ok = 0;
  prog_gen++;
  segs_tex = 0;
  segs_rows = 0;
  segs_had_n = 0;
  glass_lost();
  canvas_lost();
  glGenVertexArrays(1, &vao);
  glBindVertexArray(vao);
  glGenBuffers(1, &vbo);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  for (int i = 0; i < MB_INST / 4; i++) {
    glEnableVertexAttribArray(i);
    glVertexAttribPointer(i, 4, GL_FLOAT, GL_FALSE, MB_INST * 4, (void *)(intptr_t)(i * 16));
    glVertexAttribDivisor(i, 1);
  }
  // the words' atlas a byte a texel, colour glyphs' four (MB_ATLAS above)
  GLuint *texs[2] = {&atlas, &catlas};
  for (int k = 0; k < 2; k++) {
    glGenTextures(1, texs[k]);
    glBindTexture(GL_TEXTURE_2D, *texs[k]);
    if (k == 0) glTexStorage2D(GL_TEXTURE_2D, 1, GL_R8, MB_ATLAS, MB_ATLAS);
    else glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, MB_ATLAS_COLOR, MB_ATLAS_COLOR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  glEnable(GL_BLEND);
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  gl_preload_cached_progs();
}

// ---------------------------------------------------------------------------
// Glass (src/ui/glass.mbt): when the instances reach a run of glass (slot 20 negative: the capture it shares), what
// is drawn so far under it (its rects with room for the blur round them) is copied out of the surface, halved down
// to where the blur is a few texels wide (dual Kawase's downsample, at most 1/8), blurred there by a Gaussian of what
// deviation is left, and drawn through. Level j is 1/2^j of the largest capture yet (the glass and the blur's margin
// round it, not the surface: a composer's strip, not the screen), [4] a Gaussian's first half. Level 0, the
// copy, has 8 bits a channel as the surface has; what the passes write keeps 10 (RGB10_A2, in as many bytes): at 8 each
// pass rounds the frost's slow slopes into flat steps, a texel of the last level 8 pixels wide on the screen (a blur
// under 4 pixels, too narrow to halve, is written back into the copy: it leaves no slope that wide).

typedef struct { GLuint t, fb; int w, h; GLenum format; } level;
static level lv[5];
static int lv_w, lv_h;
static int lv_shrink_frames, lv_win_max_w, lv_win_max_h;
static int lv_frame_max_w, lv_frame_max_h;
static level lens_lv[2];
static int lens_w, lens_h;
static float cur_ox, cur_oy, cur_vpw, cur_vph;
static int levels_rebuilt;
static GLuint bd_tex;
static float gmap[4], guvc[4], ggb[4], gshape[32], grad[32];
static int gn;
// the app's part of the surface (MBView: the soft keyboard over the rest), in its pixels from the foot
static int vy0, vhp;

// the last capture's blur is kept to be shown again (capture, below)
static int kept_ok;
static void slots_invalidate(void);
static void slots_drop_textures(void);
static void glass_forget(void);

static level level_tex(GLenum format, int w, int h) {
  level l = {0, 0, w > 0 ? w : 1, h > 0 ? h : 1, format};
  glGenTextures(1, &l.t);
  glBindTexture(GL_TEXTURE_2D, l.t);
  glTexStorage2D(GL_TEXTURE_2D, 1, format, l.w, l.h);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glGenFramebuffers(1, &l.fb);
  glBindFramebuffer(GL_FRAMEBUFFER, l.fb);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, l.t, 0);
  return l;
}

static void ensure_levels(int w, int h) {
  if (lv[0].t && lv_w >= w && lv_h >= h) return;
  for (int j = 0; j < 5; j++)
    if (lv[j].t) {
      glDeleteTextures(1, &lv[j].t);
      glDeleteFramebuffers(1, &lv[j].fb);
    }
  int nw = (w + 255) & ~255;
  int nh = (h + 255) & ~255;
  if (fb_w > 0 && nw > fb_w) nw = fb_w;
  if (fb_h > 0 && nh > fb_h) nh = fb_h;
  if (nw < w) nw = w;
  if (nh < h) nh = h;
  lv_w = nw > lv_w ? nw : lv_w;
  lv_h = nh > lv_h ? nh : lv_h;
  levels_rebuilt++;
  lv_shrink_frames = 0;
  lv_win_max_w = lv_win_max_h = 0;
  lv_frame_max_w = lv_frame_max_h = 0;
  // (the blurs kept were shown by where they lie in levels of the old size: one made now would be shown by the new)
  slots_invalidate();
  slots_drop_textures();
  for (int j = 0; j < 4; j++)
    lv[j] = level_tex(j == 0 ? GL_RGBA8 : GL_RGB10_A2, (lv_w + (1 << j) - 1) >> j, (lv_h + (1 << j) - 1) >> j);
  lv[4] = level_tex(GL_RGB10_A2, lv_w, lv_h);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

static void ensure_lens_levels(int w, int h) {
  if (lens_lv[0].t && lens_w >= w && lens_h >= h) return;
  for (int j = 0; j < 2; j++)
    if (lens_lv[j].t) {
      glDeleteTextures(1, &lens_lv[j].t);
      glDeleteFramebuffers(1, &lens_lv[j].fb);
    }
  lens_w = w > lens_w ? w : lens_w;
  lens_h = h > lens_h ? h : lens_h;
  for (int j = 0; j < 2; j++) lens_lv[j] = level_tex(GL_RGBA8, lens_w, lens_h);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

static void post_pass(level *src, int sw, int sh, level *dst, int w, int h, int mode, float sg, float dx, float dy) {
  glBindFramebuffer(GL_FRAMEBUFFER, dst->fb);
#ifdef GL_ES_VERSION_3_0
  {
    const GLenum att = GL_COLOR_ATTACHMENT0;
    glInvalidateFramebuffer(GL_FRAMEBUFFER, 1, &att);
  }
#endif
  glViewport(0, 0, w, h);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, src->t);
  glUniform1i(pu_src, 0);
  glUniform4f(pu_a, 1.0f / src->w, 1.0f / src->h, (float)mode, sg);
  glUniform4f(pu_b, (sw - 0.5f) / src->w, (sh - 0.5f) / src->h, dx, dy);
  glDrawArrays(GL_TRIANGLES, 0, 3);
}

// The post program's other units (u_lv1..3) let go of the levels: a level still bound to an active sampler while a
// later pass draws into it is a feedback loop (GL_INVALID_OPERATION on WebGL2 and strict GLES 3, the draw dropped).
static void unbind_post_extra(void) {
  glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0);
  glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, 0);
  glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, 0);
  glActiveTexture(GL_TEXTURE0);
}

// Partial redraw: the surface's frame is drawn into a canvas of its own (canvas_fb), kept
// across frames, and copied onto the surface (what the surface held is gone once shown); where the app says only some
// parts differ from the frame before (@hostapi.render_dirty), only those parts of the canvas are drawn again, each cut
// to it (the scissor, `cut`: x, y from the foot, w, h; while `cut_on`), the frame's ground over it first (the instance
// after the frame's, gl_present's), then every instance. Without the surface the offscreen framebuffer is the canvas.
static GLuint canvas_fb, canvas_tex;
static int canvas_w, canvas_h, offscreen;
// what the canvas (or the offscreen framebuffer) holds is the last frame given
static int canvas_ok;
// the parts of the next frame that differ (points: x, y, w, h), all of it (`dirty_whole`), and whether any was said
#define MB_PARTS 8
static double dirty[MB_PARTS][4];
static int dirty_n, dirty_whole, dirty_told;
// a picture the frame drawn last had none of yet (drawn without it): the next drawn whole
static int pictures_missing, encode_missing;
static int cut_on;
static int cut[4];

static void gl_dirty_add(double x, double y, double w, double h) {
  dirty_told = 1;
  if (w < 0 || h < 0) {
    dirty_whole = 1;
  } else if (w > 0 && h > 0) {
    // (more than it keeps: the last one grown round it)
    if (dirty_n == MB_PARTS) {
      double *d = dirty[MB_PARTS - 1];
      double x1 = fmax(d[0] + d[2], x + w), y1 = fmax(d[1] + d[3], y + h);
      d[0] = fmin(d[0], x);
      d[1] = fmin(d[1], y);
      d[2] = x1 - d[0];
      d[3] = y1 - d[1];
    } else {
      double *d = dirty[dirty_n++];
      d[0] = x; d[1] = y; d[2] = w; d[3] = h;
    }
  }
}

static volatile float g_light_angle = 0.0f;
static void gl_set_glass_light_angle(double rad) { g_light_angle = (float)rad; }

#ifndef MB_HOST_THREADS
void mb_host_render_dirty(double x, double y, double w, double h) { gl_dirty_add(x, y, w, h); }
void mb_host_glass_light_angle(double rad) { gl_set_glass_light_angle(rad); }
// (each frame drawn as it is made, on the app's thread: none dropped. A host whose app runs on another thread counts
// those a newer one took the place of: android_host.c)
int32_t mb_host_frames_dropped(void) { return 0; }
#endif

// The parts of the frame the next one draws, from what was said of them (taken: a frame nothing was said for is drawn
// whole), into `r` (as `cut`): how many (0 none), -1 all of it. `kept`: the target holds the frame before. In the
// surface's pixels, the app's top the surface's.
static int take_parts(int kept, int r[MB_PARTS][4]) {
  int told = dirty_told, whole = dirty_whole, n = dirty_n;
  dirty_told = dirty_whole = dirty_n = 0;
  if (!told || whole || !kept || pictures_missing) return -1;
  int k = 0;
  for (int i = 0; i < n; i++) {
    // (whole pixels round it, and one more)
    int x0 = (int)floor(dirty[i][0] * cur_scale) - 1, y0 = (int)floor(dirty[i][1] * cur_scale) - 1;
    int x1 = (int)ceil((dirty[i][0] + dirty[i][2]) * cur_scale) + 1;
    int y1 = (int)ceil((dirty[i][1] + dirty[i][3]) * cur_scale) + 1;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > fb_w) x1 = fb_w;
    if (y1 > fb_h) y1 = fb_h;
    if (x1 <= x0 || y1 <= y0) continue;
    r[k][0] = x0;
    r[k][1] = fb_h - y1;
    r[k][2] = x1 - x0;
    r[k][3] = y1 - y0;
    k++;
  }
  return k;
}

static void draw_into_rects(GLuint fb, const int (*rects)[4], int n_rects);
static void draw_into(GLuint fb, int part);

// The frame kept drawn into `fb`, only its parts that differ (take_parts) where it holds the frame before (`kept`),
// else whole.
static void draw_parts(GLuint fb, int kept) {
  int parts[MB_PARTS][4];
  int n = take_parts(kept, parts);
  if (n == 0) return;
  if (n < 0) draw_into_rects(fb, NULL, -1);
  else draw_into_rects(fb, parts, n);
  pictures_missing = encode_missing;
}

// The canvas gone with the context it was made in (a new one: gl_setup), nothing of it given back.
static void canvas_lost(void) {
  canvas_fb = canvas_tex = 0;
  canvas_w = canvas_h = 0;
  canvas_ok = 0;
}

// The canvas the surface's frames are drawn into, its size: made again at another size (or once the context is new:
// gl_setup), what it held lost.
static void ensure_canvas(void) {
  if (canvas_fb && canvas_w == fb_w && canvas_h == fb_h) return;
  if (canvas_fb) {
    glDeleteFramebuffers(1, &canvas_fb);
    glDeleteTextures(1, &canvas_tex);
  }
  canvas_fb = canvas_tex = 0;
  canvas_ok = 0;
  canvas_w = fb_w;
  canvas_h = fb_h;
  if (fb_w <= 0 || fb_h <= 0) return;
  glGenTextures(1, &canvas_tex);
  glBindTexture(GL_TEXTURE_2D, canvas_tex);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
  glGenFramebuffers(1, &canvas_fb);
  glBindFramebuffer(GL_FRAMEBUFFER, canvas_fb);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, canvas_tex, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    glDeleteFramebuffers(1, &canvas_fb);
    glDeleteTextures(1, &canvas_tex);
    canvas_fb = canvas_tex = 0;
  }
}

// What a capture of glass is of, worked out before any of the GPU's work: its rectangle in the surface's pixels from its
// foot (px0, pb0, w × h; the app's top, `top`), how many times it is halved (k, at most 3) and the Gaussian left after
// (sg), whether its edge is contained, and the glass's own numbers (its bounds, liquid's shapes). Zeroed whole first,
// so two of the same compare the same (as Metal's: apple_render.m Grab).
typedef struct {
  int px0, pb0, w, h, top, k, contained, progressive, n;
  int vis_x, vis_y, vis_w, vis_h;
  float sg, sp;
  float fade[4], fadex[4];
  float gb[4], shape[32], rad[32];
  MBContained edge;
} Grab;

// The capture the run [start, end) of glass makes, frosted glass of the same capture further on (glass.mbt
// shares_capture) under it too; 0 when none of it shows, or it is outside the part drawn.
static int grab_of(Grab *m, const float *f, int32_t start, int32_t end, int32_t count) {
  memset(m, 0, sizeof *m);
  const float *a = f + start * MB_INST;
  // For frosted glass (kind 5), negative slot 7 is contained; for liquid glass (kind 6), negative slot 7 encodes clear-lens zoom.
  int kind = (int)(a[5] + 0.5f);
  int is_contained = (kind == 5 && a[7] < 0.0f);
  int is_progressive = (kind == 5 && a[22] < -0.5f);
  float blur = (kind == 6 && a[7] < 0.0f) ? 0.0f : fabsf(a[7]);
  int merged_liquid = (kind == 6 && a[23] > 0.0f);
  int unmerged_liquid = (kind == 6 && !merged_liquid);
  float margin = is_contained ? 0.0f : 3.0f * blur + (kind == 6 ? a[21] * (1.0f + fabsf(a[22])) + fmaxf(a[23], 0.0f) : 0.0f) + 2.0f;
  float x0 = 1e9f, y0 = 1e9f, x1 = -1e9f, y1 = -1e9f;
  for (int32_t i = start; i < end; i++) {
    const float *b = f + i * MB_INST;
    float bx0 = b[0] > b[16] ? b[0] : b[16], by0 = b[1] > b[17] ? b[1] : b[17];
    float bx1 = b[0] + b[2] < b[18] ? b[0] + b[2] : b[18], by1 = b[1] + b[3] < b[19] ? b[1] + b[3] : b[19];
    if (kind == 6) {
      float m23 = fmaxf(unmerged_liquid ? b[23] : a[23], 0.0f);
      bx0 = b[0] - m23; by0 = b[1] - m23; bx1 = b[0] + b[2] + m23; by1 = b[1] + b[3] + m23;
      if (merged_liquid && m->n < 8) {
        for (int k = 0; k < 4; k++) m->shape[m->n * 4 + k] = b[k];
        if (fmaxf(fmaxf(b[36], b[37]), fmaxf(b[38], b[39])) > 0.0f) {
          for (int k = 0; k < 4; k++) m->rad[m->n * 4 + k] = b[36 + k];
        } else {
          for (int k = 0; k < 4; k++) m->rad[m->n * 4 + k] = b[4];
        }
        m->n++;
      }
      if (unmerged_liquid) {
        float bm = 3.0f * blur + b[21] * (1.0f + fabsf(b[22])) + m23 + 2.0f;
        if (bm > margin) margin = bm;
      }
    }
    if (bx0 < x0) x0 = bx0;
    if (by0 < y0) y0 = by0;
    if (bx1 > x1) x1 = bx1;
    if (by1 > y1) y1 = by1;
  }
  for (int32_t i = end; (kind == 5 || unmerged_liquid) && i < count; i++) {
    const float *b = f + i * MB_INST;
    if (b[20] != a[20]) continue;
    float bx0, by0, bx1, by1;
    if (unmerged_liquid) {
      float m23 = fmaxf(b[23], 0.0f);
      bx0 = b[0] - m23; by0 = b[1] - m23; bx1 = b[0] + b[2] + m23; by1 = b[1] + b[3] + m23;
      {
        float bm = 3.0f * blur + b[21] * (1.0f + fabsf(b[22])) + m23 + 2.0f;
        if (bm > margin) margin = bm;
      }
    } else {
      bx0 = b[0] > b[16] ? b[0] : b[16]; by0 = b[1] > b[17] ? b[1] : b[17];
      bx1 = b[0] + b[2] < b[18] ? b[0] + b[2] : b[18]; by1 = b[1] + b[3] < b[19] ? b[1] + b[3] : b[19];
    }
    if (bx0 < x0) x0 = bx0;
    if (by0 < y0) y0 = by0;
    if (bx1 > x1) x1 = bx1;
    if (by1 > y1) y1 = by1;
  }
  if (kind == 5 || unmerged_liquid) {
    for (int32_t i = end; i < count; i++) {
      const float *b = f + i * MB_INST;
      int bk = (int)(b[5] + 0.5f);
      if ((bk == 5 || bk == 6) && b[20] < 0.0f && b[20] != a[20]) break;
      if (bk == 7 && b[23] < 0.0f) {
        float hr = -b[23] * 0.5f;
        if (b[21] - hr < x0) x0 = b[21] - hr;
        if (b[22] - hr < y0) y0 = b[22] - hr;
        if (b[21] + hr > x1) x1 = b[21] + hr;
        if (b[22] + hr > y1) y1 = b[22] + hr;
      }
    }
  }
  m->gb[0] = x0 - 2; m->gb[1] = y0 - 2; m->gb[2] = x1 + 2; m->gb[3] = y1 + 2;
  float sc = (float)cur_scale;
  // in the surface's pixels, from its foot (GL's way up)
  int top = vy0 + vhp;
  int px0 = (int)floorf((x0 - margin) * sc), px1 = (int)ceilf((x1 + margin) * sc);
  int pb0 = top - (int)ceilf((y1 + margin) * sc), pb1 = top - (int)floorf((y0 - margin) * sc);
  if (px0 < 0) px0 = 0;
  if (px1 > fb_w) px1 = fb_w;
  if (pb0 < vy0) pb0 = vy0;
  if (pb1 > top) pb1 = top;
  if (px1 <= px0 || pb1 <= pb0 || x1 <= x0 || y1 <= y0) return 0;
  m->px0 = px0; m->pb0 = pb0; m->w = px1 - px0; m->h = pb1 - pb0; m->top = top;
  m->contained = is_contained ? mb_contained_make(&m->edge, a, px0 / sc, (top - pb0) / sc, 1.0f / sc, -1.0f / sc) : 0;
  m->progressive = is_progressive;
  if (is_progressive) {
    for (int i = 0; i < 4; i++) {
      m->fade[i] = a[52 + i];
      m->fadex[i] = a[56 + i];
    }
    int vx0 = (int)floorf(x0 * sc) - px0 - 2;
    int vy0 = (top - (int)ceilf(y1 * sc)) - pb0 - 2;
    int vx1 = (int)ceilf(x1 * sc) - px0 + 2;
    int vy1 = (top - (int)floorf(y0 * sc)) - pb0 + 2;
    if (vx0 < 0) vx0 = 0;
    if (vy0 < 0) vy0 = 0;
    if (vx1 > m->w) vx1 = m->w;
    if (vy1 > m->h) vy1 = m->h;
    if (vx1 <= vx0) { vx0 = 0; vx1 = m->w; }
    if (vy1 <= vy0) { vy0 = 0; vy1 = m->h; }
    m->vis_x = vx0; m->vis_y = vy0; m->vis_w = vx1 - vx0; m->vis_h = vy1 - vy0;
  }
  float sp = blur * sc;
  int k = 0;
  while (k < 3 && sp / (float)(1 << (k + 1)) >= 2.0f) k++;
  m->sp = sp;
  if (is_progressive && k == 0 && sp > 0.5f) k = 1;
  // what is left of the deviation once the halvings' and the last look's (bilinear) spread are taken out
  float sk = sp / (float)(1 << k);
  float pre = k > 0 ? 0.75f * (1.0f - powf(0.25f, (float)k)) / 3.0f + 1.0f / 6.0f : 0.0f;
  m->k = k;
  m->sg = sqrtf(sk * sk - pre > 0 ? sk * sk - pre : 0);
  return 1;
}

// The size of a grab's level j (its passes write each level's foot left)
static void grab_levels(const Grab *m, int lw[4], int lh[4]) {
  lw[0] = m->w; lh[0] = m->h;
  for (int j = 1; j <= 3; j++) {
    lw[j] = (lw[j - 1] + 1) / 2;
    lh[j] = (lh[j - 1] + 1) / 2;
  }
}

static void grab_map_uvc(const Grab *m, int bw, int bh, float map[4], float uvc[4]) {
  int lw[4], lh[4];
  grab_levels(m, lw, lh);
  int sk = m->progressive ? 0 : m->k, px0 = m->px0, pb0 = m->pb0, top = m->top;
  float sc = (float)cur_scale;
  float d = (float)(1 << sk);
  map[0] = sc / d / bw; map[1] = -sc / d / bh;
  map[2] = -(float)px0 / d / bw; map[3] = (float)(top - pb0) / d / bh;
  if (m->progressive) {
    uvc[0] = ((float)m->vis_x + 0.5f) / bw; uvc[1] = ((float)m->vis_y + 0.5f) / bh;
    uvc[2] = ((float)(m->vis_x + m->vis_w) - 0.5f) / bw; uvc[3] = ((float)(m->vis_y + m->vis_h) - 0.5f) / bh;
  } else {
    uvc[0] = 0.5f / bw; uvc[1] = 0.5f / bh; uvc[2] = (lw[sk] - 0.5f) / bw; uvc[3] = (lh[sk] - 0.5f) / bh;
  }
}

// What the glass shows of a grab's blur in texture `bt` (bw × bh, level k's place in it): bd_tex and the uniforms
// that say where in it it is.
static void show_blur(const Grab *m, GLuint bt, int bw, int bh) {
  memcpy(ggb, m->gb, sizeof ggb);
  memcpy(gshape, m->shape, sizeof gshape);
  memcpy(grad, m->rad, sizeof grad);
  gn = m->n;
  bd_tex = bt;
  grab_map_uvc(m, bw, bh, gmap, guvc);
}

// The level a grab's blur is left in.
static level *grab_blurred(const Grab *m) { return (m->progressive || (m->contained && m->k == 0)) ? &lv[4] : &lv[m->k]; }

// A grab of target_fb blurred into the levels: what is drawn so far in its rectangle copied out, halved k times, the
// Gaussian left (grab_blurred). The levels are shared by every capture: what is shown is the copy a slot keeps (below).
// (how many: scripts/gles_render_test.c, a blur shown again as kept is none)
static int blurs_made;

static void blur(const Grab *m) {
  blurs_made++;
  int w = m->w, h = m->h, k = m->k, contained = m->contained;
  ensure_levels(w, h);
  glDisable(GL_BLEND);
  // (the copy and the passes whole, not cut to the part: a blit is cut by the scissor too)
  glDisable(GL_SCISSOR_TEST);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, target_fb);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, lv[0].fb);
#ifdef GL_ES_VERSION_3_0
  {
    const GLenum att = GL_COLOR_ATTACHMENT0;
    glInvalidateFramebuffer(GL_DRAW_FRAMEBUFFER, 1, &att);
  }
#endif
  glBlitFramebuffer(m->px0, m->pb0, m->px0 + w, m->pb0 + h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  ensure_post();
  glUseProgram(post);
  unbind_post_extra();
  int lw[4], lh[4];
  grab_levels(m, lw, lh);
  if (m->progressive) {
    float prev_var = 0.0f;
    for (int j = 1; j <= k; j++) {
      post_pass(&lv[j - 1], lw[j - 1], lh[j - 1], &lv[j], lw[j], lh[j], 1, 0, 0, 0);
      float target_px = powf(fmaxf(m->sp, 1.0f), (float)j / (float)k);
      float have_var = prev_var + 0.75f * (float)(1 << (2 * j - 2));
      float need_var = fmaxf(target_px * target_px - have_var, 0.0f);
      float sg_j = sqrtf(need_var) / (float)(1 << j);
      if (sg_j > 0.3f) {
        post_pass(&lv[j], lw[j], lh[j], &lv[4], lw[j], lh[j], 2, sg_j, 1, 0);
        post_pass(&lv[4], lw[j], lh[j], &lv[j], lw[j], lh[j], 2, sg_j, 0, 1);
      }
      prev_var = fmaxf(have_var, target_px * target_px);
    }
    float sc = (float)cur_scale;
    float prog[36] = {0};
    prog[0] = (float)m->px0 / sc; prog[1] = (float)(m->top - m->pb0) / sc;
    prog[2] = 1.0f / sc; prog[3] = -1.0f / sc;
    for (int i = 0; i < 4; i++) { prog[4 + i] = m->fade[i]; prog[8 + i] = m->fadex[i]; }
    prog[12] = m->sp; prog[13] = (float)k;
    for (int j = 0; j < 4; j++) {
      float dj = (float)(1 << j), tw = (float)lv[j].w, th = (float)lv[j].h;
      prog[16 + j * 4 + 0] = 1.0f / (dj * tw);
      prog[16 + j * 4 + 1] = 1.0f / (dj * th);
      prog[16 + j * 4 + 2] = ((float)lw[j] - 0.5f) / tw;
      prog[16 + j * 4 + 3] = ((float)lh[j] - 0.5f) / th;
    }
    glUniform4fv(pu_c, 9, prog);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, lv[1].t); glUniform1i(pu_lv1, 1);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, lv[2].t); glUniform1i(pu_lv2, 2);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, lv[3].t); glUniform1i(pu_lv3, 3);
    glEnable(GL_SCISSOR_TEST);
    glScissor(m->vis_x, m->vis_y, m->vis_w, m->vis_h);
    post_pass(&lv[0], w, h, &lv[4], w, h, 4, 0, 0, 0);
    glDisable(GL_SCISSOR_TEST);
    unbind_post_extra();
    return;
  }
  if (contained) {
    glUniform4fv(pu_c, 9, (const float *)&m->edge);
    post_pass(&lv[0], w, h, &lv[4], w, h, 3, 0, 0, 0);
  }
  for (int j = 1; j <= k; j++)
    post_pass(j == 1 && contained ? &lv[4] : &lv[j - 1], lw[j - 1], lh[j - 1], &lv[j], lw[j], lh[j], 1, 0, 0, 0);
  if (m->sg > 0.3f) {
    level *from = grab_blurred(m);
    level *tmp = contained && k == 0 ? &lv[0] : &lv[4];
    post_pass(from, lw[k], lh[k], tmp, lw[k], lh[k], 2, m->sg, 1, 0);
    post_pass(tmp, lw[k], lh[k], from, lw[k], lh[k], 2, m->sg, 0, 1);
  }
}

// The blurs kept, a slot each, as many as a screen has groups of glass at once (a bar at the top, a composer and its
// ground at the foot, a sheet's, a page sliding over another: 2 to 6), the one least lately shown taken for a new one.
// A slot holds a capture's blur copied out of the levels, as big as the levels (so it
// is shown by the same numbers as the level it came from, to the byte), and what it was of. What a capture copies is
// what the frame drew before it in the grab's rectangle (the instances up to the glass that reach into it, the pieces
// of the frame's shapes they are drawn by, the ground the frame cleared to) of a surface of that size: a frame that
// draws all that the same under the same glass (a caret blinking in a composer, a spinner turning, a button lit under
// the hand, over a list at rest) shows the blur as it is, with no copy and no passes, the framebuffer drawn into not
// left for them (apple_render.m's slots, Metal's); one where something moved under one group of glass makes that
// group's blur again, the others' kept. A stream or a native view's picture drawn into it (its pictures change under
// the same instances) is blurred anew each frame, as is a frame an image under it had no texture for yet.
#define MB_GLASS_SLOTS 32
#ifdef __ANDROID__
#define MB_GLASS_CACHE_MAX_BYTES ((size_t)32 * 1024 * 1024)
#else
#define MB_GLASS_CACHE_MAX_BYTES ((size_t)64 * 1024 * 1024)
#endif
typedef struct {
  GLuint bt, bfb;
  int bw, bh;
  GLenum bf;
  float *under;
  size_t under_cap, under_n;
  int32_t whole, picked;
  Grab grab;
  double key[9];
  int valid;
  unsigned used;
  unsigned gen;
} glass_slot;
static glass_slot slots[MB_GLASS_SLOTS];
static unsigned slots_clock;
static unsigned slots_gen;

static size_t glass_tex_bytes(int w, int h) {
  if (w <= 0 || h <= 0) return 0;
  return (size_t)w * (size_t)h * 4;
}

static size_t slots_total_bytes(void) {
  size_t total = 0;
  for (int i = 0; i < MB_GLASS_SLOTS; i++) {
    if (slots[i].bt) total += glass_tex_bytes(slots[i].bw, slots[i].bh);
  }
  return total;
}

static void slot_drop_tex(glass_slot *s) {
  if (s->bt) {
    glDeleteFramebuffers(1, &s->bfb);
    glDeleteTextures(1, &s->bt);
    s->bt = s->bfb = 0;
    s->bw = s->bh = 0;
    s->bf = 0;
  }
}

static void slots_drop_textures(void) {
  for (int i = 0; i < MB_GLASS_SLOTS; i++) slot_drop_tex(&slots[i]);
}
// what the capture now is of (under_now), as a slot keeps it
static float *under_now;
static size_t under_now_cap, under_now_n;
static int32_t under_whole, under_picked;

#define MB_ADAPTIVE_MAX 16
#define MB_AD_TAU 0.070
#define MB_AD_SETTLE_SEC 0.42
#define MB_AD_MATCH_DIST 64.0
#define MB_AD_RB_N 3

typedef struct {
  int active;
  float cx, cy, hx, hy;
  int is_dark;
  double settle_left;
  uint64_t settle_serial;
  uint64_t updated_serial;
  uint64_t seen_serial;
} mb_ad_slot;

typedef struct {
  GLuint pbo;
  GLsync fence;
  uint32_t mask;
  uint64_t serial;
} gl_ad_rb;

static GLuint ad_tex[2], ad_fb[2];
static int ad_cur;
static gl_ad_rb ad_rb[MB_AD_RB_N];
static int ad_rb_i;
static int ad_rb_cur = -1;
static int ad_rb_prev_copied;
static uint32_t ad_track_mask;
static uint64_t ad_conv_serial[MB_ADAPTIVE_MAX];
static mb_ad_slot ad_slots[MB_ADAPTIVE_MAX];
static double ad_last_time, ad_fixed_dt;
static uint64_t ad_frame_serial;
static int ad_settling;
// 1 = update adaptive state, 0 = read-only, -1 = stateless
static int ad_mode = 1;
static double ad_cur_dt = 0.0;
static float gad_box[MB_ADAPTIVE_MAX * 4];
static int gad_n;

static void ad_forget(void) {
  memset(ad_slots, 0, sizeof ad_slots);
  memset(ad_conv_serial, 0, sizeof ad_conv_serial);
  for (int i = 0; i < MB_AD_RB_N; i++) ad_rb[i].mask = 0;
  ad_track_mask = 0;
  ad_rb_prev_copied = 0;
  ad_rb_cur = -1;
  ad_last_time = 0.0;
  __atomic_store_n(&ad_settling, 0, __ATOMIC_RELEASE);
  gad_n = 0;
}

static void ensure_ad_tex(void) {
  if (!ad_tex[0]) {
    for (int i = 0; i < 2; i++) {
      glGenTextures(1, &ad_tex[i]);
      glBindTexture(GL_TEXTURE_2D, ad_tex[i]);
      glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, MB_ADAPTIVE_MAX, 1);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glGenFramebuffers(1, &ad_fb[i]);
      glBindFramebuffer(GL_FRAMEBUFFER, ad_fb[i]);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, ad_tex[i], 0);
    }
    ad_cur = 0;
  }
  if (!ad_rb[0].pbo) {
    for (int i = 0; i < MB_AD_RB_N; i++) {
      glGenBuffers(1, &ad_rb[i].pbo);
      glBindBuffer(GL_PIXEL_PACK_BUFFER, ad_rb[i].pbo);
      glBufferData(GL_PIXEL_PACK_BUFFER, MB_ADAPTIVE_MAX * 4 * 2, NULL, GL_STREAM_READ);
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  }
}

static void ad_poll_readbacks(void) {
  for (int i = 0; i < MB_AD_RB_N; i++) {
    if (!ad_rb[i].fence) continue;
    GLenum st = glClientWaitSync(ad_rb[i].fence, 0, 0);
    if (st == GL_ALREADY_SIGNALED || st == GL_CONDITION_SATISFIED) {
      if (ad_rb[i].pbo && ad_rb[i].mask) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, ad_rb[i].pbo);
        const uint8_t *p = (const uint8_t *)glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, MB_ADAPTIVE_MAX * 4 * 2,
                                                             GL_MAP_READ_BIT);
        if (p) {
          const uint8_t *prev = p;
          const uint8_t *next = p + MB_ADAPTIVE_MAX * 4;
          for (int s = 0; s < MB_ADAPTIVE_MAX; s++) {
            if (!(ad_rb[i].mask & (1u << s))) continue;
            if (prev[s * 4 + 0] == next[s * 4 + 0] && prev[s * 4 + 1] == next[s * 4 + 1]) {
              if (ad_rb[i].serial > ad_conv_serial[s]) ad_conv_serial[s] = ad_rb[i].serial;
            }
          }
          glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
      }
      glDeleteSync(ad_rb[i].fence);
      ad_rb[i].fence = NULL;
      ad_rb[i].mask = 0;
    } else if (st == GL_WAIT_FAILED) {
      glDeleteSync(ad_rb[i].fence);
      ad_rb[i].fence = NULL;
      ad_rb[i].mask = 0;
    }
  }
}

static void ad_fill_uniforms(void) {
  if (ad_mode < 0) {
    gad_n = 0;
    return;
  }
  int max_active = 0;
  for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
    if (ad_slots[i].active) {
      gad_box[i * 4 + 0] = ad_slots[i].cx;
      gad_box[i * 4 + 1] = ad_slots[i].cy;
      gad_box[i * 4 + 2] = ad_slots[i].hx;
      gad_box[i * 4 + 3] = ad_slots[i].hy;
      max_active = i + 1;
    } else {
      gad_box[i * 4 + 0] = -1e9f;
      gad_box[i * 4 + 1] = -1e9f;
      gad_box[i * 4 + 2] = -1e9f;
      gad_box[i * 4 + 3] = -1e9f;
    }
  }
  gad_n = max_active;
}

typedef struct {
  int sid, is_new, is_dark;
  float cx, cy, hx, hy;
} gl_ad_pend;

static int ad_collect_and_match(const float *f, int32_t start, int32_t end, int32_t count, const Grab *m,
                                int backdrop_changed, double dt, uint64_t serial, gl_ad_pend out[MB_ADAPTIVE_MAX]) {
  (void)end;
  if (ad_mode <= 0 || dt < 0.0) return 0;
  const float *a = f + (size_t)start * MB_INST;
  int kind = (int)(a[5] + 0.5f);
  if (kind != 6) return 0;
  int merged_liquid = a[23] > 0.0f;
  struct { float cx, cy, hx, hy; int is_dark; } items[MB_ADAPTIVE_MAX];
  int ni = 0;
  if (merged_liquid) {
    int is_clear = (a[7] <= 0.1f && a[11] < 0.12f);
    int is_adaptive = a[14] < -0.5f;
    if (is_adaptive && !is_clear) {
      float lum = 0.2126f * a[8] + 0.7152f * a[9] + 0.0722f * a[10];
      items[ni].cx = (m->gb[0] + m->gb[2]) * 0.5f;
      items[ni].cy = (m->gb[1] + m->gb[3]) * 0.5f;
      items[ni].hx = fmaxf((m->gb[2] - m->gb[0]) * 0.5f, 1.0f);
      items[ni].hy = fmaxf((m->gb[3] - m->gb[1]) * 0.5f, 1.0f);
      items[ni].is_dark = (a[11] >= 0.05f && lum < 0.35f) ? 1 : 0;
      ni++;
    }
  } else {
    float tid = a[20];
    for (int32_t i = start; i < count && ni < MB_ADAPTIVE_MAX; i++) {
      const float *b = f + (size_t)i * MB_INST;
      if (b[20] != tid) continue;
      if ((int)(b[5] + 0.5f) != 6 || b[23] > 0.0f) continue;
      int is_clear = (b[7] <= 0.1f && b[11] < 0.12f);
      int is_adaptive = b[14] < -0.5f;
      if (!is_adaptive || is_clear) continue;
      float lum = 0.2126f * b[8] + 0.7152f * b[9] + 0.0722f * b[10];
      items[ni].cx = b[0] + b[2] * 0.5f;
      items[ni].cy = b[1] + b[3] * 0.5f;
      items[ni].hx = fmaxf(b[2] * 0.5f, 1.0f);
      items[ni].hy = fmaxf(b[3] * 0.5f, 1.0f);
      items[ni].is_dark = (b[11] >= 0.05f && lum < 0.35f) ? 1 : 0;
      ni++;
    }
  }
  int n_upd = 0;
  for (int k = 0; k < ni; k++) {
    int sid = -1, is_new = 0;
    for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
      mb_ad_slot *s = &ad_slots[i];
      if (s->active && s->seen_serial == serial && s->is_dark == items[k].is_dark &&
          hypotf(items[k].cx - s->cx, items[k].cy - s->cy) <= 2.0f) {
        sid = i;
        break;
      }
    }
    if (sid < 0) {
      float best_d = (float)MB_AD_MATCH_DIST + 1e-3f;
      for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
        mb_ad_slot *s = &ad_slots[i];
        if (!s->active || s->seen_serial == serial || s->is_dark != items[k].is_dark) continue;
        float d = hypotf(items[k].cx - s->cx, items[k].cy - s->cy);
        if (d <= best_d) { best_d = d; sid = i; }
      }
      if (sid < 0) {
        for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
          if (!ad_slots[i].active) { sid = i; break; }
        }
        if (sid < 0) {
          uint64_t oldest = UINT64_MAX;
          for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
            if (ad_slots[i].seen_serial != serial && ad_slots[i].seen_serial < oldest) {
              oldest = ad_slots[i].seen_serial;
              sid = i;
            }
          }
          if (sid < 0) sid = 0;
        }
        is_new = 1;
        memset(&ad_slots[sid], 0, sizeof ad_slots[sid]);
        ad_slots[sid].active = 1;
        ad_slots[sid].is_dark = items[k].is_dark;
      }
      ad_slots[sid].cx = items[k].cx;
      ad_slots[sid].cy = items[k].cy;
      ad_slots[sid].hx = items[k].hx;
      ad_slots[sid].hy = items[k].hy;
      ad_slots[sid].seen_serial = serial;
    }
    mb_ad_slot *s = &ad_slots[sid];
    if (!is_new && s->updated_serial == serial) continue;
    if (!is_new && !backdrop_changed && s->settle_left > 0.0 && ad_conv_serial[sid] >= s->settle_serial) {
      s->settle_left = 0.0;
    }
    int need = is_new || backdrop_changed || s->settle_left > 0.0;
    if (need) {
      if (is_new) {
        s->settle_left = 0.0;
        s->settle_serial = serial;
      } else if (backdrop_changed) {
        s->settle_left = MB_AD_SETTLE_SEC;
        s->settle_serial = serial;
      } else {
        s->settle_left -= dt;
        if (s->settle_left <= 0.0) s->settle_left = 0.0;
      }
      s->updated_serial = serial;
      out[n_upd++] = (gl_ad_pend){sid, is_new, s->is_dark, s->cx, s->cy, s->hx, s->hy};
    }
  }
  return n_upd;
}

typedef struct {
  gl_ad_pend p;
  GLuint bt;
  float map[4];
  float uvc[4];
} gl_ad_batch;

static void ad_run_updates_batch(const gl_ad_batch *items, int n_upd, double dt) {
  if (n_upd <= 0) return;
  ensure_ad_prog();
  if (!ad_prog) return;
  ensure_ad_tex();
  int cur = ad_cur, nxt = 1 - cur;
  uint32_t batch_mask = 0;
  for (int i = 0; i < n_upd; i++) {
    if (!items[i].p.is_new && dt > 0.0) batch_mask |= (1u << items[i].p.sid);
  }
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  if (batch_mask && !ad_rb_prev_copied) {
    int slot = -1;
    for (int k = 0; k < MB_AD_RB_N; k++) {
      int idx = (ad_rb_i + k) % MB_AD_RB_N;
      if (!ad_rb[idx].fence && ad_rb[idx].pbo) { slot = idx; break; }
    }
    if (slot >= 0) {
      glBindFramebuffer(GL_READ_FRAMEBUFFER, ad_fb[cur]);
      glPixelStorei(GL_PACK_ALIGNMENT, 1);
      glBindBuffer(GL_PIXEL_PACK_BUFFER, ad_rb[slot].pbo);
      glReadPixels(0, 0, MB_ADAPTIVE_MAX, 1, GL_RGBA, GL_UNSIGNED_BYTE, (void *)0);
      glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
      ad_rb_cur = slot;
      ad_rb_prev_copied = 1;
    }
  }
  ad_track_mask |= batch_mask;
  glBindFramebuffer(GL_READ_FRAMEBUFFER, ad_fb[cur]);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, ad_fb[nxt]);
  glBlitFramebuffer(0, 0, MB_ADAPTIVE_MAX, 1, 0, 0, MB_ADAPTIVE_MAX, 1, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, ad_fb[nxt]);
  glViewport(0, 0, MB_ADAPTIVE_MAX, 1);
  glEnable(GL_SCISSOR_TEST);
  glUseProgram(ad_prog);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, ad_tex[cur]);
  glUniform1i(adu_prev, 1);
  glUniform1i(adu_bd, 0);
  glActiveTexture(GL_TEXTURE0);
  GLuint last_bt = 0;
  for (int i = 0; i < n_upd; i++) {
    if (items[i].bt != last_bt) {
      last_bt = items[i].bt;
      glBindTexture(GL_TEXTURE_2D, last_bt);
    }
    glUniform4fv(adu_map, 1, items[i].map);
    glUniform4fv(adu_uvc, 1, items[i].uvc);
    glScissor(items[i].p.sid, 0, 1, 1);
    glUniform4f(adu_box, items[i].p.cx, items[i].p.cy, items[i].p.hx, items[i].p.hy);
    glUniform4f(adu_param, (float)items[i].p.is_dark, (float)items[i].p.is_new, (float)dt, (float)items[i].p.sid);
    glDrawArrays(GL_TRIANGLES, 0, 3);
  }
  ad_cur = nxt;
}

static void ad_rb_finish(uint64_t serial) {
  if (ad_rb_prev_copied && ad_rb_cur >= 0 && ad_track_mask && ad_fb[ad_cur] && ad_rb[ad_rb_cur].pbo) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, ad_fb[ad_cur]);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ad_rb[ad_rb_cur].pbo);
    glReadPixels(0, 0, MB_ADAPTIVE_MAX, 1, GL_RGBA, GL_UNSIGNED_BYTE, (void *)(uintptr_t)(MB_ADAPTIVE_MAX * 4));
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    ad_rb[ad_rb_cur].fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    ad_rb[ad_rb_cur].mask = ad_track_mask;
    ad_rb[ad_rb_cur].serial = serial;
    ad_rb_i = (ad_rb_cur + 1) % MB_AD_RB_N;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, target_fb);
  }
  ad_rb_prev_copied = 0;
  ad_track_mask = 0;
  ad_rb_cur = -1;
}

static void ad_run_updates(const gl_ad_pend *pend, int n_upd, double dt) {
  if (n_upd <= 0 || !bd_tex) return;
  ensure_ad_prog();
  if (!ad_prog) return;
  gl_ad_batch items[MB_ADAPTIVE_MAX];
  for (int i = 0; i < n_upd; i++) {
    items[i].p = pend[i];
    items[i].bt = bd_tex;
    memcpy(items[i].map, gmap, sizeof items[i].map);
    memcpy(items[i].uvc, guvc, sizeof items[i].uvc);
  }
  ad_run_updates_batch(items, n_upd, dt);
}

static double ad_next_dt(void) {
  if (ad_fixed_dt > 0.0) return ad_fixed_dt;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
  double dt = ad_last_time > 0.0 ? (now - ad_last_time) : (1.0 / 60.0);
  ad_last_time = now;
  if (dt < 0.0) dt = 0.0;
  if (dt > 0.1) dt = 0.1;
  return dt;
}

static void ad_finalize_frame(int whole_frame, uint64_t serial) {
  int settling = 0;
  for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
    mb_ad_slot *s = &ad_slots[i];
    if (!s->active) continue;
    if (whole_frame && s->seen_serial != serial) {
      s->active = 0;
      s->settle_left = 0.0;
      continue;
    }
    if (s->settle_left > 0.0 && ad_conv_serial[i] >= s->settle_serial) s->settle_left = 0.0;
    if (s->settle_left > 0.0) settling = 1;
  }
  __atomic_store_n(&ad_settling, settling, __ATOMIC_RELEASE);
}

static void gl_set_fixed_dt(double dt) { ad_fixed_dt = dt > 0.0 ? dt : 0.0; }
static void gl_adaptive_reset(void) { ad_forget(); }
static int gl_adaptive_settling(void) { return __atomic_load_n(&ad_settling, __ATOMIC_ACQUIRE); }

static void slots_invalidate(void) {
  for (int i = 0; i < MB_GLASS_SLOTS; i++) slots[i].valid = 0;
  kept_ok = 0;
}

static void glass_forget(void) {
  slots_invalidate();
  ad_forget();
}

// a new context has none of the old textures
static void glass_lost(void) {
  memset(lv, 0, sizeof lv);
  lv_w = lv_h = 0;
  lv_shrink_frames = lv_win_max_w = lv_win_max_h = 0;
  lv_frame_max_w = lv_frame_max_h = 0;
  memset(lens_lv, 0, sizeof lens_lv);
  lens_w = lens_h = 0;
  for (int i = 0; i < MB_GLASS_SLOTS; i++) {
    glass_slot *s = &slots[i];
    s->bt = s->bfb = 0;
    s->bw = s->bh = 0;
    s->bf = 0;
  }
  ad_tex[0] = ad_tex[1] = 0;
  ad_fb[0] = ad_fb[1] = 0;
  ad_cur = 0;
  memset(ad_rb, 0, sizeof ad_rb);
  ad_rb_i = 0;
  ad_rb_cur = -1;
  glass_forget();
}

static void shrink_levels(int w, int h) {
  for (int j = 0; j < 5; j++)
    if (lv[j].t) {
      glDeleteTextures(1, &lv[j].t);
      glDeleteFramebuffers(1, &lv[j].fb);
    }
  lv_w = w > 0 ? w : 1;
  lv_h = h > 0 ? h : 1;
  levels_rebuilt++;
  for (int j = 0; j < 4; j++)
    lv[j] = level_tex(j == 0 ? GL_RGBA8 : GL_RGB10_A2, (lv_w + (1 << j) - 1) >> j, (lv_h + (1 << j) - 1) >> j);
  lv[4] = level_tex(GL_RGB10_A2, lv_w, lv_h);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  for (int i = 0; i < MB_GLASS_SLOTS; i++) {
    glass_slot *s = &slots[i];
    if (!s->bt) continue;
    int sk = s->grab.progressive ? 0 : s->grab.k;
    int max_sw = (lv_w + (1 << sk) - 1) >> sk;
    int max_sh = (lv_h + (1 << sk) - 1) >> sk;
    if (!s->valid || s->bw > max_sw || s->bh > max_sh) {
      slot_drop_tex(s);
      s->valid = 0;
    }
  }
}

// The glass's own textures given back, in the context they were made in (current): the levels, the slots' copies and
// what each slot was of. The next capture makes what it needs again at its size (ensure_levels, slot_fill), its blur
// the same to the byte (a blur is of what is drawn under it, not of what was kept).
static void glass_free(void) {
  for (int j = 0; j < 5; j++)
    if (lv[j].t) {
      glDeleteTextures(1, &lv[j].t);
      glDeleteFramebuffers(1, &lv[j].fb);
    }
  for (int j = 0; j < 2; j++)
    if (lens_lv[j].t) {
      glDeleteTextures(1, &lens_lv[j].t);
      glDeleteFramebuffers(1, &lens_lv[j].fb);
    }
  for (int i = 0; i < MB_GLASS_SLOTS; i++) {
    glass_slot *s = &slots[i];
    if (s->bt) {
      glDeleteFramebuffers(1, &s->bfb);
      glDeleteTextures(1, &s->bt);
    }
    free(s->under);
    s->under = NULL;
    s->under_cap = s->under_n = 0;
  }
  for (int i = 0; i < 2; i++) {
    if (ad_fb[i]) glDeleteFramebuffers(1, &ad_fb[i]);
    if (ad_tex[i]) glDeleteTextures(1, &ad_tex[i]);
  }
  for (int i = 0; i < MB_AD_RB_N; i++) {
    if (ad_rb[i].fence) glDeleteSync(ad_rb[i].fence);
    if (ad_rb[i].pbo) glDeleteBuffers(1, &ad_rb[i].pbo);
  }
  bd_tex = 0;
  glass_lost();
}

// Glass's textures (its levels as big as the largest capture yet, a copy a slot) are given back once this many frames
// in a row drew no glass (a sheet closed, the composer gone): held on, they are tens of MB at a screen's size.
#define MB_GLASS_IDLE 180
static int glass_idle_frames;
static int glass_drawn;  // the frame drawing now reached glass (draw_into)

static void glass_idle_tick(void) {
  if (glass_drawn) {
    glass_idle_frames = 0;
    if (lv_w > 0 && lv_h > 0 && lv_frame_max_w > 0 && lv_frame_max_h > 0) {
      if (lv_frame_max_w > lv_win_max_w) lv_win_max_w = lv_frame_max_w;
      if (lv_frame_max_h > lv_win_max_h) lv_win_max_h = lv_frame_max_h;
      if (++lv_shrink_frames >= MB_GLASS_IDLE) {
        if ((size_t)lv_win_max_w * (size_t)lv_win_max_h * 2 < (size_t)lv_w * (size_t)lv_h) {
          shrink_levels(lv_win_max_w, lv_win_max_h);
        }
        lv_shrink_frames = 0;
        lv_win_max_w = lv_win_max_h = 0;
      }
    }
    lv_frame_max_w = lv_frame_max_h = 0;
  } else {
    lv_frame_max_w = lv_frame_max_h = 0;
    if (glass_idle_frames < MB_GLASS_IDLE && ++glass_idle_frames == MB_GLASS_IDLE && lv_w > 0) glass_free();
  }
  glass_drawn = 0;
}

// Whether instance i (its run of glass starting at `run`) draws anything in g (x0, y0, x1, y1, points): its quad as
// the vertex shader makes it (VS: grown round its rect, liquid glass over its group's bounds, rotated AABB when turned).
static int reaches(const float *f, int32_t i, int32_t run, const float g[4]) {
  const float *b = f + (size_t)i * MB_INST;
  int kind = (int)(b[5] + 0.5f);
  if (b[32] != 0.0f && kind == 6 && (b[23] > 0.0f || f[(size_t)run * MB_INST + 23] > 0.0f)) return 1;
  float e = kind == 2 ? fabsf(b[7]) * 3.0f + 2.0f : 1.0f;
  // (liquid: its group's bounds, each shape and the first's reach round it, 2 more: grab_of)
  if (kind == 6) e = fmaxf(fmaxf(b[23], f[(size_t)run * MB_INST + 23]), 0.0f) + 2.0f;
  e += 1.0f;
  float x0 = fminf(b[0], b[0] + b[2]) - e, x1 = fmaxf(b[0], b[0] + b[2]) + e;
  float y0 = fminf(b[1], b[1] + b[3]) - e, y1 = fmaxf(b[1], b[1] + b[3]) + e;
  if (b[32] != 0.0f) {
    float px = b[33], py = b[34], c = cosf(b[32]), s = sinf(b[32]);
    float dx[4] = {x0 - px, x1 - px, x0 - px, x1 - px};
    float dy[4] = {y0 - py, y0 - py, y1 - py, y1 - py};
    float rx0 = 1e30f, ry0 = 1e30f, rx1 = -1e30f, ry1 = -1e30f;
    for (int k = 0; k < 4; k++) {
      float rx = px + c * dx[k] - s * dy[k];
      float ry = py + s * dx[k] + c * dy[k];
      if (rx < rx0) rx0 = rx;
      if (rx > rx1) rx1 = rx;
      if (ry < ry0) ry0 = ry;
      if (ry > ry1) ry1 = ry;
    }
    x0 = rx0 - 1.0f; x1 = rx1 + 1.0f;
    y0 = ry0 - 1.0f; y1 = ry1 + 1.0f;
  }
  return x1 > g[0] && x0 < g[2] && y1 > g[1] && y0 < g[3];
}

// What the capture of the run at start is of (under_now): exact spatial dependency closure of every instance before
// start whose pixels (directly, or transitively through an earlier glass capture or adaptive ink sample) reach into
// the capture's rectangle, plus the frame's shapes' pieces (from `pieces` on). 0 when a stream or a native view's
// picture is among them.
static int under_take(const float *f, int32_t start, int32_t count, int32_t pieces, const Grab *m) {
  float sc = (float)cur_scale;
  float dep[4] = {(float)m->px0 / sc - 1.0f, (float)(m->top - (m->pb0 + m->h)) / sc - 1.0f,
                  (float)(m->px0 + m->w) / sc + 1.0f, (float)(m->top - m->pb0) / sc + 1.0f};
  float seen_tids[32];
  int seen_n = 0;
  for (int pass = 0; pass < 4; pass++) {
    int grew = 0;
    for (int32_t i = start - 1; i >= 0; i--) {
      const float *bi = f + (size_t)i * MB_INST;
      float tid = bi[20];
      int k = (int)(bi[5] + 0.5f);
      int is_glass = tid < 0.0f;
      int is_ad = k == 7 || ((k == 10 || k == 11) && bi[23] > 0.0f);
      if (!is_glass && !is_ad) continue;
      int32_t run = i;
      if (is_glass) {
        while (run > 0 && f[(size_t)(run - 1) * MB_INST + 20] == tid) run--;
      }
      if (!reaches(f, i, run, dep)) continue;
      if (is_glass) {
        int already = 0;
        for (int s = 0; s < seen_n; s++) {
          if (seen_tids[s] == tid) { already = 1; break; }
        }
        if (already) continue;
        if (seen_n < 32) seen_tids[seen_n++] = tid;
        int32_t first_i = run;
        for (int32_t j = 0; j < run; j++) {
          if (f[(size_t)j * MB_INST + 20] == tid) { first_i = j; break; }
        }
        const float *a = f + (size_t)first_i * MB_INST;
        int gkind = (int)(a[5] + 0.5f);
        int is_contained = (gkind == 5 && a[7] < 0.0f);
        float blur_r = (gkind == 6 && a[7] < 0.0f) ? 0.0f : fabsf(a[7]);
        int merged_liquid = (gkind == 6 && a[23] > 0.0f);
        int unmerged_liquid = (gkind == 6 && !merged_liquid);
        float margin = is_contained ? 0.0f : 3.0f * blur_r + (gkind == 6 ? a[21] * (1.0f + fabsf(a[22])) + fmaxf(a[23], 0.0f) : 0.0f) + 2.0f;
        float gx0 = 1e9f, gy0 = 1e9f, gx1 = -1e9f, gy1 = -1e9f;
        for (int32_t j = first_i; j < count; j++) {
          const float *b = f + (size_t)j * MB_INST;
          if (b[20] != tid) continue;
          float bx0, by0, bx1, by1;
          if (gkind == 6) {
            float m23 = fmaxf(unmerged_liquid ? b[23] : a[23], 0.0f);
            bx0 = b[0] - m23; by0 = b[1] - m23; bx1 = b[0] + b[2] + m23; by1 = b[1] + b[3] + m23;
            if (unmerged_liquid) {
              float bm = 3.0f * blur_r + b[21] * (1.0f + fabsf(b[22])) + m23 + 2.0f;
              if (bm > margin) margin = bm;
            }
          } else {
            bx0 = b[0] > b[16] ? b[0] : b[16]; by0 = b[1] > b[17] ? b[1] : b[17];
            bx1 = b[0] + b[2] < b[18] ? b[0] + b[2] : b[18]; by1 = b[1] + b[3] < b[19] ? b[1] + b[3] : b[19];
          }
          if (bx0 < gx0) gx0 = bx0;
          if (by0 < gy0) gy0 = by0;
          if (bx1 > gx1) gx1 = bx1;
          if (by1 > gy1) gy1 = by1;
        }
        if (gx1 > gx0 && gy1 > gy0) {
          float ex0 = gx0 - margin - 2.0f, ey0 = gy0 - margin - 2.0f;
          float ex1 = gx1 + margin + 2.0f, ey1 = gy1 + margin + 2.0f;
          if (ex0 < dep[0]) { dep[0] = ex0; grew = 1; }
          if (ey0 < dep[1]) { dep[1] = ey0; grew = 1; }
          if (ex1 > dep[2]) { dep[2] = ex1; grew = 1; }
          if (ey1 > dep[3]) { dep[3] = ey1; grew = 1; }
        }
      } else {
        float rad = fabsf(bi[23]) + 4.0f;
        float ex0 = bi[21] - rad, ey0 = bi[22] - rad;
        float ex1 = bi[21] + rad, ey1 = bi[22] + rad;
        if (ex0 < dep[0]) { dep[0] = ex0; grew = 1; }
        if (ey0 < dep[1]) { dep[1] = ey0; grew = 1; }
        if (ex1 > dep[2]) { dep[2] = ex1; grew = 1; }
        if (ey1 > dep[3]) { dep[3] = ey1; grew = 1; }
      }
    }
    if (!grew) break;
  }
  size_t most = ((size_t)start + (size_t)(count - pieces)) * MB_INST;
  if (under_now_cap < most) {
    under_now_cap = most;
    under_now = (float *)realloc(under_now, under_now_cap * sizeof(float));
  }
  float *o = under_now;
  int32_t picked = 0, run = 0;
  int has_shape = 0;
  for (int32_t i = 0; i < start; i++) {
    float tid = f[(size_t)i * MB_INST + 20];
    if (i > 0 && tid != f[(size_t)(i - 1) * MB_INST + 20]) run = i;
    if (!reaches(f, i, run, dep)) continue;
    if (tid > (float)MB_STREAM_TEX) return 0;
    if ((int)(f[(size_t)i * MB_INST + 5] + 0.5f) == 11) has_shape = 1;
    memcpy(o, f + (size_t)i * MB_INST, MB_INST * sizeof(float));
    o += MB_INST;
    picked++;
  }
  if (has_shape && count > pieces) {
    memcpy(o, f + (size_t)pieces * MB_INST, (size_t)(count - pieces) * MB_INST * sizeof(float));
    o += (size_t)(count - pieces) * MB_INST;
  }
  under_now_n = (size_t)(o - under_now);
  under_whole = 0;
  under_picked = picked;
  return 1;
}

// The slot whose blur is of what the capture now is (under_now), or none.
static glass_slot *slot_same(const Grab *m, const double key[9]) {
  for (int i = 0; i < MB_GLASS_SLOTS; i++) {
    glass_slot *s = &slots[i];
    if (s->valid && s->under_n == under_now_n && s->whole == under_whole && s->picked == under_picked &&
        memcmp(&s->grab, m, sizeof *m) == 0 && memcmp(s->key, key, sizeof s->key) == 0 &&
        memcmp(s->under, under_now, under_now_n * sizeof(float)) == 0)
      return s;
  }
  return NULL;
}

static void slots_evict_budget(int keep_idx, unsigned frame_clock, int allow_frame_slots) {
  while (slots_total_bytes() > MB_GLASS_CACHE_MAX_BYTES) {
    int victim = -1;
    for (int j = 0; j < MB_GLASS_SLOTS; j++) {
      if (j == keep_idx || !slots[j].bt) continue;
      if (!allow_frame_slots && slots[j].used > frame_clock) continue;
      if (victim < 0 || (!slots[j].valid && slots[victim].valid) ||
          (slots[j].valid == slots[victim].valid && slots[j].used < slots[victim].used)) {
        victim = j;
      }
    }
    if (victim < 0) break;
    slot_drop_tex(&slots[victim]);
    slots[victim].valid = 0;
  }
}

// The blur just made (blur) kept in the slot least lately shown: by swapping texture/FBO handles with the level
// (zero GPU blit) when the level is close to the grab's size, or copying only the grab's active bottom-left region
// into a compact 64-px-aligned slot texture when the shared level is much larger than the grab.
static glass_slot *slot_fill(const Grab *m, unsigned frame_clock) {
  level *L = grab_blurred(m);
  int lw[4], lh[4];
  grab_levels(m, lw, lh);
  int sk = m->progressive ? 0 : m->k;
  int gw = lw[sk] > 0 ? lw[sk] : 1;
  int gh = lh[sk] > 0 ? lh[sk] : 1;
  int Lw = L->w, Lh = L->h;
  int bw = (gw + 63) & ~63;
  int bh = (gh + 63) & ~63;
  if (bw > Lw) bw = Lw;
  if (bh > Lh) bh = Lh;
  if (bw < 1) bw = 1;
  if (bh < 1) bh = 1;
  size_t L_area = (size_t)Lw * (size_t)Lh;
  size_t b_area = (size_t)bw * (size_t)bh;
  int full_size = (bw >= Lw && bh >= Lh);
  int use_swap = full_size || (L_area <= 2 * b_area && glass_tex_bytes(Lw, Lh) <= MB_GLASS_CACHE_MAX_BYTES);
  int t0 = -1, t1 = -1, t2 = -1, t3 = -1, t4 = -1, fallback = 0;
  for (int i = 0; i < MB_GLASS_SLOTS; i++) {
    glass_slot *s = &slots[i];
    if (s->used < slots[fallback].used) fallback = i;
    if (s->used > frame_clock) continue;
    int has_bt = s->bt != 0;
    int reuse_tex = 0;
    if (use_swap) {
      reuse_tex = has_bt && s->bw == Lw && s->bh == Lh && s->bf == L->format;
    } else {
      reuse_tex = has_bt && s->bf == L->format && s->bw >= gw && s->bh >= gh &&
                  (size_t)s->bw * (size_t)s->bh <= 2 * b_area;
    }
    if (!s->valid) {
      if (reuse_tex) {
        if (t0 < 0) t0 = i;
      } else if (!has_bt) {
        if (t1 < 0) t1 = i;
      } else {
        if (t3 < 0) t3 = i;
      }
    } else if (reuse_tex) {
      if (t2 < 0 || s->used < slots[t2].used) t2 = i;
    }
    if (t4 < 0 || s->used < slots[t4].used) t4 = i;
  }
  int idx = t0 >= 0 ? t0 : t1 >= 0 ? t1 : t2 >= 0 ? t2 : t3 >= 0 ? t3 : t4 >= 0 ? t4 : fallback;
  glass_slot *s = &slots[idx];
  s->valid = 0;
  s->gen = ++slots_gen;
  if (use_swap) {
    if (s->bt != 0 && s->bw == Lw && s->bh == Lh && s->bf == L->format) {
      GLuint tmp_t = s->bt, tmp_fb = s->bfb;
      s->bt = L->t;
      s->bfb = L->fb;
      L->t = tmp_t;
      L->fb = tmp_fb;
    } else {
      slot_drop_tex(s);
      s->bt = L->t;
      s->bfb = L->fb;
      s->bw = Lw;
      s->bh = Lh;
      s->bf = L->format;
      *L = level_tex(s->bf, s->bw, s->bh);
    }
  } else {
    if (!(s->bt != 0 && s->bf == L->format && s->bw >= gw && s->bh >= gh &&
          (size_t)s->bw * (size_t)s->bh <= 2 * b_area)) {
      slot_drop_tex(s);
      level nl = level_tex(L->format, bw, bh);
      s->bt = nl.t;
      s->bfb = nl.fb;
      s->bw = nl.w;
      s->bh = nl.h;
      s->bf = nl.format;
    }
    glDisable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, L->fb);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, s->bfb);
#ifdef GL_ES_VERSION_3_0
    {
      const GLenum att = GL_COLOR_ATTACHMENT0;
      glInvalidateFramebuffer(GL_DRAW_FRAMEBUFFER, 1, &att);
    }
#endif
    glBlitFramebuffer(0, 0, gw, gh, 0, 0, gw, gh, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
  }
  slots_evict_budget(idx, frame_clock, 0);
  return s;
}

static void slot_show(const Grab *m, glass_slot *s) {
  s->used = ++slots_clock;
  show_blur(m, s->bt, s->bw, s->bh);
}

static void slot_keep(glass_slot *s, const Grab *m, const double key[9]) {
  if (s->under_cap < under_now_n) {
    s->under = (float *)realloc(s->under, under_now_n * sizeof(float));
    s->under_cap = under_now_n;
  }
  memcpy(s->under, under_now, under_now_n * sizeof(float));
  s->under_n = under_now_n;
  s->whole = under_whole;
  s->picked = under_picked;
  s->grab = *m;
  memcpy(s->key, key, sizeof s->key);
  s->valid = 1;
}

static void main_state(void);

typedef struct {
  int tid;
  glass_slot *slot;
  unsigned gen;
  Grab grab;
} gl_pre_hit;

// What the run [start, end) of glass sees (`pieces`: where the frame's shapes' pieces start, `r`, `g`, `b` the ground it
// was cleared to), blurred anew or as a slot keeps it; 0 when none of it shows. Leaves the main programs' state.
static int capture(const float *f, int32_t start, int32_t end, int32_t count, int32_t pieces, double r, double g,
                   double b, unsigned frame_clock, const gl_pre_hit *pre_hits, int pre_hits_n) {
  Grab m;
  int tid = (int)f[start * MB_INST + 20];
  int shows = 0;
  glass_slot *s = NULL;
  for (int h = 0; h < pre_hits_n; h++) {
    if (pre_hits[h].tid == tid) {
      glass_slot *hs = pre_hits[h].slot;
      if (hs && hs->valid && hs->bt && hs->gen == pre_hits[h].gen) {
        m = pre_hits[h].grab;
        shows = 1;
        s = hs;
      }
      break;
    }
  }
  double stretch_w = ((int)(cur_w * cur_scale + 0.5) != fb_w) ? cur_w : 0.0;
  double stretch_h = (vhp == fb_h && (int)(cur_h * cur_scale + 0.5) != fb_h) ? cur_h : 0.0;
  double key[9] = {fb_w, fb_h, cur_scale, r, g, b, over_other, stretch_w, stretch_h};
  int switched = 0;
  if (!s) shows = grab_of(&m, f, start, end, count);
  if (shows) {
    int reblurred = 0;
    if (!s) {
      int known = under_take(f, start, count, pieces, &m);
      s = known ? slot_same(&m, key) : NULL;
      if (!s) {
        reblurred = 1;
        switched = 1;
        blur(&m);
        s = slot_fill(&m, frame_clock);
        // (an image drawn under it that had no texture yet: it comes under the same instances, so this blur is not kept
        // to be shown again as theirs)
        if (known && !encode_missing) slot_keep(s, &m, key);
      }
    }
    kept_ok = s->valid;
    slot_show(&m, s);
    gl_ad_pend ad_pend[MB_ADAPTIVE_MAX];
    int ad_n_upd = ad_collect_and_match(f, start, end, count, &m, reblurred, ad_cur_dt, ad_frame_serial, ad_pend);
    if (ad_n_upd > 0) {
      switched = 1;
      ad_run_updates(ad_pend, ad_n_upd, ad_cur_dt);
    }
    ad_fill_uniforms();
  }
  if (switched) {
    main_state();
  } else if (shows) {
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, bd_tex ? bd_tex : atlas);
    prog_gen++;
  }
  return shows;
}

// The program for `group` (MB_PROG_*) used, compiled on first use, its uniforms set if they changed since it was last.
static void use_prog(int group) {
  int idx = (group >= 0 && group < MB_PROGS) ? group : MB_PROG_UI;
  kprog *k = &progs[idx];
  if (!k->p) {
    *k = make_prog(idx);
    k->gen = prog_gen - 1;
  }
  if (prog_now == k->p && k->gen == prog_gen) return;
  if (prog_now != k->p) {
    prog_now = k->p;
    glUseProgram(k->p);
  }
  if (k->gen == prog_gen) return;
  k->gen = prog_gen;
  if (k->vp >= 0) glUniform2f(k->vp, cur_vpw > 0.0f ? cur_vpw : (float)cur_w, cur_vph > 0.0f ? cur_vph : (float)cur_h);
  if (k->origin >= 0) glUniform2f(k->origin, cur_ox, cur_oy);
  if (k->scale >= 0) glUniform1f(k->scale, (float)cur_scale);
  if (k->map >= 0) glUniform4fv(k->map, 1, gmap);
  if (k->uvc >= 0) glUniform4fv(k->uvc, 1, guvc);
  if (k->gb >= 0) glUniform4fv(k->gb, 1, ggb);
  if (k->shape >= 0) glUniform4fv(k->shape, 8, gshape);
  if (k->rad >= 0) glUniform4fv(k->rad, 8, grad);
  if (k->n >= 0) glUniform1i(k->n, gn);
  if (k->glight >= 0) {
    float a = g_light_angle;
    glUniform2f(k->glight, cosf(a), sinf(a));
  }
  if (k->ad_box >= 0) glUniform4fv(k->ad_box, MB_ADAPTIVE_MAX, gad_box);
  if (k->ad_n >= 0) glUniform1i(k->ad_n, gad_n);
}

// the main programs' state (after the passes)
static void main_state(void) {
  glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
  glViewport(0, vy0, fb_w, vhp);
  if (cut_on) {
    glEnable(GL_SCISSOR_TEST);
    glScissor(cut[0], cut[1], cut[2], cut[3]);
  } else {
    glDisable(GL_SCISSOR_TEST);
  }
  glEnable(GL_BLEND);
  glBindVertexArray(vao);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glActiveTexture(GL_TEXTURE5);
  glBindTexture(GL_TEXTURE_2D, ad_tex[ad_cur] ? ad_tex[ad_cur] : atlas);
  glActiveTexture(GL_TEXTURE4);
  glBindTexture(GL_TEXTURE_2D, catlas);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, atlas);
  // (the shapes' pieces before the backdrop: the unit left active as it was, 2, which a stream's SurfaceTexture is
  // latched on as its picture is asked for: Streams.show)
  glActiveTexture(GL_TEXTURE3);
  glBindTexture(GL_TEXTURE_2D, segs_tex ? segs_tex : atlas);
  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, bd_tex ? bd_tex : atlas);
  // (the programs' uniforms as they are now: each set again as it is next used)
  prog_gen++;
  prog_now = 0;
}

// The pieces of the frame's shapes (src/ui/shape.mbt: the instances of kind 12 after every one drawn) into segs_tex.

static void segs_upload(int32_t count) {
  int32_t d = count;
  while (d > 0 && (int)(fbuf[(d - 1) * MB_INST + 5] + 0.5f) == 12) d--;
  if (d == count) return;
  int rows = (int)(((size_t)(count - d) * (MB_INST / 4) + SEGS_ROW - 1) / SEGS_ROW);
  const float *pieces = fbuf + (size_t)d * MB_INST;
  size_t n = (size_t)(count - d) * MB_INST;
  // (the same as the texture holds: nothing to upload)
  if (segs_tex && rows <= segs_rows && n == segs_had_n && memcmp(segs_had, pieces, n * sizeof(float)) == 0) return;
  if (n > segs_had_cap) {
    segs_had_cap = n * 2;
    segs_had = realloc(segs_had, segs_had_cap * sizeof(float));
  }
  memcpy(segs_had, pieces, n * sizeof(float));
  segs_had_n = n;
  glActiveTexture(GL_TEXTURE3);
  if (!segs_tex || rows > segs_rows) {
    if (segs_tex) glDeleteTextures(1, &segs_tex);
    glGenTextures(1, &segs_tex);
    glBindTexture(GL_TEXTURE_2D, segs_tex);
    segs_rows = rows * 2;
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, SEGS_ROW, segs_rows);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  }
  glBindTexture(GL_TEXTURE_2D, segs_tex);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, SEGS_ROW, rows, GL_RGBA, GL_FLOAT, fbuf + (size_t)d * MB_INST);
}

// The frame presented last, kept (in fbuf): its instances and its ground, drawn again as a native view's picture
// changes (Android's Native.redraw), the app not asked.
static int32_t kept_count;
static double kept_r, kept_g, kept_b;
static void draw_kept(void);

static void canvas_shown(void);

// Whether the frame kept draws a native view's picture into the canvas (Android's views, Linux's players): what it
// shows changes under the same instances, so the frame is drawn whole.
static int views_drawn_in(void) {
  for (int32_t i = 0; i < kept_count; i++) {
    int tid = (int)fbuf[i * MB_INST + 20];
    if (tid <= MB_VIEW_TEX) continue;
#ifdef MB_VIEWS_UNDER
    if (view_under(tid)) continue;
#endif
    return 1;
  }
  return 0;
}

// A frame presented (the host's mb_host_present, its glyphs in the atlases first): kept as floats, its groups' headers
// drawn out (groups.h), and drawn. A frame drawn whole (nothing said of its parts, all of it said, a picture missing
// from the last, a native view's picture in it) goes straight onto target_fb: through the canvas it would be drawn
// whole there and blitted again, every pixel read and written twice more (45 MB a frame of a fold's screen as a list
// scrolls), and a tiler's frame drawn whole on its chip is written out once. Glass reads what is drawn under it out of
// target_fb as well (capture: the surface's own framebuffer is read as GLES 3 reads any, its rows and the app's part,
// vy0 and vhp, the same). The canvas then holds no frame (canvas_ok): the first frame drawn in part after it is drawn
// whole into the canvas and shown, those after only the parts that differ.
static void gl_present_kept(int32_t count, double r, double g, double b);

// The floats a frame of `count` instances needs (`fbuf`'s room): its instances, its ground after them, and a row of
// the shapes' pieces more (segs_upload reads whole rows).
static size_t gl_frame_floats(int32_t count) {
  return (size_t)(count > 0 ? count : 0) * MB_INST + MB_INST + SEGS_ROW * 4;
}

static void gl_present(const double *buf, int32_t count, double r, double g, double b) {
  size_t n = gl_frame_floats(count);
  if (fcap < n) {
    fcap = n * 2;
    fbuf = (float *)realloc(fbuf, fcap * sizeof(float));
  }
  mb_groups_floats(fbuf, buf, count);
  gl_present_kept(count, r, g, b);
}

// The frame in fbuf (`count` instances as floats, its groups drawn out: gl_present's, or Android's made on the app's
// thread and handed over) kept and drawn, as gl_present says.
static void gl_present_drawn(int32_t count, double r, double g, double b);
static void gl_present_kept(int32_t count, double r, double g, double b) {
  ad_poll_readbacks();
  glass_drawn = 0;
  ad_mode = 1;
  ad_cur_dt = ad_next_dt();
  ad_frame_serial++;
  int whole = !dirty_told || dirty_whole || pictures_missing || views_drawn_in();
  if (!whole && gl_adaptive_settling()) {
    for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
      if (ad_slots[i].active && ad_slots[i].settle_left > 0.0)
        gl_dirty_add(ad_slots[i].cx - ad_slots[i].hx - 4.0, ad_slots[i].cy - ad_slots[i].hy - 4.0,
                     ad_slots[i].hx * 2.0 + 8.0, ad_slots[i].hy * 2.0 + 8.0);
    }
    if (!dirty_whole && !mb_glass_damage_expand(fbuf, count, dirty, &dirty_n, fb_w / cur_scale, fb_h / cur_scale,
                                                 cur_scale)) dirty_whole = 1;
  }
  gl_present_drawn(count, r, g, b);
  ad_rb_finish(ad_frame_serial);
  ad_finalize_frame(whole, ad_frame_serial);
  glass_idle_tick();
  // (the surface's context's first frame drawn: what it has no program of yet made ahead, not in a frame that first
  // needs it; never offscreen, which has no binary cache set: mbui-render's draws stay all on its thread)
  if (ahead_due && !offscreen && prog_cache_dir[0] != '\0') {
    ahead_due = 0;
#ifdef MB_PROGS_AHEAD
    pthread_mutex_lock(&ahead_mu);
    unsigned gen = ahead_gen, all = ahead_claimed == (1u << MB_SLOTS) - 1;
    pthread_mutex_unlock(&ahead_mu);
    if (!all) progs_ahead_start(gen);
#endif
  }
}

static int gl_adaptive_step(void) {
  if (!gl_adaptive_settling() || kept_count <= 0 || !fbuf) return 0;
  ad_poll_readbacks();
  int need = 0;
  for (int i = 0; i < MB_ADAPTIVE_MAX; i++) {
    mb_ad_slot *s = &ad_slots[i];
    if (!s->active || s->settle_left <= 0.0) continue;
    if (ad_conv_serial[i] >= s->settle_serial) {
      s->settle_left = 0.0;
    } else {
      need = 1;
    }
  }
  if (!need) {
    __atomic_store_n(&ad_settling, 0, __ATOMIC_RELEASE);
    if (!offscreen) {
      if (canvas_ok && canvas_fb) canvas_shown();
      else draw_kept();
    }
    return 0;
  }
  dirty_told = 1;
  dirty_whole = dirty_n = 0;
  gl_present_kept(kept_count, kept_r, kept_g, kept_b);
  return 1;
}

static void gl_present_drawn(int32_t count, double r, double g, double b) {
  kept_count = count;
  kept_r = r;
  kept_g = g;
  kept_b = b;
  if (views_drawn_in()) dirty_told = 0;
  if (offscreen) {
    draw_parts(target_fb, canvas_ok);
    canvas_ok = 1;
    return;
  }
  if (!dirty_told || dirty_whole || pictures_missing) {
    dirty_told = dirty_whole = dirty_n = 0;
    canvas_ok = 0;
    draw_into(target_fb, 0);
    pictures_missing = encode_missing;
    return;
  }
  ensure_canvas();
  if (!canvas_fb) {
    dirty_told = dirty_whole = dirty_n = 0;
    draw_into(target_fb, 0);
    return;
  }
  draw_parts(canvas_fb, canvas_ok);
  canvas_ok = 1;
  canvas_shown();
}

// The canvas onto the surface (target_fb), whole.
static void canvas_shown(void) {
  glDisable(GL_SCISSOR_TEST);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, canvas_fb);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target_fb);
  glBlitFramebuffer(0, 0, fb_w, fb_h, 0, 0, fb_w, fb_h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
}

// The frame presented last, drawn again into a framebuffer of its own the surface's size (as on the surface: what the
// surface holds is gone once it is shown): read_fb, bound as it returns.
static GLuint read_fb, read_tex;
static int read_w, read_h;

static void draw_kept_read(void) {
  if (!read_fb || read_w != fb_w || read_h != fb_h) {
    if (read_fb) {
      glDeleteFramebuffers(1, &read_fb);
      glDeleteTextures(1, &read_tex);
    }
    glGenTextures(1, &read_tex);
    glBindTexture(GL_TEXTURE_2D, read_tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
    glGenFramebuffers(1, &read_fb);
    glBindFramebuffer(GL_FRAMEBUFFER, read_fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, read_tex, 0);
    read_w = fb_w;
    read_h = fb_h;
  }
  int prev_ad_mode = ad_mode;
  if (ad_mode > 0) ad_mode = 0;
  draw_into(read_fb, 0);
  ad_mode = prev_ad_mode;
  glBindFramebuffer(GL_FRAMEBUFFER, read_fb);
}

// What drawing holds beyond what frames need given back (the window hidden, the app put away; its context current):
// glass's textures and the read back's framebuffer. A frame after makes what it needs again as it draws.
void mb_render_trim(void) {
  glass_free();
  glass_idle_frames = 0;
  if (read_fb) {
    glDeleteFramebuffers(1, &read_fb);
    glDeleteTextures(1, &read_tex);
    read_fb = read_tex = 0;
    read_w = read_h = 0;
  }
}

// That frame's pixels in the rectangle x, y, w × h (from the top left) into `out` as RGBA, premultiplied, rows from
// the top (host_native.mbt drawn_pixels; on the thread MoonBit runs on, its context current): 1 when read, 0 where the
// rectangle is not all in the frame.
static int32_t gles_drawn_pixels(int32_t x, int32_t y, int32_t w, int32_t h, moonbit_bytes_t out) {
  if (kept_count <= 0 || fb_w <= 0 || fb_h <= 0 || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > fb_w || y + h > fb_h)
    return 0;
  if ((size_t)Moonbit_array_length(out) < (size_t)w * h * 4) return 0;
  GLuint was = target_fb;
  draw_kept_read();
  size_t row = (size_t)w * 4;
  unsigned char *px = malloc(row * h);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fb);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  // (GL's rows from the foot: the app's top is the surface's)
  glReadPixels(x, fb_h - y - h, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  for (int r = 0; r < h; r++) memcpy(out + row * r, px + row * (h - 1 - r), row);
  free(px);
  glBindFramebuffer(GL_FRAMEBUFFER, was);
  return 1;
}

// Instances never presented (a shot's, mbui/src/ui/shot.mbt) drawn as a frame is, but `scale` pixels a point into a
// picture of their own w × h (their 0, 0 its top left), on the ground r, g, b, and its pixels into `out` as
// mb_render_drawn_pixels gives the frame's: the frame kept, and the size frames are drawn at, set aside while they are
// drawn in its place, then put back (what a native view's picture redraws is the frame as it was). 1 when read.
static int32_t gles_pixels_of(const double *inst, int32_t count, double r, double g, double b, double scale,
                              int32_t w, int32_t h, moonbit_bytes_t out) {
  if (count <= 0 || !(scale > 0) || w <= 0 || h <= 0) return 0;
  float *kf = fbuf;
  size_t kc = fcap;
  int32_t kn = kept_count;
  double kr = kept_r, kg = kept_g, kb = kept_b;
  int kfw = fb_w, kfh = fb_h;
  double kw = cur_w, kh = cur_h, ks = cur_scale;
  size_t n = (size_t)count * MB_INST;
  // (a row of the shapes' pieces more: segs_upload reads whole rows)
  fcap = n + SEGS_ROW * 4;
  fbuf = malloc(fcap * sizeof(float));
  for (size_t i = 0; i < n; i++) fbuf[i] = (float)inst[i];
  kept_count = count;
  kept_r = r;
  kept_g = g;
  kept_b = b;
  fb_w = w;
  fb_h = h;
  cur_scale = scale;
  cur_w = w / scale;
  cur_h = h / scale;
  int prev_ad_mode = ad_mode;
  ad_mode = -1;
  int32_t ok = gles_drawn_pixels(0, 0, w, h, out);
  ad_mode = prev_ad_mode;
  free(fbuf);
  fbuf = kf;
  fcap = kc;
  kept_count = kn;
  kept_r = kr;
  kept_g = kg;
  kept_b = kb;
  fb_w = kfw;
  fb_h = kfh;
  cur_w = kw;
  cur_h = kh;
  cur_scale = ks;
  return ok;
}

#ifndef MB_HOST_THREADS
int32_t mb_render_drawn_pixels(int32_t x, int32_t y, int32_t w, int32_t h, moonbit_bytes_t out) {
  return gles_drawn_pixels(x, y, w, h, out);
}

int32_t mb_render_pixels_of(const double *inst, int32_t count, double r, double g, double b, double scale, int32_t w,
                            int32_t h, moonbit_bytes_t out) {
  return gles_pixels_of(inst, count, r, g, b, scale, w, h, out);
}
#endif

// The frame kept drawn whole onto the surface again (a native view's picture changed: Android's Native.redraw),
// straight onto it as a frame presented whole is (gl_present): the canvas then holds no frame.
static void draw_kept(void) {
  draw_into(target_fb, 0);
  if (!offscreen) canvas_ok = 0;
}

// The frame kept drawn into framebuffer `fb` (the surface's size): `part` 1, only the part `cut` over what it holds
// (the frame's ground there first), else all of it, cleared to the ground. Whether a picture was missing in
// encode_missing.
// Instances first to first + n drawn (GLES has no base instance: the attributes start at the first).
static void draw_run(int32_t first, int32_t n) {
  for (int i = 0; i < MB_INST / 4; i++)
    glVertexAttribPointer(i, 4, GL_FLOAT, GL_FALSE, MB_INST * 4, (void *)(intptr_t)(first * MB_INST * 4 + i * 16));
  glDrawArraysInstanced(GL_TRIANGLES, 0, 6, n);
}

// Instances start to end drawn, each that pays for it in strips (bands.h), the
// rest as they come.
static void draw_banded(int32_t start, int32_t end, int32_t count) {
  int top = vy0 + vhp;
  MBStrip to = cut_on ? mb_strip(cut[0], top - (cut[1] + cut[3]), cut[0] + cut[2], top - cut[1]) : mb_strip(0, 0, fb_w, vhp);
  MBStrip st[MB_STRIPS];
  int32_t s = start;
  for (int32_t i = start; i < end; i++) {
    if (!mb_band_kind(fbuf, i)) continue;
    int n = mb_bands(fbuf, i, count, (float)cur_scale, to, st);
    if (n < 0) continue;
    if (i > s) draw_run(s, i - s);
    glEnable(GL_SCISSOR_TEST);
    for (int k = 0; k < n; k++) {
      if (k == 0 || st[k].flat != st[k - 1].flat) {
        if (st[k].flat) {
          ensure_prog_flat();
          glUseProgram(prog_flat);
          glUniform2f(uf_vp, (float)cur_w, (float)cur_h);
        } else {
          glUseProgram(prog_now);
        }
      }
      glScissor(st[k].x0, top - st[k].y1, st[k].x1 - st[k].x0, st[k].y1 - st[k].y0);
      draw_run(i, 1);
    }
    if (n > 0 && st[n - 1].flat) glUseProgram(prog_now);
    if (cut_on) glScissor(cut[0], cut[1], cut[2], cut[3]);
    else glDisable(GL_SCISSOR_TEST);
    s = i + 1;
  }
  if (end > s) draw_run(s, end - s);
}

// Whether a grab's rectangle meets pixel rect r (GL bottom-left: x, y, w, h).
static int grab_in_rect(const Grab *m, const int r[4]) {
  return m->px0 < r[0] + r[2] && r[0] < m->px0 + m->w &&
         m->pb0 < r[1] + r[3] && r[1] < m->pb0 + m->h;
}

static int grab_in_cut(const Grab *m) {
  return !cut_on || grab_in_rect(m, cut);
}

static int grab_in_any_rect(const Grab *m, const int (*rects)[4], int n_rects) {
  if (!rects || n_rects < 0) return 1;
  for (int i = 0; i < n_rects; i++) {
    if (grab_in_rect(m, rects[i])) return 1;
  }
  return 0;
}

// Conservative CPU scissor test for non-glass instance `b` against top-down pixel rect [rx0, ry0, rx1, ry1).
// Matches VS grow (kind 2 shadow blur, kind 0/4/5/8 1pt AA), intersects a_clip (16..19) and active a_oclip (40..43
// when a_orc 44..47 > 0), and keeps all rotated instances (b[32] != 0) plus a +/- 2px safety margin.
#define MB_CULL_SPLIT_GAP 16
static int inst_in_px_rect(const float *b, float sx, float sy, int rx0, int ry0, int rx1, int ry1) {
  int kind = (int)(b[5] + 0.5f);
  if (kind == 12) return 0;
  if (b[32] != 0.0f) return 1;
  float grow = kind == 2 ? fabsf(b[7]) * 3.0f + 2.0f
             : (kind == 6 && b[23] <= 0.0f) ? 2.0f
             : ((kind == 0 || kind == 4 || kind == 5 || kind == 8) ? 1.0f : 0.0f);
  float x0 = fminf(b[0], b[0] + b[2]) - grow;
  float x1 = fmaxf(b[0], b[0] + b[2]) + grow;
  float y0 = fminf(b[1], b[1] + b[3]) - grow;
  float y1 = fmaxf(b[1], b[1] + b[3]) + grow;
  float cpad = (b[24] > 0.0f || b[25] > 0.0f || b[26] > 0.0f || b[27] > 0.0f) ? 1.0f : 0.0f;
  float cx0 = b[16] - cpad, cy0 = b[17] - cpad, cx1 = b[18] + cpad, cy1 = b[19] + cpad;
  if (cx0 > x0) x0 = cx0;
  if (cy0 > y0) y0 = cy0;
  if (cx1 < x1) x1 = cx1;
  if (cy1 < y1) y1 = cy1;
  if (b[44] > 0.0f || b[45] > 0.0f || b[46] > 0.0f || b[47] > 0.0f) {
    float ox0 = b[40] - 1.0f, oy0 = b[41] - 1.0f, ox1 = b[42] + 1.0f, oy1 = b[43] + 1.0f;
    if (ox0 > x0) x0 = ox0;
    if (oy0 > y0) y0 = oy0;
    if (ox1 < x1) x1 = ox1;
    if (oy1 < y1) y1 = oy1;
  }
  if (x1 <= x0 || y1 <= y0) return 0;
  float px0 = x0 * sx - 2.0f, py0 = y0 * sy - 2.0f;
  float px1 = x1 * sx + 2.0f, py1 = y1 * sy + 2.0f;
  return px1 > (float)rx0 && px0 < (float)rx1 && py1 > (float)ry0 && py0 < (float)ry1;
}

static void draw_into_rects(GLuint fb, const int (*rects)[4], int n_rects) {
  int32_t count = kept_count;
  double r = kept_r, g = kept_g, b = kept_b;
  int is_partial = (rects != NULL && n_rects > 0);
  if (rects != NULL && n_rects == 0) return;
  GLuint was = target_fb;
  target_fb = fb;
  encode_missing = 0;
  cut_on = 0;
  // the app drawn in the surface's top part, as tall as it was told (the soft keyboard over the rest: MBView)
  int vh = (int)(cur_h * cur_scale + 0.5);
  vy0 = 0;
  vhp = fb_h;
  if (vh > 0 && vh < fb_h) {
    vy0 = fb_h - vh;
    vhp = vh;
  }
  // (where the pieces of the frame's shapes start: what a capture is of, with what is before it)
  int32_t pieces = count;
  while (pieces > 0 && (int)(fbuf[(pieces - 1) * MB_INST + 5] + 0.5f) == 12) pieces--;
  // Pre-scan glass captures once per frame (covering all dirty rects when partial): size blur levels once, and batch
  // adaptive updates for blur-cache-hit groups into a single pass so tile-based GPUs do not split the main FBO pass.
  int levels_sized = 0;
  gl_pre_hit pre_hits[16];
  int pre_hits_n = 0;
  if (count > 0) {
    int max_w = 0, max_h = 0, all_max_w = 0, all_max_h = 0, scan_bound = 0, any_glass = 0;
    for (int32_t s0 = 0; s0 < count;) {
      int stid = (int)fbuf[s0 * MB_INST + 20];
      int32_t e0 = s0 + 1;
      if (stid < 0) {
        any_glass = 1;
        while (e0 < count && (int)fbuf[e0 * MB_INST + 20] == stid) e0++;
        if (stid != scan_bound) {
          scan_bound = stid;
          Grab gm;
          if (grab_of(&gm, fbuf, s0, e0, count)) {
            if (gm.w > all_max_w) all_max_w = gm.w;
            if (gm.h > all_max_h) all_max_h = gm.h;
            if (!is_partial || grab_in_any_rect(&gm, rects, n_rects)) {
              if (gm.w > max_w) max_w = gm.w;
              if (gm.h > max_h) max_h = gm.h;
            }
          }
        }
      }
      s0 = e0;
    }
    if (any_glass) {
      levels_sized = 1;
      if (max_w > lv_w || max_h > lv_h) {
        ensure_levels(max_w, max_h);
        main_state();
      } else if (ad_mode > 0 && lv[0].t && all_max_w > 0 && all_max_h > 0) {
        if (all_max_w > lv_frame_max_w) lv_frame_max_w = all_max_w;
        if (all_max_h > lv_frame_max_h) lv_frame_max_h = all_max_h;
      }
      if (ad_mode > 0 && ad_cur_dt >= 0.0) {
        gl_ad_batch pre_batch[MB_ADAPTIVE_MAX];
        int pre_n = 0;
        double stretch_w = ((int)(cur_w * cur_scale + 0.5) != fb_w) ? cur_w : 0.0;
        double stretch_h = (vhp == fb_h && (int)(cur_h * cur_scale + 0.5) != fb_h) ? cur_h : 0.0;
        double key[9] = {fb_w, fb_h, cur_scale, r, g, b, over_other, stretch_w, stretch_h};
        int pre_bound = 0;
        for (int32_t s0 = 0; s0 < count;) {
          int stid = (int)fbuf[s0 * MB_INST + 20];
          int32_t e0 = s0 + 1;
          if (stid < 0) {
            while (e0 < count && (int)fbuf[e0 * MB_INST + 20] == stid) e0++;
            if (stid != pre_bound) {
              pre_bound = stid;
              int skind = (int)(fbuf[s0 * MB_INST + 5] + 0.5f);
              if (skind == 5 || skind == 6) {
                Grab gm;
                if (grab_of(&gm, fbuf, s0, e0, count) && (!is_partial || grab_in_any_rect(&gm, rects, n_rects)) &&
                    under_take(fbuf, s0, count, pieces, &gm)) {
                  glass_slot *sl = slot_same(&gm, key);
                  if (sl && sl->bt) {
                    if (pre_hits_n < 16) {
                      pre_hits[pre_hits_n].tid = stid;
                      pre_hits[pre_hits_n].slot = sl;
                      pre_hits[pre_hits_n].gen = sl->gen;
                      pre_hits[pre_hits_n].grab = gm;
                      pre_hits_n++;
                    }
                    if (skind == 6 && pre_n < MB_ADAPTIVE_MAX) {
                      gl_ad_pend tmp[MB_ADAPTIVE_MAX];
                      int nu = ad_collect_and_match(fbuf, s0, e0, count, &gm, 0, ad_cur_dt, ad_frame_serial, tmp);
                      if (nu > 0) {
                        float map[4], uvc[4];
                        grab_map_uvc(&gm, sl->bw, sl->bh, map, uvc);
                        for (int i = 0; i < nu && pre_n < MB_ADAPTIVE_MAX; i++) {
                          pre_batch[pre_n].p = tmp[i];
                          pre_batch[pre_n].bt = sl->bt;
                          memcpy(pre_batch[pre_n].map, map, sizeof map);
                          memcpy(pre_batch[pre_n].uvc, uvc, sizeof uvc);
                          pre_n++;
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          s0 = e0;
        }
        if (pre_n > 0) ad_run_updates_batch(pre_batch, pre_n, ad_cur_dt);
      }
    }
  }
  glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
  glViewport(0, 0, fb_w, fb_h);
  if (!is_partial) {
    glDisable(GL_SCISSOR_TEST);
    if (over_other) glClearColor(0, 0, 0, 0);
    else glClearColor((float)r, (float)g, (float)b, 1);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  glViewport(0, vy0, fb_w, vhp);
  if (count <= 0 && !is_partial) {
    target_fb = was;
    return;
  }
  size_t n = (size_t)count * MB_INST;
  // Upload shape segments and the instance VBO once per frame, shared across all dirty-rect passes.
  segs_upload(count);
  glBindVertexArray(vao);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  if (n > 0) glBufferData(GL_ARRAY_BUFFER, n * sizeof(float), fbuf, GL_STREAM_DRAW);
  unsigned frame_clock = slots_clock;
  int top = vy0 + vhp;
  float sx = cur_w > 0.0 ? (float)fb_w / (float)cur_w : (float)cur_scale;
  float sy = cur_h > 0.0 ? (float)vhp / (float)cur_h : (float)cur_scale;
  int pass_n = is_partial ? n_rects : 1;
  for (int pi = 0; pi < pass_n; pi++) {
    cut_on = is_partial;
    if (is_partial) memcpy(cut, rects[pi], sizeof cut);
    bd_tex = 0;
    memset(gmap, 0, sizeof gmap);
    memset(guvc, 0, sizeof guvc);
    memset(ggb, 0, sizeof ggb);
    gn = 0;
    ad_fill_uniforms();
    main_state();
    if (cut_on) {
      if (over_other) glClearColor(0, 0, 0, 0);
      else glClearColor((float)r, (float)g, (float)b, 1);
      glClear(GL_COLOR_BUFFER_BIT);
    }
    int rx0 = cut_on ? cut[0] : 0;
    int rx1 = cut_on ? cut[0] + cut[2] : fb_w;
    int ry0 = cut_on ? top - (cut[1] + cut[3]) : 0;
    int ry1 = cut_on ? top - cut[1] : vhp;
    // one draw per run of instances showing the same image (slot 20; 0: none, the atlas stands in; a native view's
    // picture where it shows, kind 9: nothing until it has one) of one kind (its program: use_prog), or sharing one
    // capture of glass (negative); GLES has no base instance, so the attributes start at the run instead
    int32_t start = 0;
    int bound = 0, shows = 0;
    while (start < count) {
      int tid = (int)fbuf[start * MB_INST + 20];
      int kind = (int)(fbuf[start * MB_INST + 5] + 0.5f);
      if (kind == 8) {
        int32_t child_n = (int32_t)(fbuf[start * MB_INST + 12] + 0.5f);
        if (child_n < 0) child_n = 0;
        if (start + 1 + child_n > count) child_n = count - start - 1;
        const float *hb = fbuf + (size_t)start * MB_INST;
        if (child_n <= 0 || hb[11] <= 0.001f || hb[2] <= 0.0f || hb[3] <= 0.0f) {
          start += 1 + child_n;
          continue;
        }
        glass_drawn = 1;
        float sc_f = (float)cur_scale;
        float blur_pt = fmaxf(hb[7], 0.0f);
        float refr_pt = fmaxf(hb[14], 0.0f);
        float margin = blur_pt * 3.0f + refr_pt + 4.0f;
        float x0 = hb[0], y0 = hb[1], x1 = hb[0] + hb[2], y1 = hb[1] + hb[3];
        for (int32_t ci = start + 1; ci < start + 1 + child_n; ci++) {
          const float *cb_f = fbuf + (size_t)ci * MB_INST;
          int ck = (int)(cb_f[5] + 0.5f);
          if (ck == 12 || cb_f[2] <= 0.0f || cb_f[3] <= 0.0f) continue;
          if (cb_f[0] < x0) x0 = cb_f[0];
          if (cb_f[1] < y0) y0 = cb_f[1];
          if (cb_f[0] + cb_f[2] > x1) x1 = cb_f[0] + cb_f[2];
          if (cb_f[1] + cb_f[3] > y1) y1 = cb_f[1] + cb_f[3];
        }
        float ox = floorf((x0 - margin) * sc_f) / sc_f;
        float oy = floorf((y0 - margin) * sc_f) / sc_f;
        int pw = (int)ceilf(((x1 + margin) - ox) * sc_f);
        int ph = (int)ceilf(((y1 + margin) - oy) * sc_f);
        int max_w = fb_w > 2048 ? fb_w : 2048;
        int max_h = fb_h > 2048 ? fb_h : 2048;
        if (pw < 1) pw = 1;
        if (ph < 1) ph = 1;
        if (pw > max_w) pw = max_w;
        if (ph > max_h) ph = max_h;
        if (cut_on && hb[32] == 0.0f) {
          int lx0 = (int)floorf(ox * sx) - 2;
          int ly0 = (int)floorf(oy * sy) - 2;
          int lx1 = (int)ceilf((ox + (float)pw / sc_f) * sx) + 2;
          int ly1 = (int)ceilf((oy + (float)ph / sc_f) * sy) + 2;
          if (lx1 <= rx0 || lx0 >= rx1 || ly1 <= ry0 || ly0 >= ry1) {
            start += 1 + child_n;
            continue;
          }
        }
        ensure_lens_levels(pw, ph);
        GLuint prev_bd = bd_tex;
        // Pass 1: render children into lens_lv[0]
        glBindFramebuffer(GL_FRAMEBUFFER, lens_lv[0].fb);
        // (u_bd off any lens level: one bound there by a lens before is drawn into now)
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, atlas);
        glViewport(0, 0, pw, ph);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        cur_ox = ox; cur_oy = oy; cur_vpw = (float)pw / sc_f; cur_vph = (float)ph / sc_f;
        prog_gen++;
        int32_t cs = start + 1, cend_all = start + 1 + child_n;
        while (cs < cend_all) {
          int ctid = (int)fbuf[cs * MB_INST + 20];
          int ck = (int)(fbuf[cs * MB_INST + 5] + 0.5f);
          if (ck == 5 || ck == 6 || ck == 8 || ck == 9 || ck == 12 || ctid < 0) {
            cs++;
            continue;
          }
          int cgrp = prog_group_of(ck, fbuf[cs * MB_INST + 23]);
          int32_t ce = cs + 1;
          while (ce < cend_all && (int)fbuf[ce * MB_INST + 20] == ctid) {
            int kk = (int)(fbuf[ce * MB_INST + 5] + 0.5f);
            if (kk == 5 || kk == 6 || kk == 8 || kk == 9 || kk == 12) break;
            if (prog_group_of(kk, fbuf[ce * MB_INST + 23]) != cgrp) break;
            ce++;
          }
          GLuint ct = ctid ? image_tex(ctid) : atlas;
          if (ctid > MB_STREAM_TEX && !ct) { cs = ce; continue; }
          if (ctid > 0 && ctid <= MB_STREAM_TEX && !ct) encode_missing = 1;
          glActiveTexture(GL_TEXTURE1);
          glBindTexture(GL_TEXTURE_2D, ct ? ct : atlas);
          use_prog(cgrp);
          draw_run(cs, ce - cs);
          cs = ce;
        }
        // Pass 2: separable Gaussian blur in RGBA8
        float sp = blur_pt * sc_f;
        if (sp > 0.25f) {
          glDisable(GL_BLEND);
          ensure_post();
          glUseProgram(post);
          unbind_post_extra();
          post_pass(&lens_lv[0], pw, ph, &lens_lv[1], pw, ph, 2, sp, 1.0f, 0.0f);
          post_pass(&lens_lv[1], pw, ph, &lens_lv[0], pw, ph, 2, sp, 0.0f, 1.0f);
        }
        // Pass 3: composite refracted & SDF-clipped foreground lens onto target
        cur_ox = 0.0f; cur_oy = 0.0f; cur_vpw = 0.0f; cur_vph = 0.0f;
        bd_tex = lens_lv[0].t;
        float W = (float)lens_lv[0].w, H = (float)lens_lv[0].h;
        gmap[0] = sc_f / W; gmap[1] = -sc_f / H;
        gmap[2] = -(ox * sc_f) / W; gmap[3] = ((float)ph + oy * sc_f) / H;
        guvc[0] = 0.5f / W; guvc[1] = 0.5f / H;
        guvc[2] = ((float)pw - 0.5f) / W; guvc[3] = ((float)ph - 0.5f) / H;
        main_state();
        use_prog(MB_PROG_LENS);
        draw_run(start, 1);
        bd_tex = prev_bd;
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, bd_tex ? bd_tex : atlas);
        bound = 0;
        start += 1 + child_n;
        continue;
      }
      if (kind == 12) {
        start++;
        continue;
      }
      // Consecutive instances sharing `tid` and `prog_group_of` draw in one batched instanced run.
      int grp = prog_group_of(kind, fbuf[start * MB_INST + 23]);
      int32_t end = start + 1;
      while (end < count && (int)fbuf[end * MB_INST + 20] == tid) {
        int k = (int)(fbuf[end * MB_INST + 5] + 0.5f);
        if (k == 8 || k == 12) break;
        if (tid >= 0 && prog_group_of(k, fbuf[end * MB_INST + 23]) != grp) break;
        end++;
      }
      if (tid < 0) {
        glass_drawn = 1;
        if (!levels_sized) {
          levels_sized = 1;
          int max_w = 0, max_h = 0, scan_bound = 0;
          for (int32_t s0 = start; s0 < count;) {
            int stid = (int)fbuf[s0 * MB_INST + 20];
            int32_t e0 = s0 + 1;
            if (stid < 0) {
              while (e0 < count && (int)fbuf[e0 * MB_INST + 20] == stid) e0++;
              if (stid != scan_bound) {
                scan_bound = stid;
                Grab gm;
                if (grab_of(&gm, fbuf, s0, e0, count) && (!is_partial || grab_in_any_rect(&gm, rects, n_rects))) {
                  if (gm.w > max_w) max_w = gm.w;
                  if (gm.h > max_h) max_h = gm.h;
                }
              }
            }
            s0 = e0;
          }
          if (max_w > lv_w || max_h > lv_h) {
            ensure_levels(max_w, max_h);
            main_state();
          }
        }
        if (tid != bound) {
          int in_cut = 1;
          if (cut_on) {
            Grab gm;
            int found = 0;
            for (int h = 0; h < pre_hits_n; h++) {
              if (pre_hits[h].tid == tid) {
                gm = pre_hits[h].grab;
                found = 1;
                break;
              }
            }
            if (!found) found = grab_of(&gm, fbuf, start, end, count);
            in_cut = found && grab_in_cut(&gm);
          }
          shows = in_cut ? capture(fbuf, start, end, count, pieces, r, g, b, frame_clock, pre_hits, pre_hits_n) : 0;
          bound = tid;
        }
        if (shows) {
          // merged liquid (merge > 0): the group as one shape, drawn once; unmerged liquid and frosted: each instance
          int merged_liquid = kind == 6 && fbuf[start * MB_INST + 23] > 0.0f;
          use_prog(prog_group_of(kind, fbuf[start * MB_INST + 23]));
          for (int i = 0; i < MB_INST / 4; i++)
            glVertexAttribPointer(i, 4, GL_FLOAT, GL_FALSE, MB_INST * 4, (void *)(intptr_t)(start * MB_INST * 4 + i * 16));
          glDrawArraysInstanced(GL_TRIANGLES, 0, 6, merged_liquid ? 1 : end - start);
        }
        start = end;
        continue;
      }
      GLuint t = tid ? image_tex(tid) : atlas;
      if (!t && tid > 0 && tid <= MB_STREAM_TEX) encode_missing = 1;
      if (t) {  // 0: lost with the context, decoding again; a stream's or a view's with no picture yet
        if (tid > MB_VIEW_TEX) {
          view_parts_in(tid, start, end);
          use_prog(grp);
          glActiveTexture(GL_TEXTURE1);
          glBindTexture(GL_TEXTURE_2D, t);
#ifdef MB_VIEWS_UNDER
          // (a view under the surface: its picture a white texel, so what kind 9 draws is how much of each pixel it
          // covers, and that much of the canvas is taken away there: a hole the view shows through, its round edge as
          // soft as a drawn one's; what is drawn after it draws over it)
          int under = view_under(tid);
          if (under) glBlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_ALPHA);
#endif
          draw_run(start, end - start);
#ifdef MB_VIEWS_UNDER
          if (under) glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
#endif
        } else if (!cut_on) {
          use_prog(grp);
          glActiveTexture(GL_TEXTURE1);
          glBindTexture(GL_TEXTURE_2D, t);
          if (tid == 0) draw_banded(start, end, count);
          else draw_run(start, end - start);
        } else {
          int bound_run = 0;
          int32_t cur = start;
          while (cur < end) {
            while (cur < end && !inst_in_px_rect(fbuf + (size_t)cur * MB_INST, sx, sy, rx0, ry0, rx1, ry1)) cur++;
            if (cur >= end) break;
            int32_t lo = cur, hi = cur + 1;
            int32_t j = hi;
            while (j < end) {
              if (inst_in_px_rect(fbuf + (size_t)j * MB_INST, sx, sy, rx0, ry0, rx1, ry1)) {
                hi = j + 1;
              } else if (j - hi + 1 >= MB_CULL_SPLIT_GAP) {
                break;
              }
              j++;
            }
            if (!bound_run) {
              use_prog(grp);
              glActiveTexture(GL_TEXTURE1);
              glBindTexture(GL_TEXTURE_2D, t);
              bound_run = 1;
            }
            if (tid == 0) draw_banded(lo, hi, count);
            else draw_run(lo, hi - lo);
            cur = j + 1;
          }
        }
      }
      start = end;
    }
  }
  if (levels_sized && slots_total_bytes() > MB_GLASS_CACHE_MAX_BYTES) slots_evict_budget(-1, frame_clock, 1);
  if (cut_on) glDisable(GL_SCISSOR_TEST);
  cut_on = 0;
  target_fb = was;
}

static void draw_into(GLuint fb, int part) {
  if (part == 1) draw_into_rects(fb, (const int (*)[4])&cut, 1);
  else draw_into_rects(fb, NULL, -1);
}

// ---------------------------------------------------------------------------
// Without the surface (mbui-render, src/render: a frame drawn as on the surface, read back as a PNG): a framebuffer of
// its own the size the surface would be, drawn into.

static GLuint off_tex;

static void gl_offscreen(double w, double h, double scale) {
  offscreen = 1;
  cur_w = w;
  cur_h = h;
  cur_scale = scale;
  fb_w = (int)floor(w * scale + 0.5);
  fb_h = (int)floor(h * scale + 0.5);
  glGenTextures(1, &off_tex);
  glBindTexture(GL_TEXTURE_2D, off_tex);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fb_w, fb_h);
  glGenFramebuffers(1, &target_fb);
  glBindFramebuffer(GL_FRAMEBUFFER, target_fb);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, off_tex, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) LOG("mbui-render: no framebuffer");
}

// The offscreen framebuffer as its frames left it (not the last frame drawn again: what drawing only the parts that
// differ made of it, mbui-render's MBUI_DL_FROM), as a PNG.
static int gl_png(const char *path, GLuint fb);

int mb_render_snapshot_drawn(const char *path) { return offscreen && target_fb ? gl_png(path, target_fb) : 0; }

static void png_chunk(FILE *f, const char *type, const unsigned char *data, uint32_t n) {
  unsigned char be[4] = {n >> 24, n >> 16, n >> 8, n};
  fwrite(be, 1, 4, f);
  fwrite(type, 1, 4, f);
  if (n) fwrite(data, 1, n, f);
  uLong c = crc32(0, (const Bytef *)type, 4);
  if (n) c = crc32(c, data, n);
  unsigned char cb[4] = {c >> 24, c >> 16, c >> 8, c};
  fwrite(cb, 1, 4, f);
}

// What framebuffer `fb` holds (the surface's size) as a PNG (8-bit RGBA, top row first, zlib's level 6): 1 when
// written.
static int gl_png(const char *path, GLuint fb) {
  if (fb_w <= 0 || fb_h <= 0) return 0;
  size_t row = (size_t)fb_w * 4;
  unsigned char *px = malloc(row * fb_h), *raw = malloc((row + 1) * fb_h);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fb);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, fb_w, fb_h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  // GL's rows are from the foot up
  for (int y = 0; y < fb_h; y++) {
    raw[(row + 1) * y] = 0;
    memcpy(raw + (row + 1) * y + 1, px + row * (fb_h - 1 - y), row);
  }
  uLongf zn = compressBound((uLong)((row + 1) * fb_h));
  unsigned char *z = malloc(zn);
  int ok = compress2(z, &zn, raw, (uLong)((row + 1) * fb_h), 6) == Z_OK;
  FILE *f = ok ? fopen(path, "wb") : NULL;
  if (f) {
    static const unsigned char sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    unsigned char ihdr[13] = {fb_w >> 24, fb_w >> 16, fb_w >> 8, fb_w, fb_h >> 24, fb_h >> 16, fb_h >> 8, fb_h,
                              8, 6, 0, 0, 0};
    fwrite(sig, 1, 8, f);
    png_chunk(f, "IHDR", ihdr, 13);
    png_chunk(f, "IDAT", z, (uint32_t)zn);
    png_chunk(f, "IEND", NULL, 0);
    ok = fclose(f) == 0;
  } else {
    ok = 0;
  }
  free(z);
  free(raw);
  free(px);
  return ok;
}
