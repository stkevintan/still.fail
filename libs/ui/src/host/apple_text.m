// Text with Core Text: shaping into grapheme clusters with their advances,
// and rasterizing each cluster as it is asked for (drawn ahead, off the
// frames' thread, where it was shaped a frame before), put where MoonBit says
// (hostapi's atlas.mbt) in an atlas: the words' (their cover, a byte a texel)
// or colour glyphs' (RGBA).
#import "apple.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static double text_scale = 2.0;

typedef struct {
  double size;
  int weight;
  int style;  // 1 slanted, 2 the code face
  double w, h, ox, oy;
  int color;
  // where the shaper put the cluster's glyph in its line, past where it starts on its own (a CJK bracket after
  // another, set half a width closer)
  double dx;
  // (the frames' thread's) the quarter-pixel phases of it drawn here or asked to be drawn ahead (bit `sub`: glyph
  // keys' bits 26..27, text.mbt glyph_col_sub), so each is asked of the queue once
  uint8_t subs_queued;
} glyph_entry;

static NSMutableDictionary<NSString *, NSNumber *> *keys;
static NSMutableArray<NSString *> *texts;
static glyph_entry *entries;
static int n_entries, cap_entries;
static NSMutableDictionary<NSString *, id> *fonts;
static int generation;

moonbit_string_t mb_string_from_ns(NSString *s) {
  NSUInteger n = s.length;
  moonbit_string_t out = moonbit_make_string_raw((int32_t)n);
  [s getCharacters:(unichar *)out range:NSMakeRange(0, n)];
  return out;
}

NSString *mb_ns_from_string(moonbit_string_t s) {
  return [[NSString alloc] initWithCharacters:(const unichar *)s length:Moonbit_array_length(s)];
}

// The system font (style & 2: its monospaced face) at this size and weight;
// style & 1 its italic. A face without one (and what the cascade draws a
// cluster in, PingFang's Han) is slanted 12° as it is rasterized, as
// browsers synthesize an oblique.
static double last_size = -1;
static int last_weight = -1, last_style = -1;
static CTFontRef last_font;

// The serif face (style & 4): Songti SC (宋体, its Latin too) at the weight nearest; the system's face where there is
// no Songti.
static CTFontRef serif_font(double size, int weight) {
  NSString *face = weight >= 600 ? @"STSongti-SC-Bold" : weight <= 300 ? @"STSongti-SC-Light" : @"STSongti-SC-Regular";
  CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)face, size, NULL);
  if (f) {
    CFStringRef got = CTFontCopyPostScriptName(f);
    BOOL ok = got && [(__bridge NSString *)got hasPrefix:@"STSongti"];
    if (got) CFRelease(got);
    if (ok) return f;
    CFRelease(f);
  }
  return mb_platform_font(size, weight, 0);
}

// The faces given (mb_host_face_add, style.mbt): each a list of font files, by the weight each is for (0: one variable
// file for every weight), its descriptors read once.
#define MB_FACES 32
static NSMutableArray<NSNumber *> *face_weights[MB_FACES];
static NSMutableArray *face_descs[MB_FACES];  // CTFontDescriptorRef, as id
static bool face_no_lig[MB_FACES];

// The face a style is set in (style.mbt): the one it names; else code's for the code face, what people wrote's for
// theirs, the app's own words' for the rest (not the serif face's); 0: none given, the system's.
static int face_id(int style) {
  int f = (style >> 8) & 31;
  if (f > 0) return face_descs[f].count ? f : 0;
  if (style & 2) return face_descs[3].count ? 3 : 0;
  if (style & 4) return 0;
  if ((style & 16) && face_descs[2].count) return 2;
  return face_descs[1].count ? 1 : 0;
}

// Digits all one width (style.mbt style_tabular), as UIFont's monospacedDigitSystemFont: OpenType's 'tnum', which a
// face loaded from its file (Inter) takes and the system's too; the AAT selector beside it, as the system's face was
// set before (scripts/apple_text_test.m holds both faces' digits one width).
static NSArray *tabular_figures(void) {
  return @[
    @{(__bridge id)kCTFontOpenTypeFeatureTag : @"tnum", (__bridge id)kCTFontOpenTypeFeatureValue : @1},
    @{
      (__bridge id)kCTFontFeatureTypeIdentifierKey : @(kNumberSpacingType),
      (__bridge id)kCTFontFeatureSelectorIdentifierKey : @(kMonospacedNumbersSelector),
    },
  ];
}

// A CJK face's marks narrow among Latin letters (style.mbt style_proportional): its pwid, kern said with it (DirectWrite
// sets what has pwid unkerned otherwise; said here too, to be sure of it).
static NSArray *proportional_widths(void) {
  return @[
    @{(__bridge id)kCTFontOpenTypeFeatureTag : @"pwid", (__bridge id)kCTFontOpenTypeFeatureValue : @1},
    @{(__bridge id)kCTFontOpenTypeFeatureTag : @"kern", (__bridge id)kCTFontOpenTypeFeatureValue : @1},
  ];
}

// Face `face` at this size and weight: its file for the nearest weight, a variable one at the weight itself; its digits
// all one width where `tabular`, its marks narrow where `proportional`.
static CTFontRef face_font(int face, double size, int weight, bool tabular, bool proportional) {
  NSArray<NSNumber *> *ws = face_weights[face];
  NSUInteger best = 0;
  int bestd = INT_MAX;
  for (NSUInteger i = 0; i < ws.count; i++) {
    int w = ws[i].intValue;
    int d = w == 0 ? 0 : abs(w - weight);
    if (d < bestd) {
      bestd = d;
      best = i;
    }
  }
  CTFontDescriptorRef d = (__bridge CTFontDescriptorRef)face_descs[face][best];
  CTFontDescriptorRef at = NULL;
  if (ws[best].intValue == 0) {
    // 'wght': the variable file at this weight
    at = CTFontDescriptorCreateCopyWithVariation(d, (__bridge CFNumberRef)@(0x77676874), (CGFloat)weight);
  }
  // the app's words and what people wrote with the web's alternates (global.css.ts: font-feature-settings "cv11",
  // "ss01": Inter's single-storey a, its open digits; a face without them is as it is)
  CTFontDescriptorRef feat = NULL;
  NSMutableArray *fs = [NSMutableArray new];
  if (face == 1 || face == 2) {
    [fs addObject:@{(__bridge id)kCTFontOpenTypeFeatureTag : @"cv11", (__bridge id)kCTFontOpenTypeFeatureValue : @1}];
    [fs addObject:@{(__bridge id)kCTFontOpenTypeFeatureTag : @"ss01", (__bridge id)kCTFontOpenTypeFeatureValue : @1}];
  }
  if (face_no_lig[face]) {
    [fs addObject:@{(__bridge id)kCTFontOpenTypeFeatureTag : @"calt", (__bridge id)kCTFontOpenTypeFeatureValue : @0}];
    [fs addObject:@{(__bridge id)kCTFontOpenTypeFeatureTag : @"liga", (__bridge id)kCTFontOpenTypeFeatureValue : @0}];
    [fs addObject:@{(__bridge id)kCTFontOpenTypeFeatureTag : @"clig", (__bridge id)kCTFontOpenTypeFeatureValue : @0}];
  }
  if (tabular) [fs addObjectsFromArray:tabular_figures()];
  if (proportional) [fs addObjectsFromArray:proportional_widths()];
  if (fs.count) {
    feat = CTFontDescriptorCreateCopyWithAttributes(at ? at : d,
                                                    (__bridge CFDictionaryRef)@{(__bridge id)kCTFontFeatureSettingsAttribute : fs});
  }
  CTFontRef f = CTFontCreateWithFontDescriptor(feat ? feat : at ? at : d, size, NULL);
  if (feat) CFRelease(feat);
  if (at) CFRelease(at);
  return f;
}

// what is asked to be drawn ahead (below), let go
static void ahead_forget(void);

// What was shaped and drawn before a face changed: forgotten (MoonBit drops its glyphs as the generation moves on).
#define MB_FACE_TRY 7
static int face_gen[MB_FACES];
static int keys_stale;  // the keys made before forgotten as the next frame starts (keys_sweep)
static CTFontRef last_attrs_font;
static int last_attrs_style = -1;
static CFDictionaryRef last_attrs;
static void bmp_forget_face(int32_t face);

static void face_changed(int32_t face) {
  [fonts removeAllObjects];
  ahead_forget();
  last_size = -1;
  last_attrs_font = NULL;
  last_attrs_style = -1;
  if (last_attrs) {
    CFRelease(last_attrs);
    last_attrs = NULL;
  }
  if (face >= MB_FACE_TRY && face < MB_FACES) {
    face_gen[face]++;
    bmp_forget_face(face);
    return;
  }
  generation++;
  keys_stale = 1;
}

static void faces_changed(void) {
  face_changed(0);
}

// Drawn at this many pixels a point (the screen the window is on): a change draws every glyph again, as a face's does
// (MoonBit places a glyph by its pixels at the scale it was drawn at).
void mb_text_set_scale(double scale) {
  if (scale == text_scale) return;
  text_scale = scale;
  ahead_forget();
  generation++;
}

int32_t mb_host_face_add(int32_t face, moonbit_string_t path, int32_t weight) {
  if (face <= 0 || face >= MB_FACES) return 0;
  NSURL *url = [NSURL fileURLWithPath:mb_ns_from_string(path)];
  CFArrayRef ds = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
  if (!ds || CFArrayGetCount(ds) == 0) {
    if (ds) CFRelease(ds);
    return 0;
  }
  if (!face_descs[face]) {
    face_descs[face] = [NSMutableArray new];
    face_weights[face] = [NSMutableArray new];
  }
  [face_descs[face] addObject:(__bridge id)CFArrayGetValueAtIndex(ds, 0)];
  [face_weights[face] addObject:@(weight)];
  CFRelease(ds);
  face_changed(face);
  return 1;
}

int32_t mb_host_face_add_bytes(int32_t face, moonbit_bytes_t data, int32_t weight) {
  if (face <= 0 || face >= MB_FACES) return 0;
  CFDataRef d = CFDataCreate(NULL, data, Moonbit_array_length(data));
  CTFontDescriptorRef desc = CTFontManagerCreateFontDescriptorFromData(d);
  CFRelease(d);
  if (!desc) return 0;
  if (!face_descs[face]) {
    face_descs[face] = [NSMutableArray new];
    face_weights[face] = [NSMutableArray new];
  }
  [face_descs[face] addObject:(__bridge_transfer id)desc];
  [face_weights[face] addObject:@(weight)];
  face_changed(face);
  return 1;
}

// A family's weight as CSS says it (100 … 900), from Core Text's (-1 … 1; AppKit's NSFontWeight constants).
static int css_weight(double w) {
  static const double ct[] = {-0.8, -0.6, -0.4, 0.0, 0.23, 0.3, 0.4, 0.56, 0.62};
  int best = 3;
  for (int i = 0; i < 9; i++) {
    if (fabs(ct[i] - w) < fabs(ct[best] - w)) best = i;
  }
  return (best + 1) * 100;
}

// Face `face` set in the family installed here named `family`: its upright styles, each for its weight (a family's
// italics are not what its words take).
int32_t mb_host_face_add_family(int32_t face, moonbit_string_t family) {
  if (face <= 0 || face >= MB_FACES) return 0;
  NSDictionary *attrs = @{(id)kCTFontFamilyNameAttribute : mb_ns_from_string(family)};
  CTFontDescriptorRef base = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
  CFArrayRef ds = CTFontDescriptorCreateMatchingFontDescriptors(base, NULL);
  CFRelease(base);
  if (!ds) return 0;
  NSMutableArray *descs = [NSMutableArray new];
  NSMutableArray<NSNumber *> *weights = [NSMutableArray new];
  for (CFIndex i = 0; i < CFArrayGetCount(ds); i++) {
    CTFontDescriptorRef d = (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, i);
    NSDictionary *traits = (__bridge_transfer NSDictionary *)CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute);
    uint32_t symbolic = [traits[(id)kCTFontSymbolicTrait] unsignedIntValue];
    if (symbolic & kCTFontItalicTrait) continue;
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

// The font families installed here, as a JSON array of their names (the system's hidden ones, named with a dot first,
// left out); "" on iOS (no list of them to the app).
moonbit_string_t mb_host_local_font_families(void) {
#if TARGET_OS_OSX
  static NSString *cached = nil;
  if (!cached) {
    @autoreleasepool {
      NSArray<NSString *> *names = (__bridge_transfer NSArray *)CTFontManagerCopyAvailableFontFamilyNames();
      NSMutableArray<NSString *> *shown = [NSMutableArray new];
      for (NSString *n in names) {
        if (![n hasPrefix:@"."]) [shown addObject:n];
      }
      [shown sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
      NSData *json = [NSJSONSerialization dataWithJSONObject:shown options:0 error:nil];
      cached = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";
    }
  }
  return mb_string_from_ns(cached);
#else
  return mb_string_from_ns(@"");
#endif
}

void mb_host_face_clear(int32_t face) {
  if (face <= 0 || face >= MB_FACES) return;
  face_no_lig[face] = false;
  if (!face_descs[face].count) return;
  [face_descs[face] removeAllObjects];
  [face_weights[face] removeAllObjects];
  face_changed(face);
}

void mb_host_face_set_ligatures(int32_t face, int32_t on) {
  if (face <= 0 || face >= MB_FACES) return;
  bool no_lig = !on;
  if (face_no_lig[face] == no_lig) return;
  face_no_lig[face] = no_lig;
  face_changed(face);
}

void mb_host_request_frame(void);

#if TARGET_OS_OSX
static NSString *local_font_info_json;
static dispatch_once_t local_font_info_once;

static NSString *scan_local_font_info_macos(void) {
  @autoreleasepool {
    NSArray<NSString *> *names = (__bridge_transfer NSArray *)CTFontManagerCopyAvailableFontFamilyNames();
    NSMutableArray<NSString *> *shown = [NSMutableArray new];
    for (NSString *n in names) {
      if (![n hasPrefix:@"."]) [shown addObject:n];
    }
    [shown sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:shown.count];
    for (NSString *name in shown) {
      NSDictionary *attrs = @{(__bridge id)kCTFontFamilyNameAttribute : name};
      CTFontDescriptorRef base = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
      CFArrayRef ds = base ? CTFontDescriptorCreateMatchingFontDescriptors(base, NULL) : NULL;
      if (base) CFRelease(base);
      BOOL mono = NO, serif = NO, cjk = NO;
      NSString *localized = name;
      if (ds && CFArrayGetCount(ds) > 0) {
        CTFontDescriptorRef d = (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, 0);
        NSString *loc = (__bridge_transfer NSString *)CTFontDescriptorCopyLocalizedAttribute(
            d, kCTFontFamilyNameAttribute, NULL);
        if (loc && loc.length > 0) localized = loc;
        NSDictionary *traits = (__bridge_transfer NSDictionary *)CTFontDescriptorCopyAttribute(
            d, kCTFontTraitsAttribute);
        uint32_t sym = [traits[(__bridge id)kCTFontSymbolicTrait] unsignedIntValue];
        if (sym & kCTFontMonoSpaceTrait) mono = YES;
        uint32_t cls = sym & kCTFontClassMaskTrait;
        if (cls == kCTFontOldStyleSerifsClass || cls == kCTFontTransitionalSerifsClass ||
            cls == kCTFontModernSerifsClass || cls == kCTFontClarendonSerifsClass ||
            cls == kCTFontSlabSerifsClass || cls == kCTFontFreeformSerifsClass) {
          serif = YES;
        }
        NSArray<NSString *> *langs = (__bridge_transfer NSArray *)CTFontDescriptorCopyAttribute(
            d, kCTFontLanguagesAttribute);
        for (NSString *lang in langs) {
          if ([lang hasPrefix:@"zh"] || [lang hasPrefix:@"ja"] || [lang hasPrefix:@"ko"]) {
            cjk = YES;
            break;
          }
        }
      }
      if (ds) CFRelease(ds);
      [items addObject:@{
        @"name" : name,
        @"localized" : localized,
        @"mono" : @(mono),
        @"serif" : @(serif),
        @"cjk" : @(cjk),
      }];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
    return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[]";
  }
}
#endif

// Asynchronous non-blocking metadata scan on macOS: returns "" immediately on first call while GCD scans
// CTFontDescriptor attributes off the main thread, publishes the cached JSON, and wakes the UI via
// mb_host_request_frame(). Returns "" on iOS.
moonbit_string_t mb_host_local_font_info(void) {
#if TARGET_OS_OSX
  @autoreleasepool {
    NSString *ready = nil;
    @synchronized(@"mb_local_font_info") {
      ready = local_font_info_json;
    }
    if (ready) return mb_string_from_ns(ready);
    dispatch_once(&local_font_info_once, ^{
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *res = scan_local_font_info_macos();
        @synchronized(@"mb_local_font_info") {
          local_font_info_json = res;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          mb_host_request_frame();
        });
      });
    });
    return mb_string_from_ns(@"");
  }
#else
  return mb_string_from_ns(@"");
#endif
}

static CTFontRef font_for(double size, int weight, int style) {
  // the font asked for last, without building its key (most calls)
  if (size == last_size && weight == last_weight && style == last_style) return last_font;
  if (!fonts) fonts = [NSMutableDictionary new];
  NSString *k = [NSString stringWithFormat:@"%g/%d/%d", size, weight, style];
  id f = fonts[k];
  if (!f) {
    int face = face_id(style);
    CTFontRef base = face ? face_font(face, size, weight, (style & 32) != 0, (style & 64) != 0) : NULL;
    if (!base) {
      base = (style & 4) && !(style & 2) ? serif_font(size, weight) : mb_platform_font(size, weight, (style & 2) != 0);
      if (style & (32 | 64)) {
        // digits all one width (style.mbt style_tabular); marks narrow (style_proportional)
        NSMutableArray *fs = [NSMutableArray new];
        if (style & 32) [fs addObjectsFromArray:tabular_figures()];
        if (style & 64) [fs addObjectsFromArray:proportional_widths()];
        CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(
            (__bridge CFDictionaryRef)@{(__bridge id)kCTFontFeatureSettingsAttribute : fs});
        CTFontRef t = CTFontCreateCopyWithAttributes(base, 0.0, NULL, d);
        CFRelease(d);
        if (t) {
          CFRelease(base);
          base = t;
        }
      }
    }
    if (style & 1) {
      CTFontRef it = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, kCTFontTraitItalic, kCTFontTraitItalic);
      if (it) {
        CFRelease(base);
        base = it;
      }
    }
    f = (__bridge_transfer id)base;
    fonts[k] = f;
  }
  // kept alive by `fonts`
  last_size = size;
  last_weight = weight;
  last_style = style;
  last_font = (__bridge CTFontRef)f;
  return last_font;
}

void mb_host_font_metrics(double size, int32_t weight, int32_t style, double *out) {
  CTFontRef f = font_for(size, weight, style);
  out[0] = CTFontGetAscent(f);
  out[1] = CTFontGetDescent(f);
  out[2] = round(size * 1.42);
  // the font a Han ideograph falls back to: a line with Chinese in it is measured by the taller of the two (the system
  // font's is .PingFangUITextSC, made to the San Francisco's ascent and descent: the same numbers, macOS 26)
  CTFontRef han = CTFontCreateForString(f, CFSTR("\u56FD"), CFRangeMake(0, 1));
  out[3] = han ? CTFontGetAscent(han) : out[0];
  out[4] = han ? CTFontGetDescent(han) : out[1];
  if (han) CFRelease(han);
  out[5] = 0;  // lines as asked, not on whole pixels
}

// Whether Core Text's own spacing of Chinese and Japanese words is left out (MBUI_AUTOSPACE=off or =mbui takes
// priority over runtime mb_host_set_host_autospace): the line said to be English, where Core Text (macOS 27) puts
// no room between Han and a Latin letter and sets no full-width mark closer, its letters kerned as before.
static int autospace_override = 1;  // 0: off, 1: on (default)

static int unspaced(void) {
  static int env_said = -2;  // -2: unread, -1: unset, 0: forced on, 1: forced off
  if (env_said == -2) {
    const char *v = getenv("MBUI_AUTOSPACE");
    if (!v || !*v) env_said = -1;
    else env_said = (strcmp(v, "off") == 0 || strcmp(v, "mbui") == 0) ? 1 : 0;
  }
  if (env_said >= 0) return env_said;
  return autospace_override == 0 ? 1 : 0;
}

void mb_host_set_host_autospace(int32_t on) {
  int next = on ? 1 : 0;
  if (autospace_override == next) return;
  autospace_override = next;
  faces_changed();
}

static bool style_no_ligatures(int style) {
  if (style & 8) return true;
  int face = face_id(style);
  return face > 0 && face_no_lig[face];
}

// style & 8 or per-face ligatures disabled: no ligatures
static CTLineRef make_line_with(NSString *s, CTFontRef f, bool no_lig, bool no_autospace) {
  NSMutableDictionary *attrs = [@{
    (__bridge id)kCTFontAttributeName : (__bridge id)f,
    (__bridge id)kCTForegroundColorFromContextAttributeName : @YES,
  } mutableCopy];
  if (no_lig) attrs[(__bridge id)kCTLigatureAttributeName] = @0;
  if (no_autospace) attrs[(__bridge id)kCTLanguageAttributeName] = @"en";
  NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attrs];
  return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
}

static CTLineRef make_line(NSString *s, CTFontRef f, int style) {
  return make_line_with(s, f, style_no_ligatures(style), unspaced() != 0);
}

static int intern_at(NSString *cluster, double size, int weight, int style, double dx) {
  if (!keys) {
    keys = [NSMutableDictionary new];
    texts = [NSMutableArray new];
  }
  int fg = face_gen[face_id(style)];
  NSString *k = (dx == 0 && fg == 0)
                    ? [NSString stringWithFormat:@"%@\x01%g\x01%d\x01%d", cluster, size, weight, style]
                    : [NSString stringWithFormat:@"%@\x01%g\x01%d\x01%d\x01%.3f\x01%d", cluster, size, weight, style, dx, fg];
  NSNumber *n = keys[k];
  if (n) return n.intValue;
  if (n_entries == cap_entries) {
    cap_entries = cap_entries ? cap_entries * 2 : 1024;
    entries = realloc(entries, sizeof(glyph_entry) * cap_entries);
  }
  int id_ = n_entries++;
  entries[id_] = (glyph_entry){size, weight, style, 0, 0, 0, 0, 0, dx, 0};
  [texts addObject:cluster];
  keys[k] = @(id_);
  return id_;
}

static int intern(NSString *cluster, double size, int weight, int style) {
  return intern_at(cluster, size, weight, style, 0);
}

// The keys of single-unit BMP clusters (dx == 0), per font, in a 2-level paged table (256 pages of 256 ints,
// allocated on demand), found without building a string for the cluster and its key.
typedef struct {
  double size;
  int weight, style;
  int *pages[256];
} bmp_keys;
static bmp_keys *bmp_cache;
static int n_bmp, last_bmp = -1;

static void bmp_forget_face(int32_t face) {
  for (int i = 0; i < n_bmp; i++) {
    if (((bmp_cache[i].style >> 8) & 31) == face) {
      for (int p = 0; p < 256; p++) {
        free(bmp_cache[i].pages[p]);
        bmp_cache[i].pages[p] = NULL;
      }
    }
  }
}

static bmp_keys *bmp_for(double size, int weight, int style) {
  if (last_bmp >= 0) {
    bmp_keys *b = &bmp_cache[last_bmp];
    if (b->size == size && b->weight == weight && b->style == style) return b;
  }
  for (int i = 0; i < n_bmp; i++) {
    if (bmp_cache[i].size == size && bmp_cache[i].weight == weight && bmp_cache[i].style == style) {
      last_bmp = i;
      return &bmp_cache[i];
    }
  }
  bmp_cache = realloc(bmp_cache, sizeof(bmp_keys) * (size_t)(n_bmp + 1));
  bmp_keys *b = &bmp_cache[n_bmp];
  b->size = size;
  b->weight = weight;
  b->style = style;
  memset(b->pages, 0, sizeof(b->pages));
  last_bmp = n_bmp++;
  return b;
}

// The key of a single-unit BMP cluster (dx == 0) in this font.
static int bmp_key(bmp_keys *bk, unichar c, double size, int weight, int style) {
  int hi = c >> 8, lo = c & 0xFF;
  int *page = bk->pages[hi];
  if (!page) {
    page = malloc(sizeof(int) * 256);
    for (int i = 0; i < 256; i++) page[i] = -1;
    bk->pages[hi] = page;
  }
  if (page[lo] < 0) page[lo] = intern([NSString stringWithCharacters:&c length:1], size, weight, style);
  return page[lo];
}

// Whether `c` takes no room and draws nothing (zero width space, joiners, word joiner, the byte order mark). Where one
// ends the line, Core Text answers 0 as its offset (macOS 27.2): a composer's mark (`@[…]` drawn with one in each
// bracket's place, refs_look) at the end of its words had its last letter at no width and its closing bracket as wide
// as the whole line, the caret after it twice as far as the words went (2026-11-08). A caret before one stands where
// the next character that takes room starts.
static int takes_no_room(unichar c) {
  return c == 0x200B || c == 0x200C || c == 0x200D || c == 0x2060 || c == 0xFEFF;
}

static int is_han(unichar c) { return c >= 0x3400 && c <= 0x9FFF; }

// Whether every UTF-16 unit in `u[0..len)` is an extended grapheme cluster of its own (same safe BMP ranges as
// text.mbt's unit_clusters and Android MBText.unitClusters): none of surrogates, CR, combining marks, variation
// selectors, ZWJ, or takes_no_room characters are included.
static int is_unit_clusters(const unichar *u, int32_t len) {
  for (int32_t i = 0; i < len; i++) {
    unichar c = u[i];
    if (c >= 0x20 && c <= 0x7E) continue;
    if (c < 0x3000) {
      if (c == '\n' || c == '\t'
          || c == 0x00A5 || c == 0x00A7 || c == 0x00B0 || c == 0x00B1
          || c == 0x00B7 || c == 0x00D7 || c == 0x00F7
          || c == 0x2013 || c == 0x2014 || (c >= 0x2018 && c <= 0x201D)
          || c == 0x2022 || c == 0x2026 || c == 0x2030
          || c == 0x2032 || c == 0x2033 || c == 0x20AC || c == 0x2103) {
        continue;
      }
      return 0;
    }
    if (c <= 0x3029 || (c >= 0x3041 && c <= 0x3096) || (c >= 0x30A1 && c <= 0x30FF)
        || is_han(c) || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xFF01 && c <= 0xFF60)) {
      continue;
    }
    return 0;
  }
  return 1;
}

// Where a caret before character `i` of `u` stands in `line` (takes_no_room: those skipped).
static double offset_at(CTLineRef line, const unichar *u, NSUInteger len, NSUInteger i) {
  while (i < len && takes_no_room(u[i])) i++;
  return CTLineGetOffsetForStringIndex(line, (CFIndex)i, NULL);
}

// Frames'-thread scratch buffers for shape_line (never shared with the background rasterizer queues).
static uint8_t *shape_from;
static uint8_t *shape_simple;
static double *shape_glyph_adv;
static double *shape_glyph_x;
static size_t shape_char_cap;
static CFIndex *shape_idx;
static CGPoint *shape_pos;
static size_t shape_glyph_cap;

static CTLineRef make_line_cached(CFStringRef s, CTFontRef f, int style) {
  int flags = (style_no_ligatures(style) ? 1 : 0) | (unspaced() ? 2 : 0);
  if (f != last_attrs_font || flags != last_attrs_style || !last_attrs) {
    if (last_attrs) CFRelease(last_attrs);
    NSMutableDictionary *attrs = [@{
      (__bridge id)kCTFontAttributeName : (__bridge id)f,
      (__bridge id)kCTForegroundColorFromContextAttributeName : @YES,
    } mutableCopy];
    if (flags & 1) attrs[(__bridge id)kCTLigatureAttributeName] = @0;
    if (flags & 2) attrs[(__bridge id)kCTLanguageAttributeName] = @"en";
    last_attrs = (__bridge_retained CFDictionaryRef)[attrs copy];
    last_attrs_font = f;
    last_attrs_style = flags;
  }
  CFAttributedStringRef as = CFAttributedStringCreate(NULL, s, last_attrs);
  CTLineRef line = CTLineCreateWithAttributedString(as);
  CFRelease(as);
  return line;
}

// Every string is shaped by Core Text as a whole line. A fast path for printable ASCII (each character's advance and
// each pair's kerning learned once) was given up: Core Text kerns a letter by what is on both sides of it (macOS 27's
// system font: the "a" of "fail" 0.09 narrower than of "ail", the "v" of "hover" than of "ver"), so words laid out by
// pairs moved by up to half a point along a line from where Core Text has them, and words that were cut with an
// ellipsis (no longer ASCII) were laid out the other way: their letters shifted the moment they were cut.
static int32_t shape_line(moonbit_string_t text, int32_t len, double size, int32_t weight, int32_t style,
                          double *out, int32_t cap) {
  if (len <= 0 || cap <= 0) return 0;
  const unichar *u = (const unichar *)text;
  int units = is_unit_clusters(u, len);
  CFStringRef cf_s = CFStringCreateWithCharactersNoCopy(NULL, u, len, kCFAllocatorNull);
  NSString *s = (__bridge NSString *)cf_s;
  CTFontRef f = font_for(size, weight, style);
  CTLineRef line = make_line_cached(cf_s, f, style);
  // Reusable frames'-thread scratch buffers:
  // - from[j]: whether any glyph came from character j (0 = part of a preceding ligature -> key -2)
  // - simple[j]: whether character j is in a 1-to-1 monotonic LTR run
  // - glyph_adv[j]: visual glyph advance sum (used for RTL lines)
  // - glyph_x[j]: leftmost glyph x position for character j (NAN: none)
  size_t need_chars = (size_t)len + 1;
  if (need_chars > shape_char_cap) {
    size_t nc = shape_char_cap ? shape_char_cap : 256;
    while (nc < need_chars) nc *= 2;
    shape_from = realloc(shape_from, nc);
    shape_simple = realloc(shape_simple, nc);
    shape_glyph_adv = realloc(shape_glyph_adv, sizeof(double) * nc);
    shape_glyph_x = realloc(shape_glyph_x, sizeof(double) * nc);
    shape_char_cap = nc;
  }
  uint8_t *from = shape_from;
  uint8_t *simple = shape_simple;
  double *glyph_adv = shape_glyph_adv;
  double *glyph_x = shape_glyph_x;
  memset(from, 0, need_chars);
  memset(simple, 0, need_chars);
  memset(glyph_adv, 0, sizeof(double) * need_chars);
  for (int32_t j = 0; j <= len; j++) glyph_x[j] = NAN;
  int any_rtl = 0;
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  CFIndex n_runs = CFArrayGetCount(runs);
  for (CFIndex r = 0; r < n_runs; r++) {
    CTRunRef run = CFArrayGetValueAtIndex(runs, r);
    CFIndex gc = CTRunGetGlyphCount(run);
    if (gc <= 0) continue;
    const CFIndex *idx = CTRunGetStringIndicesPtr(run);
    const CGPoint *pos = CTRunGetPositionsPtr(run);
    if (!idx || !pos) {
      size_t need = (size_t)gc;
      if (need > shape_glyph_cap) {
        size_t nc = shape_glyph_cap ? shape_glyph_cap : 256;
        while (nc < need) nc *= 2;
        shape_idx = realloc(shape_idx, sizeof(CFIndex) * nc);
        shape_pos = realloc(shape_pos, sizeof(CGPoint) * nc);
        shape_glyph_cap = nc;
      }
      if (!idx) {
        CTRunGetStringIndices(run, CFRangeMake(0, 0), shape_idx);
        idx = shape_idx;
      }
      if (!pos) {
        CTRunGetPositions(run, CFRangeMake(0, 0), shape_pos);
        pos = shape_pos;
      }
    }
    CTRunStatus status = CTRunGetStatus(run);
    int rtl = (status & kCTRunStatusRightToLeft) != 0;
    if (rtl) any_rtl = 1;
    double w = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
    CFRange rr = CTRunGetStringRange(run);
    int run_1to1 = !rtl && !(status & kCTRunStatusNonMonotonic) && gc == rr.length;
    for (CFIndex g = 0; g < gc; g++) {
      CFIndex ci = idx[g];
      if (run_1to1 && ci != rr.location + g) run_1to1 = 0;
      if (ci < 0 || ci >= len) continue;
      from[ci] = 1;
      if (isnan(glyph_x[ci]) || pos[g].x < glyph_x[ci]) glyph_x[ci] = pos[g].x;
      double next = g + 1 < gc ? pos[g + 1].x : pos[0].x + w;
      glyph_adv[ci] += next - pos[g].x;
    }
    if (run_1to1 && rr.location >= 0 && rr.location + rr.length <= len) {
      memset(simple + rr.location, 1, (size_t)rr.length);
    }
  }
  bmp_keys *bk = bmp_for(size, weight, style);
  int32_t k = 0;
  NSUInteger i = 0;
  // a cluster starts where the one before it ended
  double x0 = (units && !any_rtl) ? 0.0 : offset_at(line, u, (NSUInteger)len, 0);
  int mono = (style & 2) != 0;
  while (i < (NSUInteger)len && k < cap) {
    NSRange r;
    if (units) {
      r = NSMakeRange(i, 1);
    } else {
      r = [s rangeOfComposedCharacterSequenceAtIndex:i];
      if (r.location != i) x0 = offset_at(line, u, (NSUInteger)len, r.location);
    }
    unichar c = u[r.location];
    double start_x = x0;
    NSUInteger next_i = r.location + r.length;
    double x1;
    // In a simple 1-to-1 monotonic LTR run without takes_no_room, the caret offset between two Han ideographs
    // (or between two printable ASCII characters in a monospaced face) has no kerning, punctuation squeezing, or
    // CJK-Latin auto-spacing, so it equals glyph_x[next_i] directly without a CTLineGetOffsetForStringIndex call.
    if (units && !any_rtl && next_i < (NSUInteger)len && simple[r.location] && simple[next_i]
        && !isnan(glyph_x[next_i])
        && ((is_han(c) && is_han(u[next_i]))
            || (mono && c >= 0x20 && c <= 0x7E && u[next_i] >= 0x20 && u[next_i] <= 0x7E))) {
      x1 = glyph_x[next_i];
    } else if (units && !any_rtl) {
      x1 = CTLineGetOffsetForStringIndex(line, (CFIndex)next_i, NULL);
    } else {
      x1 = offset_at(line, u, (NSUInteger)len, next_i);
    }
    double adv = x1 - x0;
    x0 = x1;
    if (any_rtl) {
      adv = 0;
      for (NSUInteger j = r.location; j < next_i; j++) adv += glyph_adv[j];
    }
    int key;
    if (c == '\n') {
      adv = 0;
      key = -1;
    } else if (c == ' ' || c == '\t') {
      key = -1;
    } else {
      int drawn = 0;
      double gx = NAN;
      if (r.length == 1) {
        drawn = from[r.location];
        gx = glyph_x[r.location];
      } else {
        for (NSUInteger j = r.location; j < next_i; j++) {
          drawn |= from[j];
          if (!isnan(glyph_x[j]) && (isnan(gx) || glyph_x[j] < gx)) gx = glyph_x[j];
        }
      }
      // a glyph the shaper moved within its cluster's advance (contextual spacing of CJK punctuation): drawn
      // there, not where it sits on its own
      // (the leftmost of its glyphs: a vowel sign the shaper put before its consonant is where it starts)
      double dx = any_rtl || isnan(gx) ? 0 : gx - start_x;
      if (fabs(dx) < 0.01) dx = 0;
      // A Latin letter right after Han (or kana, a full-width sign): the room Core Text puts between them since iOS 26
      // and macOS 27 is the letter's cluster's, before it, so it is drawn where its glyph is (else the room shows
      // after it: 你是O wner); elsewhere a letter is drawn where its cluster starts (a kerned pair's glyphs a hair
      // off it, as they always were)
      BOOL after_wide = r.location > 0 && u[r.location - 1] >= 0x2E80;
      if (!drawn && k > 0)
        key = -2;
      else if (r.length == 1 && (dx == 0 || (c < 128 && !after_wide)))
        key = bmp_key(bk, c, size, weight, style);
      else
        key = intern_at([NSString stringWithCharacters:u + r.location length:r.length], size, weight, style, dx);
    }
    out[k * 4] = r.location;
    out[k * 4 + 1] = r.length;
    out[k * 4 + 2] = adv < 0 ? 0 : adv;
    out[k * 4 + 3] = key;
    k++;
    i = next_i;
  }
  CFRelease(line);
  CFRelease(cf_s);
  return k;
}

// The key of a piece of text drawn whole (a word of a joining script, a ligature): host_native.mbt's text_key.
int32_t mb_host_text_key(moonbit_string_t text, double size, int32_t weight, int32_t style) {
  @autoreleasepool {
    return intern(mb_ns_from_string(text), size, weight, style);
  }
}

int32_t mb_host_shape(moonbit_string_t text, double size, int32_t weight, int32_t style, double *out) {
  @autoreleasepool {
    int32_t len = Moonbit_array_length(text);
    int32_t cap = Moonbit_array_length(out) / 4;
    return shape_line(text, len, size, weight, style, out, cap);
  }
}


// The side of the words' atlas, or of colour glyphs' (apple.h).
int32_t mb_host_atlas_size(int32_t colour) { return colour ? MB_ATLAS_COLOR_SIDE : MB_ATLAS_SIDE; }

// A glyph key's horizontal quarter-pixel phase (bits 26..27: text.mbt glyph_col_sub), in device pixels: how far right
// of the whole pixel column its quad is put on a glyph at it is drawn (win_text.cpp's, the same).
#define SUB_COUNT 4
#define SUB_ALL 0x0F
static double sub_dx(int sub) {
  switch (sub) {
    case 1: return 0.25;
    case 2: return -0.50;
    case 3: return -0.25;
    default: return 0.0;
  }
}

// A glyph key's base (its cluster's entry) and its phase.
static int key_base(int full_key) { return full_key >= 0 ? (full_key & 0x03FFFFFF) : full_key; }
static int key_sub(int full_key) {
  int sub = full_key >= 0 ? ((full_key >> 26) & 7) : 0;
  return sub < SUB_COUNT ? sub : 0;
}

// A cluster's picture: drawn in white at `sc` pixels a point, a pixel of room round it (no pixels: nothing to draw),
// on whichever thread draws it, from its font alone; and where it is from the pen (b, points, on whole pixels), whether
// it is drawn from a colour font. Its ink is drawn moved right of where it is on its own by `e_dx` points, past where
// Core Text puts its glyphs in a line of it alone (a cluster the shaper set closer in its line: glyph_entry's dx), and
// by `sub_px` device pixels (its phase: sub_dx), the bitmap's edges on whole pixels round the ink so moved: what is
// moved is drawn so, never a pixel's rounding of the picture's place added to it (b's left is the bitmap's, a whole
// pixel), so a glyph's ink lands within an eighth of a pixel of where it is laid out.
@interface MBDrawn : NSObject
@property(nonatomic) uint8_t *px;
@property(nonatomic) int pw, ph;
@property(nonatomic) CGRect b;
@property(nonatomic) int color;
@end
@implementation MBDrawn
- (void)dealloc { free(_px); }
@end

static MBDrawn *draw_cluster_with(NSString *cluster, CTFontRef f, int style, bool no_lig, bool no_autospace,
                                  double e_dx, double sub_px, double sc) {
  MBDrawn *d = [MBDrawn new];
  CTLineRef line = make_line_with(cluster, f, no_lig, no_autospace);
  // is it drawn from a color font (emoji)? slanted, from a face with no italic?
  int color = 0, oblique = 0;
  const double slant = 0.2126;  // tan 12°
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  if (CFArrayGetCount(runs) > 0) {
    CTRunRef run = CFArrayGetValueAtIndex(runs, 0);
    CTFontRef rf = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
    CTFontSymbolicTraits traits = rf ? CTFontGetSymbolicTraits(rf) : 0;
    if (traits & kCTFontTraitColorGlyphs) color = 1;
    if ((style & 1) && !color && !(traits & kCTFontTraitItalic)) oblique = 1;
  }
  // (set closer in its line: moved by as much as its glyphs sit further right there than they do on their own, the
  // leftmost of them)
  double shift = 0;
  if (e_dx != 0) {
    double iso = NAN;
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
      CTRunRef run = CFArrayGetValueAtIndex(runs, r);
      CFIndex gc = CTRunGetGlyphCount(run);
      CGPoint *pos = malloc(sizeof(CGPoint) * (gc > 0 ? gc : 1));
      CTRunGetPositions(run, CFRangeMake(0, 0), pos);
      for (CFIndex g = 0; g < gc; g++)
        if (isnan(iso) || pos[g].x < iso) iso = pos[g].x;
      free(pos);
    }
    shift = e_dx - (isnan(iso) ? 0 : iso);
  }
  shift += sub_px / sc;
  CGRect b = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
  if (color || b.size.width <= 0 || b.size.height <= 0) {
    CGFloat asc, desc;
    double w = CTLineGetTypographicBounds(line, &asc, &desc, NULL);
    b = CGRectMake(0, -desc, w, asc + desc);
  }
  if (oblique) {
    // what is above the baseline leans right, what is below left
    double top = b.origin.y + b.size.height, bottom = b.origin.y;
    double l = b.origin.x + (bottom < 0 ? slant * bottom : 0);
    double r = b.origin.x + b.size.width + (top > 0 ? slant * top : 0);
    b = CGRectMake(l, b.origin.y, r - l, b.size.height);
  }
  // The bitmap's edges on whole pixels from the baseline, a pixel of room
  // around: the baseline then falls on a pixel row of every glyph's bitmap,
  // so glyphs placed on the same rounded baseline line up (rounding each
  // glyph's own fractional top made them wander up and down a pixel). Across,
  // round the ink where it is drawn, moved by `shift`.
  int x0 = (int)floor((b.origin.x + shift) * sc) - 1, y0 = (int)floor(b.origin.y * sc) - 1;
  int x1 = (int)ceil((b.origin.x + b.size.width + shift) * sc) + 1;
  int y1 = (int)ceil((b.origin.y + b.size.height) * sc) + 1;
  b = CGRectMake(x0 / sc, y0 / sc, (x1 - x0) / sc, (y1 - y0) / sc);
  int pw = x1 - x0, ph = y1 - y0;
  if (pw <= 0 || ph <= 0 || pw > 512 || ph > 512) {
    CFRelease(line);
    return d;
  }
  size_t bpr = (size_t)pw * 4;
  uint8_t *px = calloc(bpr * ph, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(px, pw, ph, 8, bpr, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGContextScaleCTM(ctx, sc, sc);
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextSetShouldSmoothFonts(ctx, false);
  // (its glyphs at their own places: by default Core Text puts a glyph on the nearest half pixel, so a quarter
  // pixel's phase drew as none or as half a pixel, scripts/apple_text_test.m)
  CGContextSetShouldSubpixelPositionFonts(ctx, true);
  CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
  CGContextSetTextMatrix(ctx, oblique ? CGAffineTransformMake(1, 0, slant, 1, 0, 0) : CGAffineTransformIdentity);
  CGContextSetTextPosition(ctx, -b.origin.x + shift, -b.origin.y);
  CTLineDraw(line, ctx);
  if (!color) {
    // (drawn in white: its cover alone is kept, the words' atlas's byte a texel)
    uint8_t *a = malloc((size_t)pw * ph);
    for (size_t i = 0; i < (size_t)pw * ph; i++) a[i] = px[i * 4 + 3];
    free(px);
    px = a;
  }
  d.px = px;
  d.pw = pw;
  d.ph = ph;
  d.b = b;
  d.color = color;
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CFRelease(line);
  return d;
}

static MBDrawn *draw_cluster(NSString *cluster, CTFontRef f, int style, double e_dx, double sub_px, double sc) {
  return draw_cluster_with(cluster, f, style, style_no_ligatures(style), unspaced() != 0, e_dx, sub_px, sc);
}

// the glyph drawn last (mb_host_glyph), its picture until it is put in its atlas (mb_host_glyph_put): its key with its
// phase
static int held_key = -1;
static MBDrawn *held;

// The glyph of `full_key` from its picture (drawn at text_scale): its box (in its cluster's entry), and the picture
// held for mb_host_glyph_put (where it goes in its atlas is MoonBit's: hostapi's atlas.mbt). Its left is the bitmap's,
// a whole pixel: where the shaper set it and its phase are in the picture (draw_cluster).
static void place(int full_key, MBDrawn *d) {
  glyph_entry *e = &entries[key_base(full_key)];
  held = nil;
  held_key = -1;
  e->w = e->h = 0;
  if (!d.px) return;
  held = d;
  held_key = full_key;
  double sc = text_scale;
  CGRect b = d.b;
  e->w = d.pw / sc;
  e->h = d.ph / sc;
  e->ox = b.origin.x;
  e->oy = -(b.origin.y + b.size.height);
  e->color = d.color;
}

// ---- drawing ahead: the glyphs a frame shaped and did not draw (text.mbt glyphs_ahead), and the phases of a glyph
// first drawn on the frames' thread that it was not drawn at, drawn on queues of their own, as Android's MBText draws
// them on threads of their own and win_text.cpp on threads of theirs; each phase taken as it is first asked for, from
// what was drawn ahead: waited for while a queue draws that phase, drawn here when none has begun it. So a word
// moved across by less than a pixel finds the phases it comes to drawn (ui's view_rephase). A phase at a time: a
// frame's glyphs each first at the phase its key says (bits 26..27: where its line put it, text.mbt laid_ahead; 0 for
// one shaped and not laid out), over the cores, before any other phase of theirs, which a queue of less weight draws
// after ----

// One glyph asked to be drawn ahead at some of its phases: what it is drawn from (set before a queue has it, not
// changed after); under ahead_lock, by phase (bit `sub`), those asked and not begun (`want`), those of them drawn
// first (`first`), those being drawn (`drawing`), those drawn and not taken (`have`) and their pictures, and whether
// it was let go (`gone`: what is still drawn of it then is dropped).
@interface MBAhead : NSObject
@property(nonatomic) int key;
@property(nonatomic, copy) NSString *cluster;
@property(nonatomic, strong) id font;  // a CTFontRef
@property(nonatomic) int style;
@property(nonatomic) BOOL noLig;
@property(nonatomic) BOOL noAutospace;
@property(nonatomic) double dx;
@property(nonatomic) double scale;
@property(nonatomic) BOOL gone;
// (the frames' thread's) the batch it was asked in (ahead_batch)
@property(nonatomic) unsigned batch;
@property(nonatomic) uint8_t want;
@property(nonatomic) uint8_t first;
@property(nonatomic) uint8_t drawing;
@property(nonatomic) uint8_t have;
// by phase: an MBDrawn, NSNull where none
@property(nonatomic, strong) NSMutableArray *drawn;
@end
@implementation MBAhead
@end

// The most glyphs asked for or drawn ahead and not placed yet (the oldest let go past it).
#define AHEAD_MOST 1024
static pthread_mutex_t ahead_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ahead_drawn = PTHREAD_COND_INITIALIZER;
// the first phases' queue and the rest's, of less weight
static dispatch_queue_t ahead_q, ahead_rest_q;
// (the frames' thread's) what was asked for and not all taken yet, by key, and in the order asked
static NSMutableDictionary<NSNumber *, MBAhead *> *ahead_of;
static NSMutableOrderedSet<MBAhead *> *ahead_order;
// (the frames' thread's) the batch of glyphs asked now (mb_host_glyphs_ahead), counted
static unsigned ahead_batch;

// A phase of `a` drawn: the lowest of its first not begun, or (`first` NO) of the rest; nothing where none is left.
static void draw_ahead(MBAhead *a, BOOL first) {
  pthread_mutex_lock(&ahead_lock);
  uint8_t of = first ? (uint8_t)(a.want & a.first) : (uint8_t)(a.want & ~a.first);
  uint8_t bit = a.gone ? 0 : (uint8_t)(of & -of);
  if (bit) {
    a.want = (uint8_t)(a.want & ~bit);
    a.first = (uint8_t)(a.first & ~bit);
    a.drawing = (uint8_t)(a.drawing | bit);
  }
  pthread_mutex_unlock(&ahead_lock);
  if (!bit) return;
  int s = __builtin_ctz(bit);
  MBDrawn *d;
  @autoreleasepool {
    d = draw_cluster_with(a.cluster, (__bridge CTFontRef)a.font, a.style, a.noLig, a.noAutospace, a.dx, sub_dx(s), a.scale);
  }
  pthread_mutex_lock(&ahead_lock);
  a.drawing = (uint8_t)(a.drawing & ~bit);
  if (d && !a.gone) {
    a.drawn[s] = d;
    a.have = (uint8_t)(a.have | bit);
  }
  pthread_cond_broadcast(&ahead_drawn);
  pthread_mutex_unlock(&ahead_lock);
}

// `a` no longer asked for: out of what the frames' thread keeps (a queue that still has it passes over it).
static void ahead_let_go(MBAhead *a) {
  [ahead_of removeObjectForKey:@(a.key)];
  [ahead_order removeObject:a];
}

// The oldest asked, let go with what of it is not begun, unless a phase of it is being drawn now; false when not.
// What of it was drawn and never taken, or never drawn, may be asked again.
static BOOL drop_oldest_drawn(void) {
  MBAhead *a = ahead_order.firstObject;
  if (!a) return NO;
  pthread_mutex_lock(&ahead_lock);
  BOOL idle = a.drawing == 0;
  uint8_t left = (uint8_t)(a.have | a.want);
  if (idle) {
    a.gone = YES;
    a.drawn = nil;
    a.have = 0;
    a.want = 0;
    a.first = 0;
  }
  pthread_mutex_unlock(&ahead_lock);
  if (!idle) return NO;
  if (a.key >= 0 && a.key < n_entries) entries[a.key].subs_queued &= (uint8_t)~left;
  ahead_let_go(a);
  return YES;
}

// Everything asked for let go: the faces or the scale changed, and what is drawn in them with it.
static void ahead_forget(void) {
  for (int i = 0; i < n_entries; i++) entries[i].subs_queued = 0;
  if (!ahead_order.count) return;
  pthread_mutex_lock(&ahead_lock);
  for (MBAhead *a in ahead_order) {
    a.gone = YES;
    a.drawn = nil;
    a.have = 0;
    a.want = 0;
    a.first = 0;
  }
  pthread_mutex_unlock(&ahead_lock);
  [ahead_of removeAllObjects];
  [ahead_order removeAllObjects];
}

// The glyphs' keys and what each is of forgotten (the faces changed, or more than KEYS_MOST of them: each a cluster of a
// size, weight and style ever shaped, a run left open on changing text growing them without end), the generation moved
// on. Only where MoonBit reads the generation (text.mbt text_arrive, as a frame starts: what it shaped is dropped as it
// sees it moved; faces.mbt words_forgotten, what it shaped dropped just before), never where it may still draw by a key
// made before (a face given in a frame); a key past the table draws nothing (mb_host_glyph).
#define KEYS_MOST 65536
static void keys_sweep(void) {
  if (!keys_stale && n_entries <= KEYS_MOST) return;
  keys_stale = 0;
  ahead_forget();
  [keys removeAllObjects];
  [texts removeAllObjects];
  n_entries = 0;
  if (cap_entries > 1024) {
    free(entries);
    entries = NULL;
    cap_entries = 0;
  }
  for (int i = 0; i < n_bmp; i++) {
    for (int p = 0; p < 256; p++) free(bmp_cache[i].pages[p]);
  }
  free(bmp_cache);
  bmp_cache = NULL;
  n_bmp = 0;
  last_bmp = -1;
  held = nil;
  held_key = -1;
  generation++;
}

int32_t mb_host_atlas_generation(void) {
  keys_sweep();
  return generation;
}

// Glyph `k` asked to be drawn ahead at the phases of `want`, those of `first` before the rest (none of it asked before:
// its entry's subs_queued); the asked put in `asked` for the queues. False where it is not (asked
// already and not all taken, or too many asked).
static BOOL ahead_ask(int k, uint8_t want, uint8_t first, NSMutableArray<MBAhead *> *asked) {
  if (k < 0 || k >= n_entries || want == 0 || ahead_of[@(k)]) return NO;
  if (ahead_order.count >= AHEAD_MOST && !drop_oldest_drawn()) return NO;
  glyph_entry *e = &entries[k];
  e->subs_queued |= want;
  MBAhead *a = [MBAhead new];
  a.key = k;
  a.cluster = texts[k];
  a.font = (__bridge id)font_for(e->size, e->weight, e->style);
  a.style = e->style;
  a.noLig = style_no_ligatures(e->style);
  a.noAutospace = unspaced() != 0;
  a.dx = e->dx;
  a.scale = text_scale;
  a.want = want;
  a.first = first;
  a.batch = ahead_batch;
  a.drawn = [NSMutableArray arrayWithObjects:NSNull.null, NSNull.null, NSNull.null, NSNull.null, nil];
  ahead_of[@(k)] = a;
  [ahead_order addObject:a];
  [asked addObject:a];
  return YES;
}

// The phases of `asked` other than their first, a phase an item, in the order the queue of less weight draws them: a
// phase of every glyph in turn, one more of each before a third of any (so a page moved across by a quarter of a pixel
// a frame finds the next phase of all its glyphs drawn, not all four of a few).
static NSMutableArray<MBAhead *> *ahead_rests(NSArray<MBAhead *> *asked) {
  NSMutableArray<MBAhead *> *rests = [NSMutableArray new];
  for (int pass = 0; pass < SUB_COUNT; pass++) {
    for (MBAhead *a in asked) {
      if (pass < __builtin_popcount((uint8_t)(a.want & ~a.first))) [rests addObject:a];
    }
  }
  return rests;
}

// What was asked handed to the queues, a phase an item: each glyph's first phases over the cores there are (a page's
// few hundred drawn in the time a frame or two takes, not one after another), each batch after the one before; the
// rest of their phases on the queue of less weight (ahead_rests). `firsts`: more first phases of glyphs asked before.
static void ahead_go(NSMutableArray<MBAhead *> *asked, NSMutableArray<MBAhead *> *firsts) {
  if (!asked.count && !firsts.count) return;
  for (MBAhead *a in asked) {
    for (int n = __builtin_popcount(a.first); n > 0; n--) [firsts addObject:a];
  }
  NSMutableArray<MBAhead *> *rests = ahead_rests(asked);
  if (firsts.count) {
    dispatch_async(ahead_q, ^{
      dispatch_apply(firsts.count, DISPATCH_APPLY_AUTO, ^(size_t i) { draw_ahead(firsts[i], YES); });
    });
  }
  if (rests.count) {
    dispatch_async(ahead_rest_q, ^{
      dispatch_apply(rests.count, DISPATCH_APPLY_AUTO, ^(size_t i) { draw_ahead(rests[i], NO); });
    });
  }
}

static void ahead_ensure(void) {
  if (ahead_q) return;
  ahead_q = dispatch_queue_create(
      "mbui glyphs", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  ahead_rest_q = dispatch_queue_create(
      "mbui glyphs' phases", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  ahead_of = [NSMutableDictionary new];
  ahead_order = [NSMutableOrderedSet new];
}

// The glyphs of keys[0..n) (each with the phase to draw first: key_sub) to draw ahead at the phases of each not drawn
// or asked yet; a glyph asked again at another phase not begun has that phase drawn first too.
void mb_host_glyphs_ahead(int32_t *keys, int32_t n) {
  @autoreleasepool {
    ahead_ensure();
    ahead_batch++;
    NSMutableArray<MBAhead *> *asked = [NSMutableArray new];
    NSMutableArray<MBAhead *> *firsts = [NSMutableArray new];
    for (int32_t i = 0; i < n; i++) {
      if (keys[i] < 0) continue;
      int k = key_base(keys[i]);
      if (k >= n_entries) continue;
      uint8_t bit = (uint8_t)(1 << key_sub(keys[i]));
      MBAhead *a = ahead_of[@(k)];
      if (a) {
        pthread_mutex_lock(&ahead_lock);
        BOOL stale = a.gone || a.scale != text_scale;
        BOOL add_first = NO;
        if (stale) {
          a.gone = YES;
          a.drawn = nil;
          a.have = 0;
          a.want = 0;
          a.first = 0;
        } else if ((a.want & bit) && !(a.first & bit)) {
          a.first = (uint8_t)(a.first | bit);
          add_first = YES;
        } else if (!((a.want | a.drawing | a.have) & bit)) {
          a.want = (uint8_t)(a.want | bit);
          a.first = (uint8_t)(a.first | bit);
          add_first = YES;
        }
        pthread_mutex_unlock(&ahead_lock);
        if (stale) {
          ahead_let_go(a);
        } else {
          if (add_first) {
            entries[k].subs_queued |= bit;
            if (a.batch != ahead_batch) {
              [firsts addObject:a];
              [ahead_order removeObject:a];
              [ahead_order addObject:a];
            }
          }
          continue;
        }
      }
      uint8_t want = (uint8_t)(bit | (SUB_ALL & ~entries[k].subs_queued));
      if (!ahead_ask(k, want, (uint8_t)(want & bit), asked)) continue;
    }
    ahead_go(asked, firsts);
  }
}

// What was drawn ahead of glyph `key` at phase `sub` and the scale of now, taken; nil when it was not (asked and not
// begun: that phase no longer asked, drawn here).
static MBDrawn *drawn_ahead(int key, int sub) {
  MBAhead *a = ahead_of[@(key)];
  if (!a) return nil;
  uint8_t bit = (uint8_t)(1 << sub);
  pthread_mutex_lock(&ahead_lock);
  MBDrawn *d = nil;
  if (a.want & bit) {
    // (left out of what the queues draw, which pass over it)
    a.want = (uint8_t)(a.want & ~bit);
    a.first = (uint8_t)(a.first & ~bit);
  } else {
    while (a.drawing & bit) pthread_cond_wait(&ahead_drawn, &ahead_lock);
    if (a.have & bit) {
      id got = a.drawn[sub];
      if (got != NSNull.null && a.scale == text_scale) d = got;
      a.drawn[sub] = NSNull.null;
      a.have = (uint8_t)(a.have & ~bit);
    }
  }
  BOOL done = (a.want | a.drawing | a.have) == 0 || a.scale != text_scale;
  if (done) {
    a.gone = YES;
    a.drawn = nil;
    a.have = 0;
    a.want = 0;
    a.first = 0;
  }
  pthread_mutex_unlock(&ahead_lock);
  if (done) ahead_let_go(a);
  return d;
}

// Glyph `full_key` (its cluster's and its phase) drawn, from what was drawn ahead of it when there is, else here; the
// phases of it not drawn or asked yet asked of the queue, for where the words are moved to next.
static void rasterize(int full_key) {
  int key = key_base(full_key), sub = key_sub(full_key);
  glyph_entry *e = &entries[key];
  MBDrawn *d = drawn_ahead(key, sub);
  if (!d) {
    d = draw_cluster(texts[key], font_for(e->size, e->weight, e->style), e->style, e->dx, sub_dx(sub), text_scale);
  }
  e->subs_queued |= (uint8_t)(1 << sub);
  uint8_t rest = (uint8_t)(SUB_ALL & ~e->subs_queued);
  if (rest && !ahead_of[@(key)]) {
    ahead_ensure();
    NSMutableArray<MBAhead *> *asked = [NSMutableArray new];
    ahead_ask(key, rest, 0, asked);
    ahead_go(asked, [NSMutableArray new]);
  }
  place(full_key, d);
}

void mb_host_glyph(int32_t key, double *out) {
  @autoreleasepool {
    int base = key_base(key);
    if (base < 0 || base >= n_entries) {
      for (int i = 0; i < 7; i++) out[i] = 0;
      return;
    }
    rasterize(key);
    glyph_entry *e = &entries[base];
    out[0] = 0;
    out[1] = 0;
    out[2] = e->w;
    out[3] = e->h;
    out[4] = e->ox;
    out[5] = e->oy;
    out[6] = e->color;
  }
}

// The glyph drawn last put in its atlas, its top left at x, y: a colour glyph's MB_ATLAS_COLOR_U across past its
// place in theirs (apple.h).
void mb_host_glyph_put(int32_t key, int32_t x, int32_t y) {
  int colour = x >= MB_ATLAS_COLOR_U;
  if (key != held_key || !held.px || colour != held.color) return;
  mb_atlas_upload(colour, x - (colour ? MB_ATLAS_COLOR_U : 0), y, held.pw, held.ph, held.px);
  held = nil;
  held_key = -1;
}

// A glyph's picture given back, pixels made by MoonBit put in the atlas (words' halo, src/ui/halo.mbt): none here
// yet, so no halo is drawn (win_text.cpp's are).
int32_t mb_host_glyph_picture(int32_t key, moonbit_bytes_t out) {
  (void)key;
  (void)out;
  return 0;
}

int32_t mb_host_atlas_put(int32_t x, int32_t y, int32_t w, int32_t h, moonbit_bytes_t px) {
  (void)x;
  (void)y;
  (void)w;
  (void)h;
  (void)px;
  return 0;
}

// ---------------------------------------------------------------------------
// The platform's own drawing of a line (textref_native.mbt, for src/textdiff): Core Text's CTLineDraw into a bitmap
// context, the same fonts as above and the same rasterizer settings (no font smoothing), so what differs from
// mbui's picture is where and how mbui puts each cluster.

static CGContextRef ref_ctx;
static uint8_t *ref_px;
static double ref_h, ref_sc;

static void ref_path(NSString *name, char *out, size_t cap) {
  const char *dir = getenv("MBUI_SHOT_DIR");
  snprintf(out, cap, "%s/%s.png", dir ? dir : ".", name.UTF8String);
}

void mb_host_ref_begin(double w, double h, double scale, int32_t bg) {
  if (ref_ctx) {
    CGContextRelease(ref_ctx);
    free(ref_px);
  }
  int pw = (int)round(w * scale), ph = (int)round(h * scale);
  ref_px = calloc((size_t)pw * ph * 4, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  ref_ctx = CGBitmapContextCreate(ref_px, pw, ph, 8, (size_t)pw * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  CGContextSetRGBFillColor(ref_ctx, ((bg >> 16) & 255) / 255.0, ((bg >> 8) & 255) / 255.0, (bg & 255) / 255.0, 1);
  CGContextFillRect(ref_ctx, CGRectMake(0, 0, pw, ph));
  CGContextScaleCTM(ref_ctx, scale, scale);
  CGContextSetShouldSmoothFonts(ref_ctx, false);
  ref_h = h;
  ref_sc = scale;
}

void mb_host_ref_text(moonbit_string_t text, double size, int32_t weight, int32_t style, double x, double base,
                      int32_t color, double *out) {
  @autoreleasepool {
    for (int i = 0; i < 5; i++) out[i] = 0;
    if (!ref_ctx) return;
    CTLineRef line = make_line(mb_ns_from_string(text), font_for(size, weight, style), style);
    CGContextSetRGBFillColor(ref_ctx, ((color >> 16) & 255) / 255.0, ((color >> 8) & 255) / 255.0,
                             (color & 255) / 255.0, 1);
    CGContextSetTextMatrix(ref_ctx, CGAffineTransformIdentity);
    CGContextSetTextPosition(ref_ctx, x, ref_h - base);
    CTLineDraw(line, ref_ctx);
    out[0] = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGRect b = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    out[1] = b.origin.x;
    out[2] = -(b.origin.y + b.size.height);
    out[3] = b.origin.x + b.size.width;
    out[4] = -b.origin.y;
    CFRelease(line);
  }
}

int32_t mb_host_ref_end(moonbit_string_t name) {
  @autoreleasepool {
    if (!ref_ctx) return 0;
    char path[4096];
    ref_path(mb_ns_from_string(name), path, sizeof path);
    CGImageRef img = CGBitmapContextCreateImage(ref_ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    int ok = 0;
    if (dst) {
      CGImageDestinationAddImage(dst, img, NULL);
      ok = CGImageDestinationFinalize(dst);
      CFRelease(dst);
    }
    CFRelease(url);
    CGImageRelease(img);
    CGContextRelease(ref_ctx);
    free(ref_px);
    ref_ctx = NULL;
    ref_px = NULL;
    return ok;
  }
}

int32_t mb_host_ref_frame(moonbit_string_t name) {
  @autoreleasepool {
    char path[4096];
    ref_path(mb_ns_from_string(name), path, sizeof path);
    return mb_render_snapshot(path);
  }
}

// The word around a UTF-16 offset as the system finds words (@hostapi.word_at): CFStringTokenizer's word boundaries (a
// dictionary's words in Chinese and Japanese); start × 2^32 + end, or -1 when there is none there.
double mb_host_word_at(moonbit_string_t text, int32_t off) {
  NSString *s = mb_ns_from_string(text);
  if (off < 0 || (NSUInteger)off >= s.length) return -1;
  CFLocaleRef loc = CFLocaleCopyCurrent();
  CFStringTokenizerRef tok = CFStringTokenizerCreate(NULL, (__bridge CFStringRef)s, CFRangeMake(0, (CFIndex)s.length),
                                                     kCFStringTokenizerUnitWordBoundary, loc);
  CFRelease(loc);
  if (!tok) return -1;
  CFStringTokenizerTokenType type = CFStringTokenizerGoToTokenAtIndex(tok, off);
  double out = -1;
  if (type != kCFStringTokenizerTokenNone) {
    CFRange r = CFStringTokenizerGetCurrentTokenRange(tok);
    if (r.location != kCFNotFound && r.length > 0) out = (double)r.location * 4294967296.0 + (double)(r.location + r.length);
  }
  CFRelease(tok);
  return out;
}
