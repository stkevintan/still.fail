// Text with DirectWrite: shaping into clusters with their advances, and
// rasterizing each cluster with Direct2D into the RGBA atlas: drawn ahead by
// threads of their own where the app says which it will draw, else when it is
// first drawn. Segoe UI, with Han, kana and CJK punctuation mapped to Microsoft
// YaHei UI ahead of the system fallback (which supplies Segoe UI Emoji).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <dwrite_3.h>
#include <d2d1.h>
#include <wincodec.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "win.h"

#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "user32.lib")

static const WCHAR *FAMILY = L"Segoe UI";
static bool has_segoe_var_small, has_segoe_var_display;
static const WCHAR *MONO = L"Consolas";  // the code face (style & 2)
static const WCHAR *SERIF = L"SimSun";   // the serif face (style & 4): 宋体, its Latin too
static const int RT_SIZE = 512;  // largest cluster bitmap, in pixels
static const int FINE = 4;        // a gray glyph drawn at this many times its size, its cover averaged back

struct ClusterBounds {
  double x0, y0, x1, y1, base;
  double box_w, box_h;
  int color;
  // the least weight of the fonts without variations its runs are drawn in (0: none such): a Medium asked of a face
  // with none (Microsoft YaHei UI: 290, 400, 700), drawn in its Regular
  int static_weight;
  bool valid;
};

typedef struct {
  int off, len;  // the cluster's text in pool
  double size;
  int weight;
  int style;  // 1 italic, 2 the code face
  int fg;     // per-slot face generation (for preview slots >= MB_FACE_TRY)
  double w, h, ox, oy;
  int color;
  // its ink across, from where it starts (punct_ink); known: worked out
  double ink_l, ink_r;
  bool ink_known;
  ClusterBounds bounds;
  uint8_t subs_queued;
} glyph_entry;

static IDWriteFactory2 *dw;
static IDWriteFontFallback *fallback;
// Whether Segoe UI Emoji is here (init): what emoji_sequences sets its sequences in.
static bool has_emoji_face;
static IDWriteRenderingParams *params, *params_gray, *params_gray_small, *params_ct;
static ID2D1Factory *d2d;
static IWICImagingFactory *wic;
// Where a glyph is drawn: a bitmap of RT_SIZE pixels, Direct2D's target over it at the scale it was made for, white
// and black brushes. The frames' thread has its own (the factories made in init); each thread drawing ahead its own, of
// its own factories (Direct2D's single-threaded one, WIC's).
struct Target {
  ID2D1Factory *d2d;
  IWICImagingFactory *wic;
  IWICBitmap *bitmap;
  ID2D1RenderTarget *rt;
  ID2D1SolidColorBrush *white;
  ID2D1SolidColorBrush *black;
  double scale;
  // a gray glyph's fine drawing: a bitmap as large as the largest drawn so far (fine_w × fine_h, RT_SIZE × FINE at
  // most: what draw_cluster takes), its target at FINE times the scale, a black brush
  IWICBitmap *fine_bitmap;
  int fine_w, fine_h;
  ID2D1RenderTarget *fine_rt;
  ID2D1SolidColorBrush *fine_black;
  double fine_scale;
  float *fine_a;
  float *fine_g;
  size_t fine_cap;
};
static Target main_target;
static double text_scale = 1;
static glyph_entry *entries;
static int n_entries, cap_entries;
static WCHAR *pool;
static size_t pool_len, pool_cap;
static int *table;  // open addressing: entry index + 1, 0 is empty
static size_t table_cap;
static int generation;
// the glyph drawn last (mb_host_glyph), its picture until it is put in the atlas (mb_host_glyph_put)
static int held_key = -1, held_w, held_h;
static uint8_t *held_px;
static struct { double size; int weight; int style; IDWriteTextFormat *f; } formats[32];
static int n_formats;

// Whether a monitor's EDID friendly name names an OLED panel (or a known QD-OLED / WOLED model whose EDID omits
// "OLED"), whose triangular or RWBG subpixels do not match ClearType's horizontal RGB stripes.
static bool is_oled_name(const WCHAR *name) {
  static const WCHAR *const tags[] = {
      L"OLED",     L"AW3225",   L"AW2725",   L"AW3423",   L"PG32UCD",  L"PG27AQD",  L"PG27UCD",  L"PG34WCD",
      L"XG27AQD",  L"MPG 321",  L"MPG 271",  L"MAG 321",  L"MAG 271",  L"MPG 341",  L"FO32U",    L"FO27Q",
      L"MO34WQC",  L"G80SD",    L"G60SD",    L"32GS95",   L"27GS95",   L"27GR95",   L"34GS95",   L"39GS95",
      L"45GS95",   L"LG TV",
  };
  for (size_t k = 0; k < sizeof tags / sizeof tags[0]; k++) {
    const WCHAR *t = tags[k];
    size_t tlen = wcslen(t);
    for (const WCHAR *p = name; *p; p++) {
      if (_wcsnicmp(p, t, tlen) == 0) return true;
    }
  }
  return false;
}

// Subpixel geometry of the machine's active display: FLAT when an active physical monitor is an OLED panel or when a
// physical monitor is attached and the user turned ClearType off in Windows; BGR when configured so; else RGB.
static DWRITE_PIXEL_GEOMETRY detect_pixel_geometry(void) {
  bool has_edid_monitor = false;
  bool has_oled = false;
  UINT32 np = 0, nm = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) == ERROR_SUCCESS && np > 0) {
    DISPLAYCONFIG_PATH_INFO *paths = (DISPLAYCONFIG_PATH_INFO *)calloc(np, sizeof *paths);
    DISPLAYCONFIG_MODE_INFO *modes = (DISPLAYCONFIG_MODE_INFO *)calloc(nm, sizeof *modes);
    if (paths && modes && QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths, &nm, modes, NULL) == ERROR_SUCCESS) {
      for (UINT32 i = 0; i < np; i++) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME tn = {};
        tn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tn.header.size = sizeof tn;
        tn.header.adapterId = paths[i].targetInfo.adapterId;
        tn.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&tn.header) == ERROR_SUCCESS && tn.flags.edidIdsValid) {
          has_edid_monitor = true;
          if (is_oled_name(tn.monitorFriendlyDeviceName)) has_oled = true;
        }
      }
    }
    free(paths);
    free(modes);
  }
  if (has_oled) return DWRITE_PIXEL_GEOMETRY_FLAT;
  if (has_edid_monitor) {
    BOOL smoothing = TRUE;
    UINT type = FE_FONTSMOOTHINGCLEARTYPE;
    if (SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &smoothing, 0) && !smoothing) return DWRITE_PIXEL_GEOMETRY_FLAT;
    if (SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &type, 0) && type != FE_FONTSMOOTHINGCLEARTYPE)
      return DWRITE_PIXEL_GEOMETRY_FLAT;
    IDWriteRenderingParams *sys = NULL;
    if (SUCCEEDED(dw->CreateRenderingParams(&sys)) && sys) {
      DWRITE_PIXEL_GEOMETRY g = sys->GetPixelGeometry();
      FLOAT ct = sys->GetClearTypeLevel();
      sys->Release();
      if (g == DWRITE_PIXEL_GEOMETRY_FLAT || ct <= 0.0f) return DWRITE_PIXEL_GEOMETRY_FLAT;
      if (g == DWRITE_PIXEL_GEOMETRY_BGR) return DWRITE_PIXEL_GEOMETRY_BGR;
    }
  }
  return DWRITE_PIXEL_GEOMETRY_RGB;
}

static bool use_cleartype(double sc) { return params_ct != NULL && sc < 1.25; }

// The system's font collection's family named `name` (its index), if there is one.
static bool system_family(const WCHAR *name) {
  IDWriteFontCollection *fc = NULL;
  if (FAILED(dw->GetSystemFontCollection(&fc, FALSE))) return false;
  UINT32 at = 0;
  BOOL there = FALSE;
  fc->FindFamilyName(name, &at, &there);
  fc->Release();
  return there;
}

static void init(void) {
  if (dw) return;
  DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, __uuidof(IDWriteFactory2), (IUnknown **)&dw);
  if (system_family(L"Segoe UI Variable")) {
    FAMILY = L"Segoe UI Variable";
  } else if (system_family(L"Segoe UI Variable Text")) {
    FAMILY = L"Segoe UI Variable Text";
    has_segoe_var_small = system_family(L"Segoe UI Variable Small");
    has_segoe_var_display = system_family(L"Segoe UI Variable Display");
  }
  IDWriteFontFallbackBuilder *b = NULL;
  IDWriteFontFallback *sys = NULL;
  dw->CreateFontFallbackBuilder(&b);
  DWRITE_UNICODE_RANGE cjk[] = {
      {0x2E80, 0x2FDF}, {0x3000, 0x31FF}, {0x3200, 0x4DBF},   {0x4E00, 0x9FFF},
      {0xF900, 0xFAFF}, {0xFE30, 0xFE4F}, {0xFF00, 0xFFEF}, {0x20000, 0x3FFFF},
  };
  const WCHAR *cjk_fonts[] = {L"Microsoft YaHei UI", L"Microsoft YaHei", L"SimSun"};
  b->AddMapping(cjk, sizeof cjk / sizeof cjk[0], cjk_fonts, 3, NULL, NULL, NULL, 1.0f);
  if (wcscmp(FAMILY, L"Segoe UI") != 0) {
    DWRITE_UNICODE_RANGE latin[] = {{0x0020, 0x024F}, {0x1E00, 0x1EFF}, {0x2000, 0x206F}};
    const WCHAR *latin_fonts[] = {FAMILY, L"Segoe UI"};
    b->AddMapping(latin, sizeof latin / sizeof latin[0], latin_fonts, 2, NULL, NULL, NULL, 1.0f);
  }
  has_emoji_face = system_family(L"Segoe UI Emoji");
  dw->GetSystemFontFallback(&sys);
  b->AddMappings(sys);
  b->CreateFontFallback(&fallback);
  sys->Release();
  b->Release();
  // the font's own features, ligatures with them, as DirectWrite draws any app's text: a ligature is one
  // cluster of its letters (GetClusterMetrics), drawn whole
  // plain coverage without contrast boost for colour glyphs (emojis)
  IDWriteRenderingParams2 *p2 = NULL;
  dw->CreateCustomRenderingParams(1.0f, 0.0f, 0.0f, 0.0f, DWRITE_PIXEL_GEOMETRY_FLAT,
                                  DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                                  DWRITE_GRID_FIT_MODE_DISABLED, &p2);
  params = p2;
  // Monochrome text in grayscale (125%+, an OLED panel, ClearType off in Windows) is covered as the Apple hosts cover it
  // (apple_text.m draws with font smoothing off: no dilation; apple_render.m blends that cover as it is): the outline's
  // own area of each pixel, unhinted, at linear gamma with no contrast added, so what the shader blends is the cover
  // itself, the same on a light ground as on a dark one. DirectWrite's antialiasing is 6x5 a pixel, a diagonal's or a
  // curve's edge in five steps down: drawn at four times the size (params_gray, draw_cluster's fine target) and
  // averaged back, 24x20 a pixel. Small words (under 15 pixels an em) are drawn at their size with the font's own
  // vertical hinting (params_gray_small), a 12-pixel Han's counters kept open where unhinted they blur shut.
  IDWriteRenderingParams2 *g2 = NULL;
  dw->CreateCustomRenderingParams(1.0f, 0.0f, 0.0f, 0.0f, DWRITE_PIXEL_GEOMETRY_FLAT,
                                  DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_GRID_FIT_MODE_DISABLED, &g2);
  params_gray = g2;
  IDWriteRenderingParams2 *s2 = NULL;
  dw->CreateCustomRenderingParams(1.0f, 0.0f, 0.0f, 0.0f, DWRITE_PIXEL_GEOMETRY_FLAT,
                                  DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_GRID_FIT_MODE_DEFAULT, &s2);
  params_gray_small = s2;
  // A glyph in one colour drawn with ClearType under 125% on an RGB/BGR LCD: each of a pixel's three stripes covered on
  // its own, at linear gamma with no contrast added (as gray's), across as the outline is and grid-fitted down the
  // font's own way (its horizontal strokes on whole rows, a 1x Han's counters open), symmetric antialiasing.
  DWRITE_PIXEL_GEOMETRY geom = detect_pixel_geometry();
  if (geom != DWRITE_PIXEL_GEOMETRY_FLAT) {
    IDWriteRenderingParams2 *c2 = NULL;
    dw->CreateCustomRenderingParams(1.0f, 0.0f, 0.0f, 1.0f, geom,
                                    DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_GRID_FIT_MODE_DEFAULT, &c2);
    params_ct = c2;
  }
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), NULL, (void **)&d2d);
  CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory),
                   (void **)&wic);
  main_target.d2d = d2d;
  main_target.wic = wic;
}

// The faces given (mb_host_face_add, style.mbt): each its files, made into a collection of their own (DirectWrite's
// font set from the files: a variable file's named weights in it), and the family the files make.
#define MB_FACES 32
static struct {
  WCHAR **paths;  // a file's path, or NULL: its bytes (data, sizes)
  void **data;
  UINT32 *sizes;
  int n;
  IDWriteFontCollection1 *fc;
  WCHAR family[128];
  bool system;  // a family installed here (mb_host_face_add_family): the system's collection, no files of its own
  bool no_lig;  // programming/contextual ligatures disabled on this slot
} faces[MB_FACES];
// fonts given as bytes: DirectWrite's in-memory loader (it keeps a copy of each)
static IDWriteInMemoryFontFileLoader *mem_loader;

// The face a style is set in: the one it names; else code's (style & 2), what people wrote's (style & 16), the app's
// words' (not the serif face's); 0 none given.
static bool face_has(int f) { return faces[f].fc || faces[f].system; }

static int face_id(int style) {
  int f = (style >> 8) & 31;
  if (f > 0) return face_has(f) ? f : 0;
  if (style & 2) return face_has(3) ? 3 : 0;
  if (style & 4) return 0;
  if ((style & 16) && face_has(2)) return 2;
  return face_has(1) ? 1 : 0;
}

// Face `f`'s files as a collection, its family's name from it (false: not fonts DirectWrite reads).
static bool face_build(int f) {
  IDWriteFactory5 *dw5 = NULL;
  if (FAILED(dw->QueryInterface(__uuidof(IDWriteFactory5), (void **)&dw5))) return false;
  IDWriteFontSetBuilder1 *b = NULL;
  IDWriteFontSet *set = NULL;
  IDWriteFontCollection1 *fc = NULL;
  IDWriteFontFamily1 *fam = NULL;
  IDWriteLocalizedStrings *names = NULL;
  bool ok = SUCCEEDED(dw5->CreateFontSetBuilder(&b));
  for (int i = 0; ok && i < faces[f].n; i++) {
    IDWriteFontFile *file = NULL;
    if (faces[f].paths[i]) {
      ok = SUCCEEDED(dw5->CreateFontFileReference(faces[f].paths[i], NULL, &file));
    } else {
      if (!mem_loader && SUCCEEDED(dw5->CreateInMemoryFontFileLoader(&mem_loader))) dw5->RegisterFontFileLoader(mem_loader);
      ok = mem_loader && SUCCEEDED(mem_loader->CreateInMemoryFontFileReference(dw5, faces[f].data[i], faces[f].sizes[i], NULL, &file));
    }
    ok = ok && SUCCEEDED(b->AddFontFile(file));
    if (file) file->Release();
  }
  ok = ok && SUCCEEDED(b->CreateFontSet(&set)) && SUCCEEDED(dw5->CreateFontCollectionFromFontSet(set, &fc)) &&
       fc->GetFontFamilyCount() > 0 && SUCCEEDED(fc->GetFontFamily(0, &fam)) && SUCCEEDED(fam->GetFamilyNames(&names)) &&
       SUCCEEDED(names->GetString(0, faces[f].family, 128));
  if (ok) {
    if (faces[f].fc) faces[f].fc->Release();
    faces[f].fc = fc;
    faces[f].system = false;
    fc = NULL;
  }
  if (names) names->Release();
  if (fam) fam->Release();
  if (fc) fc->Release();
  if (set) set->Release();
  if (b) b->Release();
  dw5->Release();
  return ok;
}

#define MB_FACE_TRY 7
static int face_gen[MB_FACES];
static void face_changed(int32_t f);

// A file of face `f`: its path, or its bytes (path NULL); made part of it if DirectWrite reads them as a font.
static int32_t face_take(int32_t f, WCHAR *path, void *data, UINT32 size) {
  init();
  if (f <= 0 || f >= MB_FACES) {
    free(path);
    free(data);
    return 0;
  }
  int n = faces[f].n;
  faces[f].paths = (WCHAR **)realloc(faces[f].paths, sizeof(WCHAR *) * (n + 1));
  faces[f].data = (void **)realloc(faces[f].data, sizeof(void *) * (n + 1));
  faces[f].sizes = (UINT32 *)realloc(faces[f].sizes, sizeof(UINT32) * (n + 1));
  faces[f].paths[n] = path;
  faces[f].data[n] = data;
  faces[f].sizes[n] = size;
  faces[f].n = n + 1;
  if (!face_build(f)) {
    faces[f].n = n;
    free(path);
    free(data);
    return 0;
  }
  face_changed(f);
  return 1;
}

extern "C" int32_t mb_host_face_add(int32_t f, moonbit_string_t path, int32_t weight) {
  (void)weight;  // the files' own weights say which is which (a variable file: its named instances)
  int len = Moonbit_array_length(path);
  WCHAR *p = (WCHAR *)malloc(sizeof(WCHAR) * (len + 1));
  memcpy(p, path, sizeof(WCHAR) * len);
  p[len] = 0;
  return face_take(f, p, NULL, 0);
}

extern "C" int32_t mb_host_face_add_bytes(int32_t f, moonbit_bytes_t data, int32_t weight) {
  (void)weight;
  UINT32 size = (UINT32)Moonbit_array_length(data);
  void *copy = malloc(size);
  memcpy(copy, data, size);
  return face_take(f, NULL, copy, size);
}

extern "C" void mb_host_face_clear(int32_t f) {
  if (f <= 0 || f >= MB_FACES) return;
  faces[f].no_lig = false;
  if (!face_has(f)) return;
  for (int i = 0; i < faces[f].n; i++) {
    free(faces[f].paths[i]);
    free(faces[f].data[i]);
  }
  faces[f].n = 0;
  if (faces[f].fc) faces[f].fc->Release();
  faces[f].fc = NULL;
  faces[f].system = false;
  face_changed(f);
}

extern "C" void mb_host_face_set_ligatures(int32_t f, int32_t on) {
  if (f <= 0 || f >= MB_FACES) return;
  bool no_lig = !on;
  if (faces[f].no_lig == no_lig) return;
  faces[f].no_lig = no_lig;
  face_changed(f);
}

extern "C" void mb_host_set_host_autospace(int32_t on) { (void)on; }

// Face `f` set in the family installed here named `family`: the system's collection, by its name.
extern "C" int32_t mb_host_face_add_family(int32_t f, moonbit_string_t family) {
  init();
  int len = Moonbit_array_length(family);
  if (f <= 0 || f >= MB_FACES || len <= 0 || len >= 128) return 0;
  WCHAR name[128];
  memcpy(name, family, sizeof(WCHAR) * len);
  name[len] = 0;
  if (!system_family(name)) {
    if (wcscmp(name, L"Segoe UI Variable") == 0 && system_family(L"Segoe UI Variable Text")) {
      wcscpy_s(name, 128, L"Segoe UI Variable Text");
    } else {
      return 0;
    }
  }
  for (int i = 0; i < faces[f].n; i++) {
    free(faces[f].paths[i]);
    free(faces[f].data[i]);
  }
  faces[f].n = 0;
  if (faces[f].fc) faces[f].fc->Release();
  faces[f].fc = NULL;
  memcpy(faces[f].family, name, sizeof(name));
  faces[f].system = true;
  face_changed(f);
  return 1;
}

// The font families installed here, as a JSON array of their names (each its name in the user's language, else its
// first), sorted as the collection has them.
// the user's locale, the families' names are shown and sorted in
static WCHAR names_locale[LOCALE_NAME_MAX_LENGTH];

static int name_order(const void *a, const void *b) {
  return CompareStringEx(names_locale[0] ? names_locale : NULL, LINGUISTIC_IGNORECASE, *(const WCHAR *const *)a, -1,
                         *(const WCHAR *const *)b, -1, NULL, NULL, 0) - CSTR_EQUAL;
}

static WCHAR *local_families_cache;
static size_t local_families_cache_len;

extern "C" moonbit_string_t mb_host_local_font_families(void) {
  init();
  if (!local_families_cache) {
    IDWriteFontCollection *fc = NULL;
    if (FAILED(dw->GetSystemFontCollection(&fc, FALSE))) return moonbit_make_string_raw(0);
    if (!GetUserDefaultLocaleName(names_locale, LOCALE_NAME_MAX_LENGTH)) names_locale[0] = 0;
    UINT32 count = fc->GetFontFamilyCount();
    WCHAR **all = (WCHAR **)calloc(count ? count : 1, sizeof(WCHAR *));
    UINT32 had = 0;
    for (UINT32 i = 0; i < count; i++) {
      IDWriteFontFamily *fam = NULL;
      IDWriteLocalizedStrings *names = NULL;
      WCHAR name[256];
      name[0] = 0;
      if (SUCCEEDED(fc->GetFontFamily(i, &fam)) && SUCCEEDED(fam->GetFamilyNames(&names))) {
        UINT32 at = 0;
        BOOL there = FALSE;
        if (names_locale[0]) names->FindLocaleName(names_locale, &at, &there);
        if (!there) at = 0;
        UINT32 len = 0;
        if (SUCCEEDED(names->GetStringLength(at, &len)) && len < 255) names->GetString(at, name, 256);
      }
      if (names) names->Release();
      if (fam) fam->Release();
      if (name[0]) all[had++] = _wcsdup(name);
    }
    fc->Release();
    // in the order of the user's language, as the web's localeCompare
    qsort(all, had, sizeof(WCHAR *), name_order);
    size_t cap = 4096, n = 0;
    WCHAR *out = (WCHAR *)malloc(sizeof(WCHAR) * cap);
    out[n++] = L'[';
    for (UINT32 i = 0; i < had; i++) {
      const WCHAR *name = all[i];
      size_t len = wcslen(name);
      // its name as a JSON string: a quote and a backslash escaped, the rest as it is
      if (n + 2 * len + 4 >= cap) {
        cap = (n + 2 * len + 4) * 2;
        out = (WCHAR *)realloc(out, sizeof(WCHAR) * cap);
      }
      if (n > 1) out[n++] = L',';
      out[n++] = L'"';
      for (size_t k = 0; k < len; k++) {
        if (name[k] == L'"' || name[k] == L'\\') out[n++] = L'\\';
        out[n++] = name[k] < 0x20 ? L' ' : name[k];
      }
      out[n++] = L'"';
      free(all[i]);
    }
    free(all);
    out[n++] = L']';
    local_families_cache = out;
    local_families_cache_len = n;
  }
  moonbit_string_t s = moonbit_make_string_raw((int32_t)local_families_cache_len);
  memcpy(s, local_families_cache, sizeof(WCHAR) * local_families_cache_len);
  return s;
}

static WCHAR *local_font_info_cache;
static size_t local_font_info_cache_len;

static void wbuf_append(WCHAR **buf, size_t *n, size_t *cap, const WCHAR *s, size_t len) {
  if (*n + len + 4 >= *cap) {
    *cap = (*n + len + 4) * 2;
    *buf = (WCHAR *)realloc(*buf, sizeof(WCHAR) * (*cap));
  }
  memcpy(*buf + *n, s, sizeof(WCHAR) * len);
  *n += len;
}

static void wbuf_append_json_str(WCHAR **buf, size_t *n, size_t *cap, const WCHAR *s) {
  size_t len = wcslen(s);
  if (*n + 2 * len + 4 >= *cap) {
    *cap = (*n + 2 * len + 4) * 2;
    *buf = (WCHAR *)realloc(*buf, sizeof(WCHAR) * (*cap));
  }
  (*buf)[(*n)++] = L'"';
  for (size_t k = 0; k < len; k++) {
    if (s[k] == L'"' || s[k] == L'\\') (*buf)[(*n)++] = L'\\';
    (*buf)[(*n)++] = s[k] < 0x20 ? L' ' : s[k];
  }
  (*buf)[(*n)++] = L'"';
}

extern "C" void mb_host_request_frame(void);
extern "C" void mb_app_call(void (*fn)(void *), void *arg);

static volatile LONG local_font_info_started = 0;

static void local_font_info_wake(void *) { mb_host_request_frame(); }

static WCHAR local_font_info_empty[2] = {L'[', L']'};

static void local_font_info_finish_empty(bool wake) {
  local_font_info_cache_len = 2;
  InterlockedExchangePointer((PVOID *)&local_font_info_cache, local_font_info_empty);
  if (wake) mb_app_call(local_font_info_wake, NULL);
}

static DWORD WINAPI local_font_info_worker(LPVOID) {
  IDWriteFactory *factory = NULL;
  if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                 (IUnknown **)&factory)) || !factory) {
    local_font_info_finish_empty(true);
    return 0;
  }
  IDWriteFontCollection *fc = NULL;
  if (FAILED(factory->GetSystemFontCollection(&fc, FALSE)) || !fc) {
    factory->Release();
    local_font_info_finish_empty(true);
    return 0;
  }
  WCHAR locale[LOCALE_NAME_MAX_LENGTH] = {0};
  if (!GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH)) locale[0] = 0;
  UINT32 count = fc->GetFontFamilyCount();
  size_t cap = 4096, n = 0;
  WCHAR *out = (WCHAR *)malloc(sizeof(WCHAR) * cap);
  out[n++] = L'[';
  for (UINT32 i = 0; i < count; i++) {
    IDWriteFontFamily *fam = NULL;
    IDWriteLocalizedStrings *names = NULL;
    WCHAR en_name[256] = {0}, loc_name[256] = {0};
    bool mono = false, serif = false, cjk = false;
    if (SUCCEEDED(fc->GetFontFamily(i, &fam)) && SUCCEEDED(fam->GetFamilyNames(&names))) {
      UINT32 at = 0;
      BOOL there = FALSE;
      names->FindLocaleName(L"en-us", &at, &there);
      if (!there) at = 0;
      UINT32 len = 0;
      if (SUCCEEDED(names->GetStringLength(at, &len)) && len < 255) names->GetString(at, en_name, 256);
      at = 0;
      there = FALSE;
      if (locale[0]) names->FindLocaleName(locale, &at, &there);
      if (!there) at = 0;
      len = 0;
      if (SUCCEEDED(names->GetStringLength(at, &len)) && len < 255) names->GetString(at, loc_name, 256);
      IDWriteFont *font = NULL;
      if (SUCCEEDED(fam->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                              DWRITE_FONT_STYLE_NORMAL, &font)) && font) {
        IDWriteFont1 *font1 = NULL;
        if (SUCCEEDED(font->QueryInterface(__uuidof(IDWriteFont1), (void **)&font1)) && font1) {
          mono = font1->IsMonospacedFont() != FALSE;
          DWRITE_PANOSE panose;
          font1->GetPanose(&panose);
          if (panose.familyKind == DWRITE_PANOSE_FAMILY_TEXT_DISPLAY &&
              panose.text.serifStyle >= DWRITE_PANOSE_SERIF_STYLE_COVE &&
              panose.text.serifStyle <= DWRITE_PANOSE_SERIF_STYLE_TRIANGLE) {
            serif = true;
          }
          font1->Release();
        }
        BOOL has_han = FALSE;
        if (SUCCEEDED(font->HasCharacter(0x4E2D, &has_han)) && has_han) cjk = true;
        font->Release();
      }
    }
    if (names) names->Release();
    if (fam) fam->Release();
    if (!en_name[0] && loc_name[0]) wcscpy_s(en_name, 256, loc_name);
    if (!loc_name[0] && en_name[0]) wcscpy_s(loc_name, 256, en_name);
    if (!en_name[0]) continue;
    if (n > 1) out[n++] = L',';
    wbuf_append(&out, &n, &cap, L"{\"name\":", 8);
    wbuf_append_json_str(&out, &n, &cap, en_name);
    wbuf_append(&out, &n, &cap, L",\"localized\":", 13);
    wbuf_append_json_str(&out, &n, &cap, loc_name);
    const WCHAR *tail_m = mono ? L",\"mono\":true" : L",\"mono\":false";
    wbuf_append(&out, &n, &cap, tail_m, wcslen(tail_m));
    const WCHAR *tail_s = serif ? L",\"serif\":true" : L",\"serif\":false";
    wbuf_append(&out, &n, &cap, tail_s, wcslen(tail_s));
    const WCHAR *tail_c = cjk ? L",\"cjk\":true}" : L",\"cjk\":false}";
    wbuf_append(&out, &n, &cap, tail_c, wcslen(tail_c));
  }
  fc->Release();
  factory->Release();
  out[n++] = L']';
  local_font_info_cache_len = n;
  InterlockedExchangePointer((PVOID *)&local_font_info_cache, out);
  mb_app_call(local_font_info_wake, NULL);
  return 0;
}

extern "C" moonbit_string_t mb_host_local_font_info(void) {
  WCHAR *cached = (WCHAR *)InterlockedCompareExchangePointer((PVOID *)&local_font_info_cache, NULL, NULL);
  if (!cached) {
    if (InterlockedCompareExchange(&local_font_info_started, 1, 0) == 0) {
      HANDLE th = CreateThread(NULL, 0, local_font_info_worker, NULL, 0, NULL);
      if (th) {
        CloseHandle(th);
      } else {
        local_font_info_finish_empty(true);
        cached = local_font_info_empty;
      }
    }
    if (!cached) return moonbit_make_string_raw(0);
  }
  size_t len = local_font_info_cache_len;
  moonbit_string_t s = moonbit_make_string_raw((int32_t)len);
  memcpy(s, cached, sizeof(WCHAR) * len);
  return s;
}

static const WCHAR *segoe_family_for_size(double size) {
  if (has_segoe_var_small && size < 10.5) return L"Segoe UI Variable Small";
  if (has_segoe_var_display && size >= 20.0) return L"Segoe UI Variable Display";
  return FAMILY;
}

static IDWriteTextFormat *format_for(double size, int weight, int style) {
  int face = face_id(style);
  int fkey = (face << 8) | (style & 7);
  for (int i = 0; i < n_formats; i++)
    if (formats[i].size == size && formats[i].weight == weight && formats[i].style == fkey) return formats[i].f;
  IDWriteTextFormat *f = NULL;
  const WCHAR *fam = face ? (faces[face].system && wcscmp(faces[face].family, L"Segoe UI Variable Text") == 0
                                 ? segoe_family_for_size(size)
                                 : faces[face].family)
                   : (style & 2) ? MONO
                   : (style & 4) ? SERIF
                   : segoe_family_for_size(size);
  dw->CreateTextFormat(fam,
                       face && faces[face].fc ? faces[face].fc : NULL, (DWRITE_FONT_WEIGHT)weight,
                       (style & 1) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
                       DWRITE_FONT_STRETCH_NORMAL, (FLOAT)size, L"zh-cn", &f);
  f->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  // (No font axis is said on the format, the optical size made automatic either: DirectWrite then matches the fallback
  // by its axes too, and Microsoft YaHei UI, which has none, is taken at its 400 whatever the weight, a Bold title's Han
  // drawn Regular.)
  if (n_formats == 32) {
    formats[0].f->Release();
    formats[0] = formats[--n_formats];
  }
  formats[n_formats].size = size;
  formats[n_formats].weight = weight;
  formats[n_formats].style = fkey;
  formats[n_formats++].f = f;
  return f;
}

// style & 8: no ligatures (words with letter spacing, each cluster spaced on its own): liga and clig off; style & 32:
// digits all one width (style.mbt style_tabular): tnum; style & 64: a CJK face's marks narrow among Latin letters
// (style.mbt style_proportional): pwid; the app's words and what people wrote (faces 1 and 2) with the web's
// alternates, as the Apple hosts set them (apple_text.m face_font: cv11 and ss01, Inter's single-storey a and its open
// digits; a face without them is as it is); k & 16: per-face ligatures disabled (calt, liga, clig off).
static IDWriteTypography *typographies[32];

// the typography of a style's features (NULL: none, the font's own)
static IDWriteTypography *typography_for(int style) {
  int face = face_id(style);
  int k = ((style & 8) ? 1 : 0) | ((style & 32) ? 2 : 0) | ((style & 64) ? 4 : 0) |
          (face == 1 || face == 2 ? 8 : 0) | ((face > 0 && faces[face].no_lig) ? 16 : 0);
  if (!k) return NULL;
  if (!typographies[k]) {
    IDWriteTypography *t = NULL;
    dw->CreateTypography(&t);
    if (k & 1) {
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_STANDARD_LIGATURES, 0});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_CONTEXTUAL_LIGATURES, 0});
    }
    if (k & 16) {
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_CONTEXTUAL_ALTERNATES, 0});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_STANDARD_LIGATURES, 0});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_CONTEXTUAL_LIGATURES, 0});
    }
    if (k & 2) {
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, 1});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_KERNING, 1});
    }
    // (kern said again: DirectWrite sets a range with pwid unkerned otherwise, quotes round "Wo" 3 pt wider at 20)
    if (k & 4) {
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_PROPORTIONAL_WIDTHS, 1});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_KERNING, 1});
    }
    if (k & 8) {
      t->AddFontFeature({(DWRITE_FONT_FEATURE_TAG)DWRITE_MAKE_OPENTYPE_TAG('c', 'v', '1', '1'), 1});
      t->AddFontFeature({(DWRITE_FONT_FEATURE_TAG)DWRITE_MAKE_OPENTYPE_TAG('s', 's', '0', '1'), 1});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_KERNING, 1});
    }
    typographies[k] = t;
  }
  return typographies[k];
}

static void set_style_features(IDWriteTextLayout *l, int len, int style) {
  IDWriteTypography *t = typography_for(style);
  if (t) l->SetTypography(t, {0, (UINT32)len});
}

// The code point at s[i] and how many WCHARs it takes.
static uint32_t code_at(const WCHAR *s, int len, int i, int *n) {
  WCHAR c = s[i];
  if (c >= 0xD800 && c < 0xDC00 && i + 1 < len && s[i + 1] >= 0xDC00 && s[i + 1] < 0xE000) {
    *n = 2;
    return 0x10000 + (((uint32_t)c - 0xD800) << 10) + ((uint32_t)s[i + 1] - 0xDC00);
  }
  *n = 1;
  return c;
}

// An emoji asked for by U+FE0F, or a keycap (U+20E3), whose base the face has as text: a digit, # or *, ©, ®, ❤, ☺,
// ✔ and the like. DirectWrite does not let U+FE0F choose the font: it takes the base from the face (Consolas, Segoe
// UI) and the keycap's enclosing mark from a fallback, drawn on its own about the base (no width of its own, over the
// next character: 1️⃣ before 整 drawn as a box across both). Each such sequence, with the ZWJ sequence or skin tone
// that goes on from it (❤️‍🔥), set in Segoe UI Emoji, as Edge and Chrome set it; one its base is not in falls back as
// any other text.
static void emoji_sequences(IDWriteTextLayout *l, const WCHAR *s, int len) {
  if (!has_emoji_face) return;
  for (int i = 0; i < len;) {
    int bn;
    uint32_t b = code_at(s, len, i, &bn);
    int end = i + bn;
    bool keycap_base = (b >= '0' && b <= '9') || b == '#' || b == '*';
    bool asked = false;
    if (end < len && s[end] == 0xFE0F && (keycap_base || b == 0xA9 || b == 0xAE || b >= 0x2000)) {
      end++;
      asked = true;
    }
    if (keycap_base && end < len && s[end] == 0x20E3) {
      end++;
      asked = true;
    }
    if (!asked) {
      i += bn;
      continue;
    }
    // what goes on from it: a skin tone, or a ZWJ and the next emoji (with its own U+FE0F)
    for (;;) {
      int n;
      if (end < len) {
        uint32_t c = code_at(s, len, end, &n);
        if (c >= 0x1F3FB && c <= 0x1F3FF) {
          end += n;
          continue;
        }
      }
      if (end + 1 < len && s[end] == 0x200D) {
        code_at(s, len, end + 1, &n);
        end += 1 + n;
        if (end < len && s[end] == 0xFE0F) end++;
        continue;
      }
      break;
    }
    l->SetFontFamilyName(L"Segoe UI Emoji", {(UINT32)i, (UINT32)(end - i)});
    i = end;
  }
}

static IDWriteTextLayout *make_layout(const WCHAR *s, int len, double size, int weight, int style) {
  IDWriteTextLayout *l = NULL;
  dw->CreateTextLayout(s, (UINT32)len, format_for(size, weight, style), 1e6f, 1e6f, &l);
  IDWriteTextLayout2 *l2 = NULL;
  if (SUCCEEDED(l->QueryInterface(__uuidof(IDWriteTextLayout2), (void **)&l2))) {
    l2->SetFontFallback(fallback);
    l2->Release();
  }
  set_style_features(l, len, style);
  emoji_sequences(l, s, len);
  return l;
}

#define LAYOUT_CACHE_CAP 256
static struct {
  int key;
  IDWriteTextLayout *l;
} layout_cache[LAYOUT_CACHE_CAP];
static bool layout_cache_inited;

static void layout_cache_clear(void) {
  for (int i = 0; i < LAYOUT_CACHE_CAP; i++) {
    if (layout_cache[i].l) layout_cache[i].l->Release();
    layout_cache[i].l = NULL;
    layout_cache[i].key = -1;
  }
  layout_cache_inited = true;
}

static IDWriteTextLayout *main_layout_for(int key) {
  if (!layout_cache_inited) layout_cache_clear();
  int slot = key & (LAYOUT_CACHE_CAP - 1);
  if (layout_cache[slot].key == key && layout_cache[slot].l) return layout_cache[slot].l;
  if (layout_cache[slot].l) layout_cache[slot].l->Release();
  glyph_entry *e = &entries[key];
  IDWriteTextLayout *l = make_layout(pool + e->off, e->len, e->size, e->weight, e->style);
  layout_cache[slot].key = key;
  layout_cache[slot].l = l;
  return l;
}

// A family's metrics at this weight and style (false: not on this system, `m` as it was); in a face's collection
// where one is given.
static bool family_metrics(const WCHAR *name, int weight, int style, DWRITE_FONT_METRICS *m, IDWriteFontCollection *in = NULL,
                           bool *han = NULL) {
  IDWriteFontCollection *fc = NULL;
  IDWriteFontFamily *fam = NULL;
  IDWriteFont *font = NULL;
  UINT32 i = 0;
  BOOL found = FALSE;
  bool ok = false;
  if (in) {
    fc = in;
    fc->AddRef();
  } else {
    dw->GetSystemFontCollection(&fc, FALSE);
  }
  if (SUCCEEDED(fc->FindFamilyName(name, &i, &found)) && found && SUCCEEDED(fc->GetFontFamily(i, &fam)) &&
      SUCCEEDED(fam->GetFirstMatchingFont((DWRITE_FONT_WEIGHT)weight, DWRITE_FONT_STRETCH_NORMAL,
                                          (style & 1) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, &font))) {
    font->GetMetrics(m);
    ok = true;
    BOOL has = FALSE;
    if (han && SUCCEEDED(font->HasCharacter(0x56FD, &has))) *han = has;
  }
  if (font) font->Release();
  if (fam) fam->Release();
  fc->Release();
  return ok;
}

// The ink of code point `cp` in a family at this weight and style, in its design units: how far it reaches above the
// baseline and below it (false: not on this system, or no such glyph). In a face's collection where one is given.
static bool family_ink(const WCHAR *name, int weight, int style, UINT32 cp, double *above, double *below,
                       IDWriteFontCollection *in = NULL) {
  IDWriteFontCollection *fc = NULL;
  IDWriteFontFamily *fam = NULL;
  IDWriteFont *font = NULL;
  IDWriteFontFace *ff = NULL;
  UINT32 i = 0;
  BOOL found = FALSE;
  bool ok = false;
  if (in) {
    fc = in;
    fc->AddRef();
  } else {
    dw->GetSystemFontCollection(&fc, FALSE);
  }
  UINT16 gi = 0;
  DWRITE_GLYPH_METRICS gm = {};
  if (SUCCEEDED(fc->FindFamilyName(name, &i, &found)) && found && SUCCEEDED(fc->GetFontFamily(i, &fam)) &&
      SUCCEEDED(fam->GetFirstMatchingFont((DWRITE_FONT_WEIGHT)weight, DWRITE_FONT_STRETCH_NORMAL,
                                          (style & 1) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, &font)) &&
      SUCCEEDED(font->CreateFontFace(&ff)) && SUCCEEDED(ff->GetGlyphIndices(&cp, 1, &gi)) && gi &&
      SUCCEEDED(ff->GetDesignGlyphMetrics(&gi, 1, &gm, FALSE))) {
    *above = (double)gm.verticalOriginY - gm.topSideBearing;
    *below = (double)gm.advanceHeight - gm.bottomSideBearing - gm.verticalOriginY;
    ok = true;
  }
  if (ff) ff->Release();
  if (font) font->Release();
  if (fam) fam->Release();
  fc->Release();
  return ok;
}

// A line's ascent and descent for a face, as tall in all as the face's own (its ascent and descent, design units),
// the baseline moved so that the line's middle is the middle of the ink reaching `above` over it and `below` under it: a line
// centred in a box then shows its words centred in it (Segoe UI's ascent, 1.08 em, keeps room for accents over
// capitals 0.70 high, and set its words low in every capsule).
static void centred_line(double ascent, double descent, double above, double below, double *a, double *d) {
  double half = (ascent + descent) / 2.0, mid = (above - below) / 2.0;
  *a = half + mid;
  *d = half - mid;
}

extern "C" void mb_host_font_metrics(double size, int32_t weight, int32_t style, double *out) {
  init();
  DWRITE_FONT_METRICS m = {};
  m.designUnitsPerEm = 2048;
  m.ascent = 2210;
  m.descent = 514;
  int face = face_id(style);
  bool han = false;
  if (face) family_metrics(faces[face].family, weight, style, &m, faces[face].fc, &han);
  else family_metrics((style & 2) ? MONO : (style & 4) ? SERIF : FAMILY, weight, style, &m, NULL, &han);
  // (centred on its capitals' ink, H's; on the face's cap height where it has no H)
  double em = m.designUnitsPerEm, a = m.ascent, d = m.descent, above = m.capHeight, below = 0.0;
  const WCHAR *fam_name = face ? faces[face].family : (style & 2) ? MONO : (style & 4) ? SERIF : FAMILY;
  family_ink(fam_name, weight, style, 'H', &above, &below, face ? faces[face].fc : NULL);
  centred_line(m.ascent, m.descent, above, below, &a, &d);
  out[0] = size * a / em;
  out[1] = size * d / em;
  out[2] = round(size * 1.42);
  // the face a Han ideograph is drawn in: a line with Chinese in it is measured by the taller of the two (as
  // apple_text.m asks Core Text for 国's): the face's own where it has Han (Noto Sans SC, LXGW WenKai, SimSun), else
  // the one Han falls back to (Chinese Windows' UI font)
  DWRITE_FONT_METRICS h = m;
  if (!han) family_metrics(L"Microsoft YaHei UI", weight, style, &h);
  // (centred on an ideograph's ink, 国's, in the face Han is drawn in)
  double ha = h.ascent, hd = h.descent, habove = h.capHeight, hbelow = 0.0;
  family_ink(han ? fam_name : L"Microsoft YaHei UI", weight, style, 0x56FD, &habove, &hbelow, han && face ? faces[face].fc : NULL);
  centred_line(h.ascent, h.descent, habove, hbelow, &ha, &hd);
  out[3] = size * ha / h.designUnitsPerEm;
  out[4] = size * hd / h.designUnitsPerEm;
  out[5] = 0;  // lines as asked, not on whole pixels
}

static uint32_t hash(const WCHAR *s, int len, double size, int weight, int style, int fg) {
  uint32_t h = 2166136261u;
  for (int i = 0; i < len; i++) h = (h ^ s[i]) * 16777619u;
  h = (h ^ (uint32_t)(size * 64)) * 16777619u;
  h = (h ^ (uint32_t)style) * 16777619u;
  h = (h ^ (uint32_t)fg) * 16777619u;
  return (h ^ (uint32_t)weight) * 16777619u;
}

static int same(const glyph_entry *e, const WCHAR *s, int len, double size, int weight, int style, int fg) {
  return e->len == len && e->size == size && e->weight == weight && e->style == style && e->fg == fg &&
         memcmp(pool + e->off, s, (size_t)len * sizeof(WCHAR)) == 0;
}

static void table_put(int id) {
  glyph_entry *e = &entries[id];
  size_t i = hash(pool + e->off, e->len, e->size, e->weight, e->style, e->fg) & (table_cap - 1);
  while (table[i]) i = (i + 1) & (table_cap - 1);
  table[i] = id + 1;
}

static int intern(const WCHAR *s, int len, double size, int weight, int style) {
  int fg = face_gen[face_id(style)];
  if (table_cap) {
    size_t i = hash(s, len, size, weight, style, fg) & (table_cap - 1);
    for (; table[i]; i = (i + 1) & (table_cap - 1))
      if (same(&entries[table[i] - 1], s, len, size, weight, style, fg)) return table[i] - 1;
  }
  if (n_entries == cap_entries) {
    cap_entries = cap_entries ? cap_entries * 2 : 1024;
    entries = (glyph_entry *)realloc(entries, sizeof(glyph_entry) * cap_entries);
  }
  if (pool_len + len > pool_cap) {
    pool_cap = (pool_len + len) * 2 + 4096;
    pool = (WCHAR *)realloc(pool, pool_cap * sizeof(WCHAR));
  }
  memcpy(pool + pool_len, s, (size_t)len * sizeof(WCHAR));
  int id = n_entries++;
  glyph_entry ge = {};
  ge.off = (int)pool_len;
  ge.len = len;
  ge.size = size;
  ge.weight = weight;
  ge.style = style;
  ge.fg = fg;
  entries[id] = ge;
  pool_len += len;
  if ((size_t)n_entries * 2 > table_cap) {
    free(table);
    table_cap = table_cap ? table_cap * 2 : 4096;
    table = (int *)calloc(table_cap, sizeof(int));
    for (int j = 0; j < n_entries; j++) table_put(j);
  } else {
    table_put(id);
  }
  return id;
}

// CJK punctuation two in a row set solid, as Core Text sets it on the Apple hosts (and DirectWrite would, for a font
// with chws: Microsoft YaHei, the fallback Han is drawn in, has neither chws nor halt, so "），" stood a whole empty
// half em apart). 1: a closing mark or a pause (，。、：；and the closing brackets), its ink in its first half in a
// Simplified Chinese font; 2: an opening bracket, its ink in its second half. ！？ and the quotes (narrow in YaHei)
// are left as they are.
static int punct_kind(WCHAR c) {
  switch (c) {
    case 0xFF0C: case 0x3002: case 0x3001: case 0xFF1A: case 0xFF1B: case 0xFF0E:
    case 0xFF09: case 0x300D: case 0x300F: case 0x3011: case 0x300B: case 0x3009: case 0x3015: case 0xFF3D:
    case 0xFF5D:
      return 1;
    case 0xFF08: case 0x300C: case 0x300E: case 0x3010: case 0x300A: case 0x3008: case 0x3014: case 0xFF3B:
    case 0xFF5B:
      return 2;
  }
  return 0;
}

// Where glyph `key`'s ink is across, from where it starts: worked out once, from the face it is drawn in.
static void punct_ink(int key) {
  glyph_entry *e = &entries[key];
  if (e->ink_known) return;
  IDWriteTextLayout *l = main_layout_for(key);
  DWRITE_TEXT_METRICS tm;
  DWRITE_OVERHANG_METRICS om;
  l->GetMetrics(&tm);
  l->SetMaxWidth(tm.widthIncludingTrailingWhitespace);
  l->SetMaxHeight(tm.height);
  l->GetOverhangMetrics(&om);
  e->ink_l = -om.left;
  e->ink_r = tm.widthIncludingTrailingWhitespace + om.right;
  e->ink_known = true;
}

// Each pair of full-width marks in a line's clusters (out, as mb_host_shape gives them): the first's advance a half
// em less where its ink still ends before the second's begins (a closing mark's empty second half; before an opening
// bracket, that bracket's empty first half), as chws sets them. An opening bracket then a closing one ("（）") is
// left.
static void punct_solid(const WCHAR *s, double size, double *out, int32_t k) {
  double half = size / 2, tol = size * 0.05;
  for (int32_t i = 0; i + 1 < k; i++) {
    int a = (int)out[i * 4 + 3], b = (int)out[(i + 1) * 4 + 3];
    if (a < 0 || b < 0 || out[i * 4 + 1] != 1 || out[(i + 1) * 4 + 1] != 1) continue;
    int ka = punct_kind(s[(int)out[i * 4]]), kb = punct_kind(s[(int)out[(i + 1) * 4]]);
    if (!ka || !kb || (ka == 2 && kb == 1)) continue;
    double adv = out[i * 4 + 2];
    if (fabs(adv - size) > tol || fabs(out[(i + 1) * 4 + 2] - size) > tol) continue;
    punct_ink(a);
    punct_ink(b);
    if (entries[a].ink_r <= adv - half + entries[b].ink_l + tol) out[i * 4 + 2] = adv - half;
  }
}

extern "C" int32_t mb_host_shape(moonbit_string_t text, double size, int32_t weight, int32_t style, double *out) {
  init();
  int32_t len = Moonbit_array_length(text);
  int32_t cap = Moonbit_array_length(out) / 4;
  const WCHAR *s = (const WCHAR *)text;
  IDWriteTextLayout *l = make_layout(s, len, size, weight, style);
  static DWRITE_CLUSTER_METRICS *cm;
  static UINT32 cm_cap;
  UINT32 n = 0;
  if (l->GetClusterMetrics(cm, cm_cap, &n) == E_NOT_SUFFICIENT_BUFFER) {
    cm_cap = n * 2;
    cm = (DWRITE_CLUSTER_METRICS *)realloc(cm, cm_cap * sizeof *cm);
    l->GetClusterMetrics(cm, cm_cap, &n);
  }
  int32_t k = 0, pos = 0;
  for (UINT32 i = 0; i < n && k < cap; i++) {
    int clen = cm[i].length;
    WCHAR c = s[pos];
    double adv = cm[i].width;
    int key;
    if (c == '\n' || cm[i].isNewline) {
      adv = 0;
      key = -1;
    } else if (c == ' ' || c == '\t') {
      key = -1;
    } else {
      key = intern(s + pos, clen, size, weight, style);
    }
    out[k * 4] = pos;
    out[k * 4 + 1] = clen;
    out[k * 4 + 2] = adv < 0 ? 0 : adv;
    out[k * 4 + 3] = key;
    k++;
    pos += clen;
  }
  l->Release();
  punct_solid(s, size, out, k);
  return k;
}

// The key of a piece of text drawn whole (a word of a joining script): host_native.mbt's text_key.
extern "C" int32_t mb_host_text_key(moonbit_string_t text, double size, int32_t weight, int32_t style) {
  init();
  return intern((const WCHAR *)text, Moonbit_array_length(text), size, weight, style);
}

// The glyphs' keys and what each is of forgotten (the faces changed, or more than KEYS_MOST of them: each a cluster of a
// size, weight and style ever shaped, a run left open on changing text growing them without end), the generation moved
// on. Only where MoonBit reads the generation (text.mbt text_arrive, as a frame starts: what it shaped is dropped as it
// sees it moved; faces.mbt words_forgotten, what it shaped dropped just before), never where it may still draw by a key
// made before (a face given in a frame); a key past the table draws nothing (mb_host_glyph). What the threads drawing
// ahead hold is their own (Ahead: its text copied), let go of by ahead_forget.
#define KEYS_MOST 65536
static int keys_stale;  // set as the faces change (faces_changed)
static void ahead_forget(void);
static void keys_sweep(void) {
  if (!keys_stale && n_entries <= KEYS_MOST) return;
  keys_stale = 0;
  ahead_forget();
  layout_cache_clear();
  n_entries = 0;
  pool_len = 0;
  if (cap_entries > 1024) {
    free(entries);
    entries = NULL;
    cap_entries = 0;
    free(pool);
    pool = NULL;
    pool_cap = 0;
  }
  free(table);
  table = NULL;
  table_cap = 0;
  free(held_px);
  held_px = NULL;
  held_key = -1;
  generation++;
}

extern "C" int32_t mb_host_atlas_generation(void) {
  keys_sweep();
  return generation;
}

// (one atlas: colour glyphs in it with the others)
extern "C" int32_t mb_host_atlas_size(int32_t colour) { return colour ? 0 : mb_atlas_size; }

// What was drawn before is drawn again: MoonBit drops its glyphs as the generation moves on.
static void reset_atlas(void) {
  generation++;
}

// What was measured and drawn before a face changed: its formats made again, its glyphs drawn again.
static void ahead_forget(void);

static void face_changed(int32_t f) {
  layout_cache_clear();
  for (int i = 0; i < n_formats; i++) formats[i].f->Release();
  n_formats = 0;
  ahead_forget();
  if (f >= MB_FACE_TRY && f < MB_FACES) {
    face_gen[f]++;
    return;
  }
  for (int i = 0; i < n_entries; i++) {
    entries[i].ink_known = false;
    entries[i].bounds = {};
    entries[i].subs_queued = 0;
  }
  reset_atlas();
  keys_stale = 1;
}

extern "C" void mb_text_set_scale(double scale) {
  if (scale == text_scale) return;
  text_scale = scale;
  ahead_forget();
  reset_atlas();
}

// Draws nothing; tells whether any run of a layout comes from a color font
// (emoji), the way the Core Text host checks kCTFontTraitColorGlyphs.
struct ColorProbe : public IDWriteTextRenderer {
  bool check_weight = false;
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
    bool need_color = true;
    if (run->fontFace) {
      if (check_weight) {
        // the weight of a font with no variations a run is drawn in (a variable one's is what was asked)
        IDWriteFontFace5 *f5 = NULL;
        if (SUCCEEDED(run->fontFace->QueryInterface(__uuidof(IDWriteFontFace5), (void **)&f5))) {
          need_color = f5->IsColorFont() != FALSE;
          if (!f5->HasVariations()) {
            int w = (int)f5->GetWeight();
            if (static_weight == 0 || w < static_weight) static_weight = w;
          }
          f5->Release();
        } else {
          IDWriteFontFace2 *f2 = NULL;
          if (SUCCEEDED(run->fontFace->QueryInterface(__uuidof(IDWriteFontFace2), (void **)&f2))) {
            need_color = f2->IsColorFont() != FALSE;
            f2->Release();
          }
        }
      } else {
        IDWriteFontFace2 *f2 = NULL;
        if (SUCCEEDED(run->fontFace->QueryInterface(__uuidof(IDWriteFontFace2), (void **)&f2))) {
          need_color = f2->IsColorFont() != FALSE;
          f2->Release();
        }
      }
    }
    if (!color && need_color) {
      IDWriteColorGlyphRunEnumerator *runs = NULL;
      if (SUCCEEDED(dw->TranslateColorGlyphRun(x, y, run, desc, mode, NULL, 0, &runs))) {
        color = 1;
        runs->Release();
      }
    }
    return S_OK;
  }
  STDMETHOD(DrawUnderline)(void *, FLOAT, FLOAT, DWRITE_UNDERLINE const *, IUnknown *) override {
    return S_OK;
  }
  STDMETHOD(DrawStrikethrough)(void *, FLOAT, FLOAT, DWRITE_STRIKETHROUGH const *, IUnknown *) override {
    return S_OK;
  }
  STDMETHOD(DrawInlineObject)(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override {
    return S_OK;
  }
};

static void target_ensure(Target *t, double scale) {
  if (t->rt && t->scale == scale) return;
  if (t->white) t->white->Release();
  if (t->black) t->black->Release();
  if (t->rt) t->rt->Release();
  t->white = NULL;
  t->black = NULL;
  t->rt = NULL;
  if (!t->wic || !t->d2d) return;
  if (!t->bitmap && FAILED(t->wic->CreateBitmap(RT_SIZE, RT_SIZE, GUID_WICPixelFormat32bppPBGRA,
                                                  WICBitmapCacheOnDemand, &t->bitmap)))
    return;
  float dpi = (float)(96.0 * scale);
  D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
  if (FAILED(t->d2d->CreateWicBitmapRenderTarget(t->bitmap, &p, &t->rt))) return;
  t->rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  t->rt->SetTextRenderingParams(params);
  t->rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), &t->white);
  t->rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &t->black);
  t->scale = scale;
}

// A cluster drawn: its picture (pw × ph pixels, RGBA, NULL none), its box in points as its entry has it, whether it is
// in its own colours (an emoji), and the measured ClusterBounds used to draw it
struct Drawn {
  int pw, ph;
  uint8_t *px;
  double w, h, ox, oy;
  int color;
  ClusterBounds bounds;
};

static void measure_bounds(IDWriteTextLayout *l, int weight, ClusterBounds *cb) {
  if (cb->valid) {
    if (l->GetMaxWidth() != (FLOAT)cb->box_w) l->SetMaxWidth((FLOAT)cb->box_w);
    if (l->GetMaxHeight() != (FLOAT)cb->box_h) l->SetMaxHeight((FLOAT)cb->box_h);
    return;
  }
  bool check_weight = (weight > 400 && weight < 700);
  ColorProbe probe;
  probe.check_weight = check_weight;
  l->Draw(NULL, &probe, 0, 0);
  DWRITE_TEXT_METRICS tm;
  DWRITE_LINE_METRICS lm;
  UINT32 nl = 0;
  l->GetMetrics(&tm);
  l->GetLineMetrics(&lm, 1, &nl);
  l->SetMaxWidth(tm.widthIncludingTrailingWhitespace);
  l->SetMaxHeight(tm.height);
  DWRITE_OVERHANG_METRICS om;
  l->GetOverhangMetrics(&om);
  // the ink box in layout coordinates (y down, the baseline at lm.baseline);
  // color glyphs and blanks use the typographic box
  double x0 = -om.left, y0 = -om.top;
  double x1 = tm.widthIncludingTrailingWhitespace + om.right, y1 = tm.height + om.bottom;
  if (probe.color || x1 - x0 <= 0 || y1 - y0 <= 0) {
    x0 = 0;
    y0 = 0;
    x1 = tm.widthIncludingTrailingWhitespace;
    y1 = tm.height;
  }
  cb->x0 = x0;
  cb->y0 = y0;
  cb->x1 = x1;
  cb->y1 = y1;
  cb->base = nl ? lm.baseline : 0;
  cb->box_w = tm.widthIncludingTrailingWhitespace;
  cb->box_h = tm.height;
  cb->color = probe.color;
  cb->static_weight = probe.static_weight;
  cb->valid = true;
}

// How much a stroke drawn in a face's Regular for a weight it has not grows on each side for each 100 asked over 400,
// a share of its size: as much heavier as PingFang SC's Medium is than its Regular on the Mac (render_words.sh's last
// line beside its second: 1.25 times the ink, the same here), so a Medium the face has not (Microsoft YaHei UI: 290,
// 400, 700, DirectWrite taking 500 to its 400, 600 to its 700) still reads as one; nothing else is grown: what the Apple hosts draw is the outline's own cover, no
// dilation (its ink a point the same at 1, 1.5 and 2; render_words.sh, 2026-11-16).
static const double MEDIUM_EM = 0.0075;

// How far the edges of a cluster drawn in gray are moved out, in fine pixels (0: none).
static double grown_fine(const ClusterBounds *cb, double size, int weight, double sc) {
  if (weight > 400 && weight < 700 && cb->static_weight > 0 && cb->static_weight <= 400)
    return MEDIUM_EM * (weight - 400) / 100.0 * size * sc * FINE;
  return 0;
}

// The fine target of `t` at `scale` (FINE times its pixels), `fw` × `fh` of them at least, made when it is not (its
// bitmap made larger, a 64-pixel step at a time, only where a cluster is larger than any before: most are a glyph's,
// a word drawn whole the widest).
static bool fine_ensure(Target *t, double scale, int fw, int fh) {
  bool larger = fw > t->fine_w || fh > t->fine_h;
  if (t->fine_rt && t->fine_scale == scale && !larger) return true;
  if (t->fine_black) t->fine_black->Release();
  if (t->fine_rt) t->fine_rt->Release();
  t->fine_black = NULL;
  t->fine_rt = NULL;
  if (larger) {
    if (t->fine_bitmap) t->fine_bitmap->Release();
    t->fine_bitmap = NULL;
    t->fine_w = ((fw > t->fine_w ? fw : t->fine_w) + 63) & ~63;
    t->fine_h = ((fh > t->fine_h ? fh : t->fine_h) + 63) & ~63;
  }
  if (!t->wic || !t->d2d) return false;
  if (!t->fine_bitmap && FAILED(t->wic->CreateBitmap((UINT)t->fine_w, (UINT)t->fine_h, GUID_WICPixelFormat32bppPBGRA,
                                                       WICBitmapCacheOnDemand, &t->fine_bitmap))) {
    t->fine_w = t->fine_h = 0;
    return false;
  }
  float dpi = (float)(96.0 * scale * FINE);
  D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
  if (FAILED(t->d2d->CreateWicBitmapRenderTarget(t->fine_bitmap, &p, &t->fine_rt))) return false;
  t->fine_rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  t->fine_rt->SetTextRenderingParams(params_gray);
  t->fine_rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &t->fine_black);
  t->fine_scale = scale;
  return true;
}

// A cluster's cover drawn at FINE times its pixels (pw × ph of them, its top left at x0, y0 in points, shifted across by
// `dx` points: a quarter pixel's phase is a whole fine pixel), its edges moved out `grow` fine pixels, averaged back
// into `px` (RGBA, each the cover). False when it could not be drawn so.
//
// The edges are moved along the cover's own gradient, the same way whichever way a stroke runs (a level set of the
// cover advected outward, first order: A + δ·|∇A|, the gradient by central differences): a horizontal, a vertical, a
// diagonal and a curve grow alike, the middle of a narrow counter (where the gradient is nothing, its two sides
// pulling apart) does not fill, and a quarter pixel's shift is a whole fine pixel's, so each phase is the same picture
// moved (hostapi's atlas keeps four).
static inline uint8_t fine_cover_from_sum(int sum) {
  int c = (sum + (FINE * FINE) / 2) / (FINE * FINE);
  return (uint8_t)(c > 255 ? 255 : c);
}

static void fine_downsample_nogrow(const uint8_t *src, UINT stride, int pw, int ph, uint8_t *px) {
  for (int y = 0; y < ph; y++) {
    const uint8_t *row0 = src + (size_t)(y * FINE) * stride;
    for (int x = 0; x < pw; x++) {
      int inv = 0;
      const uint8_t *cell = row0 + (size_t)(x * FINE) * 4;
      for (int j = 0; j < FINE; j++) {
        const uint8_t *s = cell + (size_t)j * stride;
        for (int k = 0; k < FINE; k++) inv += s[k * 4 + 1];
      }
      uint8_t c = fine_cover_from_sum(255 * FINE * FINE - inv);
      uint8_t *o = px + ((size_t)y * pw + x) * 4;
      o[0] = o[1] = o[2] = o[3] = c;
    }
  }
}

static bool draw_fine(IDWriteTextLayout *l, double sc, double x0, double y0, double dx, int pw, int ph, double grow,
                      Target *t, uint8_t *px) {
  int fw = pw * FINE, fh = ph * FINE;
  if (!fine_ensure(t, sc, fw + 1, fh + 1)) return false;
  ID2D1RenderTarget *rt = t->fine_rt;
  rt->BeginDraw();
  rt->PushAxisAlignedClip(D2D1::RectF(0.0f, 0.0f, (FLOAT)((fw + 1) / (sc * FINE)), (FLOAT)((fh + 1) / (sc * FINE))),
                          D2D1_ANTIALIAS_MODE_ALIASED);
  rt->Clear(D2D1::ColorF(1, 1, 1, 1));
  rt->DrawTextLayout(D2D1::Point2F((FLOAT)(-x0 + dx), (FLOAT)-y0), l, t->fine_black,
                     D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
  rt->PopAxisAlignedClip();
  if (FAILED(rt->EndDraw())) return false;
  WICRect r = {0, 0, fw, fh};
  IWICBitmapLock *lock = NULL;
  if (FAILED(t->fine_bitmap->Lock(&r, WICBitmapLockRead, &lock))) return false;
  UINT stride = 0, bytes = 0;
  BYTE *src = NULL;
  lock->GetStride(&stride);
  lock->GetDataPointer(&bytes, &src);
  if (grow <= 0.0) {
    // No dilation: downsample directly from the locked WIC bitmap in pure integer arithmetic (zero allocations).
    fine_downsample_nogrow(src, stride, pw, ph, px);
    lock->Release();
    return true;
  }
  size_t need = (size_t)fw * (size_t)fh;
  if (need > t->fine_cap) {
    float *na = (float *)realloc(t->fine_a, sizeof(float) * need);
    if (!na) {
      lock->Release();
      return false;
    }
    t->fine_a = na;
    float *ng = (float *)realloc(t->fine_g, sizeof(float) * need);
    if (!ng) {
      lock->Release();
      return false;
    }
    t->fine_g = ng;
    t->fine_cap = need;
  }
  // the cover, 0..1 (black on white at linear gamma: 255 less the green)
  float *a = t->fine_a;
  for (int y = 0; y < fh; y++) {
    const BYTE *s = src + (size_t)y * stride;
    for (int x = 0; x < fw; x++) a[(size_t)y * fw + x] = (255 - s[x * 4 + 1]) / 255.0f;
  }
  lock->Release();
  // (the step: an edge's cover goes from 0 to 1 within a fine pixel, where a central difference is a half; δ twice
  // the distance moved)
  float delta = (float)(2.0 * grow);
  float *g = t->fine_g;
  for (int y = 0; y < fh; y++) {
    for (int x = 0; x < fw; x++) {
      size_t i = (size_t)y * fw + x;
      float gx = ((x + 1 < fw ? a[i + 1] : 0.0f) - (x > 0 ? a[i - 1] : 0.0f)) * 0.5f;
      float gy = ((y + 1 < fh ? a[i + fw] : 0.0f) - (y > 0 ? a[i - fw] : 0.0f)) * 0.5f;
      float v = a[i] + delta * sqrtf(gx * gx + gy * gy);
      g[i] = v > 1.0f ? 1.0f : v;
    }
  }
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      float sum = 0;
      for (int j = 0; j < FINE; j++) {
        const float *row = g + (size_t)(y * FINE + j) * fw + x * FINE;
        for (int k = 0; k < FINE; k++) sum += row[k];
      }
      int c = (int)(sum * (255.0f / (FINE * FINE)) + 0.5f);
      uint8_t *o = px + ((size_t)y * pw + x) * 4;
      o[0] = o[1] = o[2] = o[3] = (uint8_t)(c > 255 ? 255 : c);
    }
  }
  return true;
}

// A cluster's layout drawn in white at `sc` pixels a point (shifted horizontally by `dx` points for its
// quarter-pixel subpixel phase), a pixel round its cached bounds `cb`, on `t`; `size` and `weight` as it was asked.
static void draw_cluster(IDWriteTextLayout *l, const ClusterBounds *cb, double sc, double dx, double size, int weight,
                         Target *t, Drawn *d) {
  *d = {};
  int color = cb->color;
  // The bitmap's edges on whole pixels from the baseline, a pixel of room
  // around: the baseline then falls on a pixel row of every glyph's bitmap,
  // so glyphs placed on the same rounded baseline line up.
  // (across, where its ink is once moved by its phase's `dx`: a pixel of room on both sides at every phase)
  double base = cb->base;
  int px0 = (int)floor((cb->x0 + dx) * sc) - 1, px1 = (int)ceil((cb->x1 + dx) * sc) + 1;
  int py0 = (int)floor((cb->y0 - base) * sc) - 1, py1 = (int)ceil((cb->y1 - base) * sc) + 1;
  double x0 = px0 / sc;
  double y0 = base + py0 / sc;
  int pw = px1 - px0, ph = py1 - py0;
  if (pw <= 0 || ph <= 0 || pw > RT_SIZE || ph > RT_SIZE) return;
  bool mono = !color && (params_ct || params_gray);
  bool ct = mono && use_cleartype(sc);
  d->w = pw / sc;
  d->h = ph / sc;
  d->ox = x0;
  d->oy = y0 - base;
  // In gray, at 15 pixels an em and more: drawn fine and averaged back (init: params_gray).
  if (mono && !ct && size * sc >= 15.0) {
    uint8_t *px = (uint8_t *)malloc((size_t)pw * ph * 4);
    if (draw_fine(l, sc, x0, y0, dx, pw, ph, grown_fine(cb, size, weight, sc), t, px)) {
      d->pw = pw;
      d->ph = ph;
      d->px = px;
      d->bounds = *cb;
      return;
    }
    free(px);
  }
  target_ensure(t, sc);
  if (!t->rt) {
    *d = {};
    return;
  }
  // One colour: drawn black on opaque white at linear gamma with no contrast, each stripe's cover (255 - s) in its
  // channel (ClearType under 125% on RGB/BGR LCDs; else gray, the small hinted), the shader blending a mask stripe by
  // stripe (win_render.cpp fmain), its alpha their mean. Straight on the target: in a layer made for ClearType
  // (D2D1_LAYER_OPTIONS_INITIALIZE_FOR_CLEARTYPE) Direct2D drew it gray after all.
  // Clip to the glyph's own bounds so Clear() does not wipe the entire 512x512 (1 MiB) WIC bitmap per glyph.
  FLOAT clip_w = (FLOAT)((pw < RT_SIZE ? pw + 1 : pw) / sc);
  FLOAT clip_h = (FLOAT)((ph < RT_SIZE ? ph + 1 : ph) / sc);
  t->rt->BeginDraw();
  t->rt->PushAxisAlignedClip(D2D1::RectF(0.0f, 0.0f, clip_w, clip_h), D2D1_ANTIALIAS_MODE_ALIASED);
  t->rt->Clear(mono ? D2D1::ColorF(1, 1, 1, 1) : D2D1::ColorF(0, 0, 0, 0));
  if (mono) {
    t->rt->SetTextAntialiasMode(ct ? D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    t->rt->SetTextRenderingParams(ct ? params_ct : size * sc < 15.0 ? params_gray_small : params_gray);
  }
  t->rt->DrawTextLayout(D2D1::Point2F((FLOAT)(-x0 + dx), (FLOAT)-y0), l, mono ? t->black : t->white,
                        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT | D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
  t->rt->PopAxisAlignedClip();
  t->rt->EndDraw();
  if (mono) {
    t->rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    t->rt->SetTextRenderingParams(params);
  }
  WICRect r = {0, 0, pw, ph};
  IWICBitmapLock *lock = NULL;
  if (SUCCEEDED(t->bitmap->Lock(&r, WICBitmapLockRead, &lock))) {
    UINT stride = 0, bytes = 0;
    BYTE *src = NULL;
    lock->GetStride(&stride);
    lock->GetDataPointer(&bytes, &src);
    uint8_t *px = (uint8_t *)malloc((size_t)pw * ph * 4);
    for (int y = 0; y < ph; y++) {
      const BYTE *s = src + (size_t)y * stride;
      uint8_t *o = px + (size_t)y * pw * 4;
      for (int x = 0; x < pw; x++, s += 4, o += 4) {
        o[0] = mono ? (uint8_t)(255 - s[2]) : s[2];
        o[1] = mono ? (uint8_t)(255 - s[1]) : s[1];
        o[2] = mono ? (uint8_t)(255 - s[0]) : s[0];
        o[3] = mono ? (uint8_t)((o[0] + o[1] + o[2] + 1) / 3) : s[3];
        // premultiplied: drawn in white, a mask's pixel has its colour equal to its alpha; an emoji's does not
        if (color == 1 && o[3] > 64 && (o[0] + 32 < o[3] || o[1] + 32 < o[3] || o[2] + 32 < o[3])) color = 2;
      }
    }
    lock->Release();
    d->pw = pw;
    d->ph = ph;
    d->px = px;
    d->bounds = *cb;
  }
  // a color font's glyph drawn in the text's colour (Segoe UI Emoji's flags are letters): a mask after all
  d->color = color == 2;
}

// ---- drawing ahead: the glyphs a frame shaped (text.mbt glyphs_ahead) and the remaining subpixel phases of any
// glyph first drawn on the main thread, drawn by threads of their own a phase at a time: each glyph's first at the
// phase its key says (where its line put it), every glyph's before the rest of any; the frames' thread waits only for
// the phase it asks for while a thread draws it, and draws one no thread has begun ----

#define SUB_COUNT 4
#define SUB_ALL 0x0F

// Horizontal quarter-pixel shift (in device pixels) encoded in bits 26..27 of a glyph key (text.mbt glyph_col_sub: a
// half pixel is one phase, on the column to its right, never split between two):
// 0 -> 0.0, 1 -> +0.25, 2 -> -0.50, 3 -> -0.25.
static double sub_dx(int sub) {
  switch (sub) {
    case 1: return 0.25;
    case 2: return -0.50;
    case 3: return -0.25;
    default: return 0.0;
  }
}

// One glyph cluster asked to be drawn ahead: what it is drawn from (set before a thread has it, not changed after);
// under ahead_lock, by phase (bit `sub`), those asked and not begun (`want_mask`), those of them drawn before any other
// phase of any glyph (`first_mask`: the phase its line put it at, text.mbt laid_ahead), those a thread draws now
// (`drawing_mask`), those drawn and not taken (`have_mask`, their pictures in `drawn`); whether the frames' thread let
// go of it (`dropped`: what is still drawn of it then is let go); and how many hold it (`refs`: the frames' thread
// while it keeps it, each place in a queue, each thread drawing it), freed by the last of them.
struct Ahead {
  int key;
  WCHAR *text;
  int len;
  IDWriteTextFormat *format;
  IDWriteTypography *typography;
  double scale;
  double size;
  int weight;
  ClusterBounds bounds;
  uint8_t want_mask;
  uint8_t first_mask;
  uint8_t drawing_mask;
  uint8_t skip_mask;
  uint8_t have_mask;
  bool dropped;
  int refs;
  Drawn drawn[SUB_COUNT];
};

// A queue of glyphs for the threads ahead, oldest first (under ahead_lock).
struct AheadQueue {
  Ahead **at;
  int head, n, cap;
};

// The most glyph clusters asked for or drawn ahead and not all placed yet (the oldest drawn let go past it).
#define AHEAD_MOST 2048
static CRITICAL_SECTION ahead_lock;
static CONDITION_VARIABLE ahead_more;
static int ahead_started;
// (under ahead_lock) what the threads are to draw: each glyph's first phases, an item a phase, before any of the rest
// (an item a glyph)
static AheadQueue ahead_first, ahead_rest;
// (the frames' thread's) what was asked for and not placed yet, by key, and in the order asked
static Ahead **ahead_of;  // by key, n_entries' room
static int ahead_of_cap;
static Ahead **ahead_order;
static int order_head, order_n, order_cap;

static void ahead_free(Ahead *a) {
  if (a->format) a->format->Release();
  if (a->typography) a->typography->Release();
  free(a->text);
  for (int s = 0; s < SUB_COUNT; s++) free(a->drawn[s].px);
  free(a);
}

// `a` put last in `q`, which holds it (under ahead_lock).
static void queue_push(AheadQueue *q, Ahead *a) {
  if (q->n + 1 > q->cap) {
    int cap = q->cap ? q->cap * 2 : 256;
    Ahead **next = (Ahead **)malloc((size_t)cap * sizeof *next);
    for (int j = 0; j < q->n; j++) next[j] = q->at[(q->head + j) % q->cap];
    free(q->at);
    q->at = next;
    q->head = 0;
    q->cap = cap;
  }
  q->at[(q->head + q->n++) % q->cap] = a;
  a->refs++;
}

// The first of `q`, taken out with its hold (under ahead_lock; `q` not empty).
static Ahead *queue_pop(AheadQueue *q) {
  Ahead *a = q->at[q->head];
  q->head = (q->head + 1) % q->cap;
  q->n--;
  return a;
}

// A hold on `a` let go (under ahead_lock): whether it was the last, `a` to be freed (outside the lock).
static bool ahead_unref(Ahead *a) {
  return --a->refs == 0;
}

static IDWriteTextLayout *layout_with(const WCHAR *s, int len, IDWriteTextFormat *f, IDWriteTypography *typo) {
  IDWriteTextLayout *l = NULL;
  if (FAILED(dw->CreateTextLayout(s, (UINT32)len, f, 1e6f, 1e6f, &l))) return NULL;
  IDWriteTextLayout2 *l2 = NULL;
  if (SUCCEEDED(l->QueryInterface(__uuidof(IDWriteTextLayout2), (void **)&l2))) {
    l2->SetFontFallback(fallback);
    l2->Release();
  }
  if (typo) l->SetTypography(typo, {0, (UINT32)len});
  emoji_sequences(l, s, len);
  return l;
}

static bool ahead_begin_phase(Ahead *a, int s) {
  uint8_t bit = (uint8_t)(1 << s);
  EnterCriticalSection(&ahead_lock);
  bool drop_now = a->dropped || (a->skip_mask & bit) != 0;
  if (drop_now) {
    a->drawing_mask &= (uint8_t)~bit;
    a->skip_mask &= (uint8_t)~bit;
  }
  LeaveCriticalSection(&ahead_lock);
  return !drop_now;
}

static void ahead_finish_phase(Ahead *a, int s, bool built, Drawn d) {
  uint8_t bit = (uint8_t)(1 << s);
  EnterCriticalSection(&ahead_lock);
  a->drawing_mask &= (uint8_t)~bit;
  bool skipped = (a->skip_mask & bit) != 0;
  a->skip_mask &= (uint8_t)~bit;
  if (built && !a->dropped && !skipped) {
    a->drawn[s] = d;
    a->have_mask |= bit;
  } else {
    free(d.px);
  }
  LeaveCriticalSection(&ahead_lock);
}

// A thread drawing ahead (with a target of its own, on COM's multithreaded apartment): a glyph's first phase not begun,
// the oldest asked, else the rest of a glyph's phases, each phase given to the frames' thread as it is drawn.
static DWORD WINAPI ahead_thread(void *) {
  CoInitializeEx(NULL, COINIT_MULTITHREADED);
  Target t = {};
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), NULL, (void **)&t.d2d);
  CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory), (void **)&t.wic);
  int cur_prio = THREAD_PRIORITY_BELOW_NORMAL;
  for (;;) {
    EnterCriticalSection(&ahead_lock);
    Ahead *a = NULL;
    uint8_t claim = 0;
    int want_prio = THREAD_PRIORITY_BELOW_NORMAL;
    for (;;) {
      while (ahead_first.n == 0 && ahead_rest.n == 0) SleepConditionVariableCS(&ahead_more, &ahead_lock, INFINITE);
      if (ahead_first.n) {
        a = queue_pop(&ahead_first);
        uint8_t f = (uint8_t)(a->want_mask & a->first_mask);
        claim = (uint8_t)(f & -f);
        want_prio = THREAD_PRIORITY_NORMAL;
      } else {
        a = queue_pop(&ahead_rest);
        claim = (uint8_t)(a->want_mask & ~a->first_mask);
        want_prio = THREAD_PRIORITY_BELOW_NORMAL;
      }
      if (a->dropped) claim = 0;
      if (claim) break;
      // (nothing left of it to draw: its place in the queue let go)
      if (ahead_unref(a)) {
        LeaveCriticalSection(&ahead_lock);
        ahead_free(a);
        EnterCriticalSection(&ahead_lock);
      }
    }
    // (its place in the queue's hold this thread's while it draws)
    a->want_mask &= (uint8_t)~claim;
    a->first_mask &= (uint8_t)~claim;
    a->drawing_mask |= claim;
    LeaveCriticalSection(&ahead_lock);
    if (want_prio != cur_prio) {
      if (SetThreadPriority(GetCurrentThread(), want_prio) != 0) cur_prio = want_prio;
    }
    IDWriteTextLayout *l = t.d2d && t.wic ? layout_with(a->text, a->len, a->format, a->typography) : NULL;
    ClusterBounds cb = a->bounds;
    if (l) measure_bounds(l, a->weight, &cb);
    for (int s = 0; s < SUB_COUNT; s++) {
      uint8_t bit = (uint8_t)(1 << s);
      if (!(claim & bit)) continue;
      if (!ahead_begin_phase(a, s)) continue;
      Drawn d = {};
      bool built = l != NULL;
      if (built) draw_cluster(l, &cb, a->scale, sub_dx(s) / a->scale, a->size, a->weight, &t, &d);
      ahead_finish_phase(a, s, built, d);
    }
    if (l) l->Release();
    EnterCriticalSection(&ahead_lock);
    bool free_it = ahead_unref(a);
    LeaveCriticalSection(&ahead_lock);
    if (free_it) ahead_free(a);
  }
}

// (the frames' thread) its hold on `a` let go, and with it what is not begun of it: freed here when nothing else holds
// it, else by the last that does
static void ahead_drop(Ahead *a) {
  EnterCriticalSection(&ahead_lock);
  a->dropped = true;
  a->want_mask = 0;
  a->first_mask = 0;
  bool free_it = ahead_unref(a);
  LeaveCriticalSection(&ahead_lock);
  if (free_it) ahead_free(a);
}

static void order_remove_front(void) {
  order_head = (order_head + 1) % order_cap;
  order_n--;
}

static void order_clear_ptr(Ahead *a) {
  for (int i = 0; i < order_n; i++) {
    Ahead **at = &ahead_order[(order_head + i) % order_cap];
    if (*at == a) {
      *at = NULL;
      break;
    }
  }
}

// Everything asked for let go: the faces or the scale changed, and what is drawn with them with it.
static void ahead_forget(void) {
  for (int i = 0; i < n_entries; i++) entries[i].subs_queued = 0;
  for (int i = 0; i < order_n; i++) {
    Ahead *a = ahead_order[(order_head + i) % order_cap];
    if (!a) continue;
    if (a->key < ahead_of_cap) ahead_of[a->key] = NULL;
    ahead_drop(a);
  }
  order_n = order_head = 0;
}

// The oldest asked, let go with what of it is not begun, unless a thread draws a phase of it now; false when not. What
// of it was drawn and never taken, or never drawn, may be asked again.
static bool drop_oldest_drawn(void) {
  while (order_n > 0 && !ahead_order[order_head]) order_remove_front();
  if (order_n == 0) return false;
  Ahead *a = ahead_order[order_head];
  EnterCriticalSection(&ahead_lock);
  bool idle = a->drawing_mask == 0;
  uint8_t left_mask = (uint8_t)(a->have_mask | a->want_mask);
  LeaveCriticalSection(&ahead_lock);
  if (!idle) return false;
  if (a->key >= 0 && a->key < n_entries) entries[a->key].subs_queued &= (uint8_t)~left_mask;
  ahead_of[a->key] = NULL;
  order_remove_front();
  ahead_drop(a);
  return true;
}

// What was drawn ahead of `key` at subpixel phase `sub` and the scale of now, taken (true, its picture in *d); false
// when it was not ready (asked and not begun: no longer asked; being drawn on a worker thread — NORMAL for ahead_first,
// BELOW_NORMAL for ahead_rest — marked skipped via skip_mask so the worker discards it and the frames' thread draws it
// immediately without ever blocking).
static bool drawn_ahead(int key, int sub, Drawn *d) {
  if (sub < 0 || sub >= SUB_COUNT) return false;
  Ahead *a = key < ahead_of_cap ? ahead_of[key] : NULL;
  if (!a) return false;
  uint8_t bit = (uint8_t)(1 << sub);
  bool ok = false;
  EnterCriticalSection(&ahead_lock);
  if (a->want_mask & bit) {
    // (left out of what the threads draw, which pass over it where nothing is left)
    a->want_mask &= (uint8_t)~bit;
    a->first_mask &= (uint8_t)~bit;
  } else if (a->drawing_mask & bit) {
    // (a worker thread — NORMAL for ahead_first, BELOW_NORMAL for ahead_rest — is drawing this phase: never stall the
    // frames' thread on it; mark skip_mask so the worker frees its bitmap when done and draw here immediately)
    a->skip_mask |= bit;
  } else if ((a->have_mask & bit) && a->scale == text_scale) {
    *d = a->drawn[sub];
    a->drawn[sub] = {};
    a->have_mask &= (uint8_t)~bit;
    ok = true;
  }
  bool done = (a->want_mask | a->drawing_mask | a->have_mask) == 0 || a->scale != text_scale;
  LeaveCriticalSection(&ahead_lock);
  if (done) {
    ahead_of[key] = NULL;
    order_clear_ptr(a);
    ahead_drop(a);
  }
  return ok;
}

static void ahead_ensure_started(void) {
  if (ahead_started) return;
  ahead_started = 1;
  InitializeCriticalSection(&ahead_lock);
  InitializeConditionVariable(&ahead_more);
#ifndef MB_WIN_AHEAD_NO_THREADS
  // (a page's few hundred glyphs drawn in the time a frame or two takes, over the cores there are, the frames'
  // thread's left to it)
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  int threads = (int)si.dwNumberOfProcessors - 1;
  threads = threads < 1 ? 1 : threads > 4 ? 4 : threads;
  for (int i = 0; i < threads; i++) {
    HANDLE h = CreateThread(NULL, 0, ahead_thread, NULL, 0, NULL);
    if (h) SetThreadPriority(h, THREAD_PRIORITY_BELOW_NORMAL), CloseHandle(h);
  }
#else
  (void)&ahead_thread;
#endif
}

// Glyph `k` asked of the threads ahead at the phases of `mask`, those of `first` before any other phase of any glyph,
// where it is not asked already (and there is room): whether it was.
static bool ahead_enqueue_one(int k, uint8_t mask, uint8_t first) {
  if (k < 0 || k >= n_entries || mask == 0) return false;
  ahead_ensure_started();
  if (ahead_of_cap <= k) {
    int cap = n_entries * 2;
    if (cap <= k) cap = (k + 1) * 2;
    ahead_of = (Ahead **)realloc(ahead_of, (size_t)cap * sizeof *ahead_of);
    memset(ahead_of + ahead_of_cap, 0, (size_t)(cap - ahead_of_cap) * sizeof *ahead_of);
    ahead_of_cap = cap;
  }
  if (ahead_of[k]) return false;
  if (order_n >= AHEAD_MOST && !drop_oldest_drawn()) return false;
  glyph_entry *e = &entries[k];
  e->subs_queued |= mask;
  Ahead *a = (Ahead *)calloc(1, sizeof(Ahead));
  a->key = k;
  a->len = e->len;
  a->text = (WCHAR *)malloc(sizeof(WCHAR) * (e->len ? e->len : 1));
  memcpy(a->text, pool + e->off, sizeof(WCHAR) * e->len);
  a->format = format_for(e->size, e->weight, e->style);
  a->format->AddRef();
  a->typography = typography_for(e->style);
  if (a->typography) a->typography->AddRef();
  a->scale = text_scale;
  a->size = e->size;
  a->weight = e->weight;
  a->bounds = e->bounds;
  a->want_mask = mask;
  a->first_mask = (uint8_t)(first & mask);
  // (the frames' thread's hold, till it lets go of it)
  a->refs = 1;
  ahead_of[k] = a;
  if (order_n + 1 > order_cap) {
    int cap = order_cap ? order_cap * 2 : 256;
    Ahead **next = (Ahead **)malloc((size_t)cap * sizeof *next);
    for (int j = 0; j < order_n; j++) next[j] = ahead_order[(order_head + j) % order_cap];
    free(ahead_order);
    ahead_order = next;
    order_head = 0;
    order_cap = cap;
  }
  ahead_order[(order_head + order_n++) % order_cap] = a;
  EnterCriticalSection(&ahead_lock);
  for (int s = 0; s < SUB_COUNT; s++) {
    if (a->first_mask & (1 << s)) queue_push(&ahead_first, a);
  }
  if (a->want_mask & ~a->first_mask) queue_push(&ahead_rest, a);
  LeaveCriticalSection(&ahead_lock);
  return true;
}

// Glyph `k` asked of the threads ahead at `mask` (with `first` prioritized): adds phases to an existing Ahead if one is
// already tracked for `k`, else creates a new one.
static bool ahead_enqueue_phases(int k, uint8_t mask, uint8_t first) {
  if (k < 0 || k >= n_entries || mask == 0) return false;
  ahead_ensure_started();
  if (ahead_of_cap <= k) {
    int cap = n_entries * 2;
    if (cap <= k) cap = (k + 1) * 2;
    ahead_of = (Ahead **)realloc(ahead_of, (size_t)cap * sizeof *ahead_of);
    memset(ahead_of + ahead_of_cap, 0, (size_t)(cap - ahead_of_cap) * sizeof *ahead_of);
    ahead_of_cap = cap;
  }
  Ahead *a = ahead_of[k];
  if (a) {
    bool queued = false;
    EnterCriticalSection(&ahead_lock);
    if (!a->dropped && a->scale == text_scale) {
      uint8_t unskip = (uint8_t)(mask & a->drawing_mask & a->skip_mask);
      if (unskip) {
        a->skip_mask &= (uint8_t)~unskip;
      }
      uint8_t add = (uint8_t)(mask & ~(a->want_mask | a->drawing_mask | a->have_mask));
      if (add) {
        a->want_mask |= add;
        entries[k].subs_queued |= add;
        uint8_t add_first = (uint8_t)(first & add);
        if (add_first) {
          a->first_mask |= add_first;
          for (int s = 0; s < SUB_COUNT; s++) {
            if (add_first & (1 << s)) queue_push(&ahead_first, a);
          }
        }
        if (add & ~add_first) queue_push(&ahead_rest, a);
        queued = true;
      }
      uint8_t promote = (uint8_t)(first & a->want_mask & ~a->first_mask);
      if (promote) {
        a->first_mask |= promote;
        for (int s = 0; s < SUB_COUNT; s++) {
          if (promote & (1 << s)) queue_push(&ahead_first, a);
        }
        queued = true;
      }
    }
    LeaveCriticalSection(&ahead_lock);
    return queued;
  }
  return ahead_enqueue_one(k, mask, first);
}

// The glyphs of keys[0..n) (each with the phase to draw first: bits 26..27, where its line put it) to draw ahead at
// that phase alone on first sight; the remaining phases are queued into ahead_rest only once the same glyph is actually
// requested at a second distinct phase (horizontal subpixel motion).
extern "C" void mb_host_glyphs_ahead(int32_t *keys, int32_t n) {
  if (n <= 0 || !dw) return;
  int asked = 0;
  for (int32_t i = 0; i < n; i++) {
    if (keys[i] < 0) continue;
    int k = keys[i] & 0x03FFFFFF;
    int sub = (keys[i] >> 26) & 3;
    if (k >= n_entries) continue;
    uint8_t bit = (uint8_t)(1 << sub);
    uint8_t prev = entries[k].subs_queued;
    bool moved = prev != 0 && (prev & bit) == 0;
    uint8_t want = moved ? (uint8_t)(SUB_ALL & ~prev) : bit;
    if (ahead_enqueue_phases(k, want, bit)) asked++;
  }
  if (asked) WakeAllConditionVariable(&ahead_more);
}

// Glyph `full_key` drawn in white, a pixel round its bounds: its box (in its entry) and its picture, held for
// mb_host_glyph_put (where it goes in the atlas is MoonBit's: hostapi's atlas.mbt). From what was drawn ahead of it
// when ready, else drawn here using cached cluster bounds and layout; remaining subpixel phases are queued ahead only
// once this glyph is actually requested at a second distinct phase.
static void rasterize(int full_key) {
  int key = full_key & 0x03FFFFFF;
  int sub = (full_key >> 26) & 7;
  if (sub >= SUB_COUNT) sub = 0;
  free(held_px);
  held_px = NULL;
  held_key = -1;
  entries[key].w = entries[key].h = 0;
  Drawn d = {};
  uint8_t bit = (uint8_t)(1 << sub);
  glyph_entry *e = &entries[key];
  bool moved = e->subs_queued != 0 && (e->subs_queued & bit) == 0;
  if (!drawn_ahead(key, sub, &d)) {
    IDWriteTextLayout *l = main_layout_for(key);
    measure_bounds(l, e->weight, &e->bounds);
    draw_cluster(l, &e->bounds, text_scale, sub_dx(sub) / text_scale, e->size, e->weight, &main_target, &d);
  } else if (!e->bounds.valid && d.bounds.valid) {
    e->bounds = d.bounds;
  }
  e->subs_queued |= bit;
  if (moved) {
    uint8_t rem = (uint8_t)(SUB_ALL & ~e->subs_queued);
    if (rem && ahead_enqueue_phases(key, rem, 0)) WakeAllConditionVariable(&ahead_more);
  }
  if (d.px) {
    held_key = full_key;
    held_w = d.pw;
    held_h = d.ph;
    held_px = d.px;
  }
  e->w = d.w;
  e->h = d.h;
  e->ox = d.ox;
  e->oy = d.oy;
  e->color = d.color;
}

extern "C" void mb_host_glyph(int32_t key, double *out) {
  int base_key = key >= 0 ? (key & 0x03FFFFFF) : key;
  if (base_key < 0 || base_key >= n_entries) {
    for (int i = 0; i < 7; i++) out[i] = 0;
    return;
  }
  rasterize(key);
  glyph_entry *e = &entries[base_key];
  out[0] = 0;
  out[1] = 0;
  out[2] = e->w;
  out[3] = e->h;
  out[4] = e->ox;
  out[5] = e->oy;
  out[6] = e->color;
}

// The glyph drawn last put in the atlas, its top left at x, y.
extern "C" void mb_host_glyph_put(int32_t key, int32_t x, int32_t y) {
  if (key != held_key || !held_px) return;
  mb_atlas_upload(x, y, held_w, held_h, held_px);
  free(held_px);
  held_px = NULL;
  held_key = -1;
}

// The picture of the glyph drawn last, as mb_host_glyph_put would put it, copied out (RGBA, a mask's colour its
// cover): what words' halo is blurred from (src/ui/halo.mbt). 1 when given.
extern "C" int32_t mb_host_glyph_picture(int32_t key, moonbit_bytes_t out) {
  if (key != held_key || !held_px) return 0;
  size_t n = (size_t)held_w * held_h * 4;
  if ((size_t)Moonbit_array_length(out) < n) return 0;
  memcpy(out, held_px, n);
  return 1;
}

// Pixels made by MoonBit (a halo, RGBA) put in the atlas, their top left at x, y, as a glyph's are. 1 when put.
extern "C" int32_t mb_host_atlas_put(int32_t x, int32_t y, int32_t w, int32_t h, moonbit_bytes_t px) {
  if (w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > mb_atlas_size || y + h > mb_atlas_size) return 0;
  if ((size_t)Moonbit_array_length(px) < (size_t)w * h * 4) return 0;
  mb_atlas_upload(x, y, w, h, px);
  return 1;
}

// ---------------------------------------------------------------------------
// The platform's own drawing of a line (textref_native.mbt, for src/textdiff): DirectWrite's text layout with its
// default features (ligatures as any app has them) and the fonts above, drawn by Direct2D into a WIC bitmap with the
// rasterizer settings above, at the places mbui draws the same words.

static IWICBitmap *ref_bmp;
static ID2D1RenderTarget *ref_rt;
static ID2D1SolidColorBrush *ref_brush;
static int ref_w, ref_h;

static void ref_path(moonbit_string_t name, WCHAR *out, size_t cap) {
  const WCHAR *dir = _wgetenv(L"MBUI_SHOT_DIR");
  int n = Moonbit_array_length(name);
  _snwprintf(out, cap, L"%ls\\%.*ls.png", dir ? dir : L".", n, (const WCHAR *)name);
}

static void ref_release(void) {
  if (ref_brush) ref_brush->Release();
  if (ref_rt) ref_rt->Release();
  if (ref_bmp) ref_bmp->Release();
  ref_brush = NULL;
  ref_rt = NULL;
  ref_bmp = NULL;
}

static D2D1_COLOR_F rgb(int c) {
  return D2D1::ColorF(((c >> 16) & 255) / 255.0f, ((c >> 8) & 255) / 255.0f, (c & 255) / 255.0f, 1);
}

extern "C" void mb_host_ref_begin(double w, double h, double scale, int32_t bg) {
  init();
  ref_release();
  ref_w = (int)floor(w * scale + 0.5);
  ref_h = (int)floor(h * scale + 0.5);
  wic->CreateBitmap(ref_w, ref_h, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnDemand, &ref_bmp);
  float dpi = (float)(96.0 * scale);
  D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
  d2d->CreateWicBitmapRenderTarget(ref_bmp, &p, &ref_rt);
  bool ct = use_cleartype(scale);
  ref_rt->SetTextAntialiasMode(ct ? D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  ref_rt->SetTextRenderingParams(ct ? params_ct : params_gray);
  ref_rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &ref_brush);
  ref_rt->BeginDraw();
  ref_rt->Clear(rgb(bg));
}

extern "C" void mb_host_ref_text(moonbit_string_t text, double size, int32_t weight, int32_t style, double x,
                                 double base, int32_t color, double *out) {
  for (int i = 0; i < 5; i++) out[i] = 0;
  if (!ref_rt) return;
  int len = Moonbit_array_length(text);
  IDWriteTextLayout *l = NULL;
  dw->CreateTextLayout((const WCHAR *)text, (UINT32)len, format_for(size, weight, style), 1e6f, 1e6f, &l);
  IDWriteTextLayout2 *l2 = NULL;
  if (SUCCEEDED(l->QueryInterface(__uuidof(IDWriteTextLayout2), (void **)&l2))) {
    l2->SetFontFallback(fallback);
    l2->Release();
  }
  set_style_features(l, len, style);
  emoji_sequences(l, (const WCHAR *)text, len);
  DWRITE_LINE_METRICS lm;
  UINT32 nl = 0;
  l->GetLineMetrics(&lm, 1, &nl);
  DWRITE_TEXT_METRICS tm;
  l->GetMetrics(&tm);
  ref_brush->SetColor(rgb(color));
  ref_rt->DrawTextLayout(D2D1::Point2F((FLOAT)x, (FLOAT)(base - (nl ? lm.baseline : 0))), l, ref_brush,
                         D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT | D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
  out[0] = tm.widthIncludingTrailingWhitespace;
  l->Release();
}

extern "C" int32_t mb_host_ref_end(moonbit_string_t name) {
  if (!ref_rt) return 0;
  ref_rt->EndDraw();
  WCHAR path[1024];
  ref_path(name, path, 1024);
  int ok = 0;
  WICRect r = {0, 0, ref_w, ref_h};
  IWICBitmapLock *lock = NULL;
  IWICStream *stream = NULL;
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *frame = NULL;
  if (SUCCEEDED(ref_bmp->Lock(&r, WICBitmapLockRead, &lock))) {
    UINT stride = 0, bytes = 0;
    BYTE *px = NULL;
    lock->GetStride(&stride);
    lock->GetDataPointer(&bytes, &px);
    // the ground is opaque: premultiplied or not, the same bytes
    WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(wic->CreateStream(&stream)) && SUCCEEDED(stream->InitializeFromFilename(path, GENERIC_WRITE)) &&
        SUCCEEDED(wic->CreateEncoder(GUID_ContainerFormatPng, NULL, &enc)) &&
        SUCCEEDED(enc->Initialize(stream, WICBitmapEncoderNoCache)) && SUCCEEDED(enc->CreateNewFrame(&frame, NULL)) &&
        SUCCEEDED(frame->Initialize(NULL)) && SUCCEEDED(frame->SetSize((UINT)ref_w, (UINT)ref_h)) &&
        SUCCEEDED(frame->SetPixelFormat(&fmt)))
      ok = SUCCEEDED(frame->WritePixels((UINT)ref_h, stride, stride * ref_h, px)) && SUCCEEDED(frame->Commit()) &&
           SUCCEEDED(enc->Commit());
    lock->Release();
  }
  if (frame) frame->Release();
  if (enc) enc->Release();
  if (stream) stream->Release();
  ref_release();
  return ok;
}

extern "C" int32_t mb_host_ref_frame(moonbit_string_t name) {
  WCHAR path[1024];
  ref_path(name, path, 1024);
  return mb_render_snapshot(path);
}
