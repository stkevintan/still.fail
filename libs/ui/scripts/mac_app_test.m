// src/host/mac_app.m's sleep, wake and display-link tests: display links paused across display and system sleep (never
// unpaused while displays are off, across tell_state, requestFrame and wake_after), all links across windows and the
// titlebar spring invalidated to zero before fresh ones are bound on wake or screen reconfiguration, DarkWake keeping
// links paused while displays stay off, reverse wake ordering reporting away time once, wedged display links replaced
// and drawn without timers, stale sleep flags cleared once the display is active again, and the menu bar given again
// with only its items' enabled changed set in place, made anew for anything else:
//   cc -Wall -Werror -fobjc-arc -I src/host -I "$MOON_HOME/include" scripts/mac_app_test.m
//     -framework Cocoa -framework QuartzCore -framework Metal -framework UserNotifications -framework Security -o out/mac_app_test && out/mac_app_test
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFTimeInterval fake_media_time = 10.0;
static uint64_t fake_mono_ns = 10000000000ull;
static BOOL fake_app_active = YES;
static BOOL fake_display_active = YES;

@interface FakeDisplayLink : NSObject
@property(nonatomic, weak) id target;
@property(nonatomic) SEL selector;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL addedToRunLoop;
@property(nonatomic) CFTimeInterval timestamp;
@property(nonatomic) CFTimeInterval targetTimestamp;
@property(nonatomic) CAFrameRateRange preferredFrameRateRange;
- (void)fire;
@end

static int live_links;
static int total_links_made;
static int min_live_links_seen;
static NSMutableArray<FakeDisplayLink *> *made_links;

@implementation FakeDisplayLink
- (instancetype)init {
  if (!(self = [super init])) return nil;
  _timestamp = fake_media_time;
  _targetTimestamp = fake_media_time + (1.0 / 60.0);
  live_links++;
  total_links_made++;
  if (!made_links) made_links = [NSMutableArray array];
  [made_links addObject:self];
  return self;
}
- (void)addToRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode {
  (void)runloop, (void)mode;
  self.addedToRunLoop = YES;
}
- (void)invalidate {
  if (self.invalidated) return;
  self.invalidated = YES;
  live_links--;
  if (live_links < min_live_links_seen) min_live_links_seen = live_links;
}
- (void)fire {
  if (self.invalidated || self.paused || !self.target || !self.selector) return;
  self.timestamp = fake_media_time;
  self.targetTimestamp = fake_media_time + (1.0 / 60.0);
  ((void (*)(id, SEL, id))objc_msgSend)(self.target, self.selector, self);
}
@end

static id test_make_display_link(NSView *view, id target, SEL sel) {
  (void)view;
  FakeDisplayLink *l = [FakeDisplayLink new];
  l.target = target;
  l.selector = sel;
  return l;
}

#define MB_HOST_MEDIA_TIME() (fake_media_time)
#define MB_HOST_MONO_NS() (fake_mono_ns)
#define MB_MAKE_DISPLAY_LINK(view, target, sel) test_make_display_link((view), (target), (sel))
#define MB_APP_IS_ACTIVE() (fake_app_active)
#define MB_HOST_DISPLAY_ACTIVE(w) ((void)(w), fake_display_active)

#import "mac_app.m"

// Minimal runtime and renderer/views stubs for linking mac_app.m without MoonBit's runtime or a GPU swapchain.
moonbit_string_t moonbit_make_string_raw(int32_t size) {
  int32_t n = size > 0 ? size : 0;
  struct moonbit_object *obj = calloc(1, sizeof(struct moonbit_object) + (size_t)(n + 1) * sizeof(uint16_t));
  obj->rc = 1u << MOONBIT_RC_COUNT_SHIFT;
  obj->meta = (uint32_t)n;
  return (moonbit_string_t)(obj + 1);
}
moonbit_string_t moonbit_make_string(int32_t size, uint16_t value) {
  moonbit_string_t s = moonbit_make_string_raw(size);
  for (int32_t i = 0; i < size; i++) s[i] = value;
  return s;
}
moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  int32_t n = size > 0 ? size : 0;
  struct moonbit_object *obj = calloc(1, sizeof(struct moonbit_object) + (size_t)(n + 1));
  obj->rc = 1u << MOONBIT_RC_COUNT_SHIFT;
  obj->meta = (uint32_t)n;
  moonbit_bytes_t b = (moonbit_bytes_t)(obj + 1);
  if (n > 0) memset(b, value, (size_t)n);
  return b;
}
moonbit_string_t mb_string_from_ns(NSString *s) {
  if (!s.length) return moonbit_make_string_raw(0);
  NSUInteger len = s.length;
  moonbit_string_t out = moonbit_make_string_raw((int32_t)len);
  [s getCharacters:out range:NSMakeRange(0, len)];
  return out;
}
NSString *mb_ns_from_string(moonbit_string_t s) {
  if (!s) return @"";
  int32_t len = Moonbit_array_length(s);
  return len > 0 ? [NSString stringWithCharacters:s length:(NSUInteger)len] : @"";
}

static int active_render_wid;
static int trims_by_wid[MB_WINS];
static int presents_by_wid[MB_WINS];
static int sizes_by_wid[MB_WINS];

void mb_render_init(CAMetalLayer *layer) { (void)layer; }
void mb_render_use(int wid) {
  if (wid >= 0 && wid < MB_WINS) active_render_wid = wid;
}
void mb_render_forget(int wid) { (void)wid; }
void mb_render_set_size(double w, double h, double scale) {
  (void)w, (void)h, (void)scale;
  sizes_by_wid[active_render_wid]++;
}
void mb_render_present(const double *inst, int32_t count, double r, double g, double b) {
  (void)inst, (void)count, (void)r, (void)g, (void)b;
  presents_by_wid[active_render_wid]++;
}
void mb_render_trim(void) { trims_by_wid[active_render_wid]++; }
void mb_render_set_clear(int wid, int on) { (void)wid, (void)on; }
void mb_render_set_bands(double top, double bottom, uint32_t ground) { (void)top, (void)bottom, (void)ground; }
static int test_adaptive_settling[MB_WINS];
static int test_adaptive_steps[MB_WINS];
int mb_render_adaptive_settling_of(int wid) {
  return (wid >= 0 && wid < MB_WINS) ? test_adaptive_settling[wid] : 0;
}
int mb_render_adaptive_step(int wid) {
  if (wid < 0 || wid >= MB_WINS || !test_adaptive_settling[wid]) return 0;
  test_adaptive_steps[wid]++;
  return 1;
}
int mb_render_snapshot(const char *path) {
  (void)path;
  return 1;
}
void mb_text_set_scale(double scale) { (void)scale; }

NSView *mb_views_root(CGRect frame) { return [[NSView alloc] initWithFrame:NSRectFromCGRect(frame)]; }
NSView *mb_views_root_of(int wid, CGRect frame) {
  (void)wid;
  return [[NSView alloc] initWithFrame:NSRectFromCGRect(frame)];
}
void mb_views_use(int wid) { (void)wid; }
void mb_views_forget(int wid) { (void)wid; }
int mb_views_pass_through(double x, double y) {
  (void)x, (void)y;
  return 0;
}
const char *mb_views_touch_at(double x, double y, double *slop) {
  (void)x, (void)y, (void)slop;
  return NULL;
}
void mb_views_snap_all(void) {}
int mb_views_snapping(void) { return 0; }

// Offscreen window whose visibility, miniaturization, occlusion and key state are controlled deterministically.
@interface TestWindow : NSWindow
@property(nonatomic) BOOL testVisible;
@property(nonatomic) BOOL testMiniaturized;
@property(nonatomic) BOOL testOccluded;
@property(nonatomic) BOOL testKey;
@end

@implementation TestWindow
- (instancetype)initWithSize:(NSSize)size {
  self = [super initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:YES];
  if (self) {
    _testVisible = YES;
    _testKey = YES;
  }
  return self;
}
- (BOOL)isVisible { return self.testVisible; }
- (BOOL)isMiniaturized { return self.testMiniaturized; }
- (NSWindowOcclusionState)occlusionState {
  return self.testVisible && !self.testMiniaturized && !self.testOccluded ? NSWindowOcclusionStateVisible : 0;
}
- (BOOL)isKeyWindow { return self.testKey; }
- (CGFloat)backingScaleFactor { return 2.0; }
@end

static int failed;
#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

static int last_app_state = -1;
static int app_state_calls;
static void on_test_app_state(int32_t s) {
  last_app_state = s;
  app_state_calls++;
  // Match ui/app.mbt's app_state_taken, which calls h_request_frame() on every state transition (including s == 0).
  mb_host_request_frame();
}

static int frame_calls_by_wid[MB_WINS];
static double last_frame_late_by_wid[MB_WINS];
static int test_want_next_by_wid[MB_WINS];
static void on_test_frame(double w, double h, double scale, double t) {
  (void)w, (void)h, (void)scale, (void)t;
  frame_calls_by_wid[win_active]++;
  last_frame_late_by_wid[win_active] = mb_host_frame_late();
  double inst[24] = {0};
  mb_host_present(inst, 1, 0.1, 0.2, 0.3);
  if (test_want_next_by_wid[win_active] > 0) {
    test_want_next_by_wid[win_active]--;
    MBView *v = win_slots[@(win_active)].view;
    if (v) v.wantFrame = YES;
  }
}
static void on_noop_pointer(int32_t k, double x, double y, int32_t b) { (void)k, (void)x, (void)y, (void)b; }
static void on_noop_wheel(double x, double y, double dx, double dy, int32_t ph) {
  (void)x, (void)y, (void)dx, (void)dy, (void)ph;
}
static int key_calls;
static int32_t last_key_code;
static int32_t last_key_mods;
static void on_test_key(int32_t k, int32_t m) {
  last_key_code = k;
  last_key_mods = m;
  key_calls++;
}
static void on_noop_text(int32_t k, moonbit_string_t s, int32_t a, int32_t b) { (void)k, (void)s, (void)a, (void)b; }

// Deterministic stand-in for AppKit's interpretKeyEvents: so keyDown tests do not depend on a live WindowServer
// or the machine's current input source.
enum {
  INTERPRET_NOOP = 0,
  INTERPRET_COCOA_EDIT = 1,
  INTERPRET_INSERT_TEXT = 2,
  INTERPRET_MARK_TEXT = 3,
  INTERPRET_SILENT_IME = 4,
};

@interface TestKeyView : MBView
@property(nonatomic) int interpretMode;
@end

@implementation TestKeyView
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)eventArray {
  (void)eventArray;
  switch (self.interpretMode) {
    case INTERPRET_NOOP: [self doCommandBySelector:@selector(noop:)]; break;
    case INTERPRET_COCOA_EDIT: [self doCommandBySelector:@selector(moveToBeginningOfParagraph:)]; break;
    case INTERPRET_INSERT_TEXT: [self insertText:@"a" replacementRange:NSMakeRange(NSNotFound, 0)]; break;
    case INTERPRET_MARK_TEXT:
      [self setMarkedText:@"ni" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
      break;
    default: break;
  }
}
@end

static NSEvent *make_key_event(NSInteger winNum, NSString *chars, NSString *raw, NSEventModifierFlags mods,
                               unsigned short keyCode) {
  return [NSEvent keyEventWithType:NSEventTypeKeyDown
                          location:NSZeroPoint
                     modifierFlags:mods
                         timestamp:fake_media_time
                      windowNumber:winNum
                           context:nil
                        characters:chars
       charactersIgnoringModifiers:raw
                         isARepeat:NO
                           keyCode:keyCode];
}

// Read all posted "system" JSON messages to inspect {"shown":{"away":...}} notifications.
static NSMutableArray<NSDictionary *> *take_system_messages(void) {
  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  int32_t n = mb_host_post_take();
  for (int32_t i = 0; i < n; i++) {
    NSString *ch = mb_ns_from_string(mb_host_post_next());
    if ([ch isEqualToString:@"system"]) {
      NSData *d = [mb_ns_from_string(mb_host_post_json()) dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
      if ([json isKindOfClass:NSDictionary.class]) [out addObject:json];
    }
  }
  return out;
}

static MBWinSlot *attach_test_window(int wid, TestWindow *w) {
  NSRect r = NSMakeRect(0, 0, 800, 600);
  NSView *box = [[NSView alloc] initWithFrame:r];
  box.wantsLayer = YES;
  win_making = wid;
  MBView *v = [[MBView alloc] initWithFrame:r];
  win_making = 0;
  [box addSubview:v];
  w.contentView = box;
  MBWinSlot *slot = [MBWinSlot new];
  slot.wid = wid;
  slot.win = w;
  slot.box = box;
  slot.view = v;
  slot.a11yNodes = [NSMutableDictionary new];
  slot.a11yElements = [NSMutableDictionary new];
  slot.zoom = 1.0;
  win_slots[@(wid)] = slot;
  return slot;
}

// The menu bar as an app gives it (mb_host_menu_setup): a chat's items enabled or not, its keys, a tray of its own
static NSArray *test_menus(BOOL in_chat, NSString *find_keys, NSString *go_title, BOOL extra, BOOL tray, BOOL tray_on) {
  NSMutableArray *go = [@[
    @{@"title" : @"Previous", @"action" : @"chat.prev", @"keys" : @"Mod+Alt+Up", @"enabled" : @YES},
    @{@"separator" : @YES},
    @{@"title" : @"Latest", @"action" : @"chat.latest", @"enabled" : @(in_chat)},
    @{@"title" : @"Find", @"action" : @"chat.find", @"keys" : find_keys, @"enabled" : @(in_chat)},
  ] mutableCopy];
  if (extra) [go addObject:@{@"title" : @"More", @"action" : @"chat.more", @"enabled" : @YES}];
  NSMutableArray *menus = [@[
    @{@"title" : @"App", @"role" : @"app", @"items" : @[
      @{@"title" : @"About {app}", @"role" : @"about"}, @{@"separator" : @YES},
      @{@"title" : @"Services", @"role" : @"services"}, @{@"separator" : @YES},
      @{@"title" : @"Quit", @"role" : @"quit", @"enabled" : @(in_chat)},
    ]},
    @{@"title" : go_title, @"role" : @"actions", @"items" : go},
    @{@"title" : @"Chat", @"role" : @"actions", @"items" : @[
      @{@"title" : @"Stop", @"action" : @"chat.stop", @"enabled" : @(in_chat)},
    ]},
    @{@"title" : @"Window", @"role" : @"window", @"items" : @[
      @{@"title" : @"Minimize", @"role" : @"minimize"}, @{@"separator" : @YES},
      @{@"title" : @"Front", @"role" : @"front"},
    ]},
  ] mutableCopy];
  [menus addObject:@{@"role" : @"tray", @"macos" : @(tray), @"title" : @"T", @"items" : @[
    @{@"title" : @"Open", @"role" : @"show"}, @{@"separator" : @YES},
    @{@"title" : @"New chat", @"action" : @"chat.new", @"enabled" : @(tray_on)},
  ]}];
  return menus;
}
static void test_menu_setup(NSArray *menus) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:menus options:0 error:NULL];
  mb_host_menu_setup(mb_string_from_ns([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]));
}
static NSMenuItem *test_menu_item(NSMenu *bar, NSInteger menu, NSInteger item) {
  return [[bar itemAtIndex:menu].submenu itemAtIndex:item];
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    app_cb = (mb_callbacks){on_test_frame, on_noop_pointer, on_noop_wheel, on_test_key, on_noop_text};
    mb_cb = (mb_callbacks){on_test_frame, win_pointer, win_wheel, win_key, win_text};
    mb_host_set_app_state(on_test_app_state);

    win_slots = [NSMutableDictionary new];
    TestWindow *w0 = [[TestWindow alloc] initWithSize:NSMakeSize(800, 600)];
    TestWindow *w1 = [[TestWindow alloc] initWithSize:NSMakeSize(640, 480)];
    MBWinSlot *s0 = attach_test_window(0, w0);
    the_box = s0.box;
    the_view = s0.view;
    MBWinSlot *s1 = attach_test_window(1, w1);

    watch_sleep();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeScreenNotification
                                                      object:w0
                                                       queue:nil
                                                  usingBlock:^(NSNotification *n) {
                                                    (void)n;
                                                    screen_changed(w0);
                                                  }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *n) {
                                                    (void)n;
                                                    screen_changed(nil);
                                                  }];

    tell_state();
    CHECK(last_app_state == 3);
    CHECK(window_seen == 1);
    FakeDisplayLink *l0 = (FakeDisplayLink *)s0.view.link;
    FakeDisplayLink *l1 = (FakeDisplayLink *)s1.view.link;
    CHECK(l0 != nil && !l0.paused && l0.addedToRunLoop);
    CHECK(l1 != nil && !l1.paused && l1.addedToRunLoop);

    // Initial tick draws both windows cleanly and pauses idle links.
    [l0 fire];
    [l1 fire];
    CHECK(frame_calls_by_wid[0] == 1 && presents_by_wid[0] == 1);
    CHECK(frame_calls_by_wid[1] == 1 && presents_by_wid[1] == 1);
    CHECK(l0.paused && l1.paused);

    // 1. Display sleep finishes the buttons' spring, trims every window, reports state 0, and keeps all links paused across
    //    state_cb's own requestFrame, extra requestFrame calls, and wake_after expirations.
    setup_inset = 1;
    window_shown = YES;
    mb_host_window_buttons_down(12.0, 200.0);
    FakeDisplayLink *btnLink = (FakeDisplayLink *)s0.buttonsLink;
    CHECK(btnLink != nil && !btnLink.invalidated);
    CHECK(live_links == 3);

    NSNotificationCenter *ws = NSWorkspace.sharedWorkspace.notificationCenter;
    fake_display_active = NO;
    [ws postNotificationName:NSWorkspaceScreensDidSleepNotification object:NSWorkspace.sharedWorkspace];
    CHECK(screens_asleep == 1);
    CHECK(window_seen == 0);
    CHECK(last_app_state == 0);
    CHECK(btnLink.invalidated && s0.buttonsLink == nil && s0.buttonsDown == 12.0);
    CHECK(trims_by_wid[0] == 1 && trims_by_wid[1] == 1);
    // Even though on_test_app_state(0) called mb_host_request_frame(), neither link may unpause while displays are off.
    CHECK(s0.view.wantFrame && s1.view.wantFrame);
    CHECK(l0.paused && l1.paused);
    CHECK(s0.view.linkAskedAt == 0 && s1.view.linkAskedAt == 0);

    // Additional frame requests and due wake_after callbacks during display sleep keep links paused too.
    mb_host_request_frame();
    CHECK(l0.paused && l1.paused);
    mb_host_wake_after(50.0);
    CHECK(wake_for > 0);
    wake_after_due(wake_for);
    CHECK(wake_for < 0);
    CHECK(l0.paused && l1.paused);

    // Window 0 drops any accidental present while unseen; the buttons snap immediately without creating a link.
    double dummy[24] = {0};
    mb_host_present(dummy, 1, 0, 0, 0);
    CHECK(presents_by_wid[0] == 1);
    mb_host_window_buttons_down(6.0, 200.0);
    CHECK(s0.buttonsLink == nil && s0.buttonsDown == 6.0);

    // 2. Display wake invalidates ALL old links (live_links drops to 0) before creating fresh links, restores state 3,
    //    and renders frames on the new links.
    min_live_links_seen = live_links;
    fake_display_active = YES;
    fake_media_time += 5.0;
    [ws postNotificationName:NSWorkspaceScreensDidWakeNotification object:NSWorkspace.sharedWorkspace];
    CHECK(screens_asleep == 0);
    CHECK(window_seen == 1);
    CHECK(last_app_state == 3);
    CHECK(min_live_links_seen == 0);
    CHECK(l0.invalidated && l1.invalidated);
    FakeDisplayLink *woke0 = (FakeDisplayLink *)s0.view.link;
    FakeDisplayLink *woke1 = (FakeDisplayLink *)s1.view.link;
    CHECK(woke0 != nil && woke0 != l0 && !woke0.invalidated && !woke0.paused);
    CHECK(woke1 != nil && woke1 != l1 && !woke1.invalidated && !woke1.paused);
    [woke0 fire];
    [woke1 fire];
    CHECK(presents_by_wid[0] == 2 && presents_by_wid[1] == 2);
    CHECK(woke0.paused && woke1.paused);
    [take_system_messages() removeAllObjects];

    // 3. System sleep + DarkWake (DidWake while display remains inactive) reports sleep duration once, keeps
    //    screens_asleep == 1 and links paused until ScreensDidWake arrives.
    fake_display_active = NO;
    fake_mono_ns = 20000000000ull;
    [ws postNotificationName:NSWorkspaceWillSleepNotification object:NSWorkspace.sharedWorkspace];
    [ws postNotificationName:NSWorkspaceScreensDidSleepNotification object:NSWorkspace.sharedWorkspace];
    CHECK(asleep_at == 20000000000ull && screens_asleep == 1);
    CHECK(woke0.paused && woke1.paused);

    // DarkWake 15s later: display is still powered off.
    fake_mono_ns = 35000000000ull;
    [ws postNotificationName:NSWorkspaceDidWakeNotification object:NSWorkspace.sharedWorkspace];
    CHECK(asleep_at == 0 && screens_asleep == 1 && window_seen == 0);
    NSMutableArray<NSDictionary *> *msgs = take_system_messages();
    CHECK(msgs.count == 1 && fabs([msgs[0][@"shown"][@"away"] doubleValue] - 15000.0) < 0.01);
    FakeDisplayLink *dark0 = (FakeDisplayLink *)s0.view.link;
    FakeDisplayLink *dark1 = (FakeDisplayLink *)s1.view.link;
    CHECK(dark0.paused && dark1.paused);

    // User later wakes the screens: links rebind and unpause, and no second away message is emitted.
    fake_display_active = YES;
    fake_mono_ns = 40000000000ull;
    [ws postNotificationName:NSWorkspaceScreensDidWakeNotification object:NSWorkspace.sharedWorkspace];
    CHECK(screens_asleep == 0 && window_seen == 1 && last_app_state == 3);
    CHECK(take_system_messages().count == 0);
    FakeDisplayLink *afterDark0 = (FakeDisplayLink *)s0.view.link;
    FakeDisplayLink *afterDark1 = (FakeDisplayLink *)s1.view.link;
    CHECK(!afterDark0.paused && !afterDark1.paused);
    [afterDark0 fire];
    [afterDark1 fire];
    CHECK(presents_by_wid[0] == 3 && presents_by_wid[1] == 3);

    // 4. Reverse wake order (ScreensDidWake arriving 20ms before DidWake) emits shown.away once, not twice.
    fake_display_active = NO;
    fake_mono_ns = 50000000000ull;
    [ws postNotificationName:NSWorkspaceWillSleepNotification object:NSWorkspace.sharedWorkspace];
    [ws postNotificationName:NSWorkspaceScreensDidSleepNotification object:NSWorkspace.sharedWorkspace];
    fake_display_active = YES;
    fake_mono_ns = 80000000000ull;
    [ws postNotificationName:NSWorkspaceScreensDidWakeNotification object:NSWorkspace.sharedWorkspace];
    fake_mono_ns = 80020000000ull;
    [ws postNotificationName:NSWorkspaceDidWakeNotification object:NSWorkspace.sharedWorkspace];
    msgs = take_system_messages();
    CHECK(msgs.count == 1 && fabs([msgs[0][@"shown"][@"away"] doubleValue] - 30000.0) < 0.01);
    [(FakeDisplayLink *)s0.view.link fire];
    [(FakeDisplayLink *)s1.view.link fire];

    // 5. External monitor hotplug (NSApplicationDidChangeScreenParametersNotification / NSWindowDidChangeScreenNotification)
    //    drops live_links to 0 and rebinds fresh links even when displayID stays the same.
    FakeDisplayLink *prePlug0 = (FakeDisplayLink *)s0.view.link;
    FakeDisplayLink *prePlug1 = (FakeDisplayLink *)s1.view.link;
    min_live_links_seen = live_links;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidChangeScreenParametersNotification
                                                        object:NSApp];
    CHECK(min_live_links_seen == 0);
    CHECK(prePlug0.invalidated && prePlug1.invalidated);
    FakeDisplayLink *postPlug0 = (FakeDisplayLink *)s0.view.link;
    FakeDisplayLink *postPlug1 = (FakeDisplayLink *)s1.view.link;
    CHECK(postPlug0 != prePlug0 && !postPlug0.paused);
    CHECK(postPlug1 != prePlug1 && !postPlug1.paused);
    [postPlug0 fire];
    [postPlug1 fire];
    int presents0BeforeMove = presents_by_wid[0];

    min_live_links_seen = live_links;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidChangeScreenNotification object:w0];
    CHECK(min_live_links_seen == 0);
    CHECK(postPlug0.invalidated);
    FakeDisplayLink *moved0 = (FakeDisplayLink *)s0.view.link;
    CHECK(moved0 != postPlug0 && !moved0.paused);
    [moved0 fire];
    CHECK(presents_by_wid[0] == presents0BeforeMove + 1);
    [(FakeDisplayLink *)s1.view.link fire];

    // 6. Wedged CADisplayLink recovery without timers: if an unpaused link fails to tick for >250ms, the next
    //    requestFrame replaces all links and draws the waiting frame immediately.
    fake_media_time = 100.0;
    [s0.view requestFrame];
    FakeDisplayLink *wedged = (FakeDisplayLink *)s0.view.link;
    CHECK(!wedged.paused && s0.view.linkAskedAt == 100.0);
    int presentsBeforeFallback = presents_by_wid[0];
    // Never call [wedged fire]; advance past 250ms and ask for a frame again.
    fake_media_time = 100.30;
    [s0.view requestFrame];
    CHECK(wedged.invalidated);
    CHECK((FakeDisplayLink *)s0.view.link != wedged);
    CHECK(presents_by_wid[0] == presentsBeforeFallback + 1);
    CHECK(!s0.view.wantFrame && s0.view.linkAskedAt == 0);

    // Same self-healing when driven by wake_after_due instead of direct requestFrame.
    fake_media_time = 200.0;
    mb_host_wake_after(16.0);
    wake_after_due(wake_for);
    FakeDisplayLink *wedgedWake = (FakeDisplayLink *)s0.view.link;
    CHECK(!wedgedWake.paused && s0.view.linkAskedAt == 200.0);
    fake_media_time = 200.30;
    wake_for = -1;
    mb_host_wake_after(16.0);
    wake_after_due(wake_for);
    CHECK(wedgedWake.invalidated);
    CHECK(presents_by_wid[0] == presentsBeforeFallback + 2);

    // 7. Stale sleep flags (aborted sleep / missed wake notification) clear automatically on user input when the
    //    window's display is active.
    asleep_at = 90000000000ull;
    screens_asleep = 1;
    pause_all_links();
    tell_state();
    CHECK(window_seen == 0 && last_app_state == 0);
    fake_display_active = YES;
    fake_mono_ns = 95000000000ull;
    NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                   location:NSZeroPoint
                              modifierFlags:0
                                  timestamp:fake_media_time
                               windowNumber:w0.windowNumber
                                    context:nil
                                 characters:@"a"
                charactersIgnoringModifiers:@"a"
                                  isARepeat:NO
                                    keyCode:0];
    [s0.view keyDown:ev];
    CHECK(key_calls == 1);
    CHECK(asleep_at == 0 && screens_asleep == 0);
    CHECK(window_seen == 1 && last_app_state == 3);
    msgs = take_system_messages();
    CHECK(msgs.count == 1 && fabs([msgs[0][@"shown"][@"away"] doubleValue] - 5000.0) < 0.01);
    int presentsBeforeKey = presents_by_wid[0];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(presents_by_wid[0] == presentsBeforeKey + 1);

    // 8. Lock-screen occlusion on wake followed by unlock (shown: 0 -> 1) rebinds fresh links at unlock too.
    //    (the lock screen covers every window: the app is seen while any of them is)
    w0.testOccluded = YES;
    w1.testOccluded = YES;
    tell_state();
    CHECK(window_seen == 0 && last_app_state == 0);
    FakeDisplayLink *whileLocked0 = (FakeDisplayLink *)s0.view.link;
    min_live_links_seen = live_links;
    w0.testOccluded = NO;
    w1.testOccluded = NO;
    tell_state();
    CHECK(min_live_links_seen == 0 && whileLocked0.invalidated);
    CHECK(window_seen == 1 && last_app_state == 3);
    FakeDisplayLink *unlocked0 = (FakeDisplayLink *)s0.view.link;
    CHECK(unlocked0 != whileLocked0 && !unlocked0.paused);
    [unlocked0 fire];
    CHECK(presents_by_wid[0] == presentsBeforeKey + 2);

    // 9. Control shortcuts (such as Control+1/2/3) reach mb_cb.key while a text field has focus,
    //    without breaking Cocoa Control editing bindings or active IME composition.
    TestKeyView *kv = [[TestKeyView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    [s0.box addSubview:kv];
    kv.imeActive = YES;
    kv.markedLen = 0;

    // 9a. Unhandled Control+1/2/3 (including non-ASCII or punctuation digit-row layouts), Control+letter, and Control+arrow
    //     fall through to mb_cb.key.
    kv.interpretMode = INTERPRET_NOOP;
    int callsBefore = key_calls;
    [kv keyDown:make_key_event(w0.windowNumber, @"1", @"1", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore + 1 && last_key_code == 1000 + '1' && last_key_mods == 2);
    [kv keyDown:make_key_event(w0.windowNumber, @"2", @"2", NSEventModifierFlagControl, 19)];
    CHECK(key_calls == callsBefore + 2 && last_key_code == 1000 + '2' && last_key_mods == 2);
    [kv keyDown:make_key_event(w0.windowNumber, @"3", @"3", NSEventModifierFlagControl, 20)];
    CHECK(key_calls == callsBefore + 3 && last_key_code == 1000 + '3' && last_key_mods == 2);
    [kv keyDown:make_key_event(w0.windowNumber, @"&", @"&", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore + 4 && last_key_code == 1000 + '1' && last_key_mods == 2);
    [kv keyDown:make_key_event(w0.windowNumber, @"\u3105", @"\u3105", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore + 5 && last_key_code == 1000 + '1' && last_key_mods == 2);
    [kv keyDown:make_key_event(w0.windowNumber, @"\x07", @"g", NSEventModifierFlagControl, 5)];
    CHECK(key_calls == callsBefore + 6 && last_key_code == 1000 + 'g' && last_key_mods == 2);
    [kv keyDown:make_key_event(w0.windowNumber, @"", @"", NSEventModifierFlagControl, 125)];
    CHECK(key_calls == callsBefore + 7 && last_key_code == 6 && last_key_mods == 2);

    // 9b. Cocoa Control editing bindings (such as Control+A) send only their text command, never a duplicate shortcut.
    kv.interpretMode = INTERPRET_COCOA_EDIT;
    callsBefore = key_calls;
    [kv keyDown:make_key_event(w0.windowNumber, @"\x01", @"a", NSEventModifierFlagControl, 0)];
    CHECK(key_calls == callsBefore + 1 && last_key_code == 24 && last_key_mods == 0);

    // 9c. Keys that insert text or start IME composition do not trigger the Control shortcut fallback.
    kv.interpretMode = INTERPRET_INSERT_TEXT;
    callsBefore = key_calls;
    [kv keyDown:make_key_event(w0.windowNumber, @"1", @"1", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore);
    kv.interpretMode = INTERPRET_MARK_TEXT;
    [kv keyDown:make_key_event(w0.windowNumber, @"1", @"1", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore && kv.markedLen == 2);

    // 9d. Active IME composition keeps Control keys even when the IME swallows them silently.
    kv.interpretMode = INTERPRET_SILENT_IME;
    [kv keyDown:make_key_event(w0.windowNumber, @"1", @"1", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore);
    kv.interpretMode = INTERPRET_NOOP;
    [kv keyDown:make_key_event(w0.windowNumber, @"1", @"1", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore);
    kv.markedLen = 0;

    // 9e. Control+Return, Control+Backspace, and plain keys without Control do not fire the fallback.
    [kv keyDown:make_key_event(w0.windowNumber, @"\r", @"\r", NSEventModifierFlagControl, 36)];
    [kv keyDown:make_key_event(w0.windowNumber, @"\x7f", @"\x7f", NSEventModifierFlagControl, 51)];
    [kv keyDown:make_key_event(w0.windowNumber, @"1", @"1", 0, 18)];
    CHECK(key_calls == callsBefore);

    // 9f. Without a focused text field, Control+1 on a punctuation digit-row layout still sends '1'.
    kv.imeActive = NO;
    [kv keyDown:make_key_event(w0.windowNumber, @"&", @"&", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore + 1 && last_key_code == 1000 + '1' && last_key_mods == 2);

    // 9g. Real MBView (not subclassed) also forwards Control+1/2/3 when imeActive is YES.
    s0.view.imeActive = YES;
    s0.view.markedLen = 0;
    callsBefore = key_calls;
    [s0.view keyDown:make_key_event(w0.windowNumber, @"1", @"1", NSEventModifierFlagControl, 18)];
    CHECK(key_calls == callsBefore + 1 && last_key_code == 1000 + '1' && last_key_mods == 2);
    [s0.view keyDown:make_key_event(w0.windowNumber, @"2", @"2", NSEventModifierFlagControl, 19)];
    CHECK(key_calls == callsBefore + 2 && last_key_code == 1000 + '2' && last_key_mods == 2);
    [s0.view keyDown:make_key_event(w0.windowNumber, @"3", @"3", NSEventModifierFlagControl, 20)];
    CHECK(key_calls == callsBefore + 3 && last_key_code == 1000 + '3' && last_key_mods == 2);
    s0.view.imeActive = NO;

    // 11. frame_late continuity across adaptive glass settle, wake_for waits, dual windows, sync resize, and real lag.
    // 11a. 100 ms adaptive_settling gap followed by a new app frame reports frame_late == 0.
    fake_media_time = 300.0;
    test_adaptive_settling[0] = 1;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);
    // Link stays unpaused for adaptive settle; tick 6 times (~100 ms) without app frames.
    CHECK(!((FakeDisplayLink *)s0.view.link).paused);
    for (int i = 0; i < 6; i++) {
      fake_media_time += 1.0 / 60.0;
      [(FakeDisplayLink *)s0.view.link fire];
    }
    CHECK(test_adaptive_steps[0] >= 6);
    test_adaptive_settling[0] = 0;
    fake_media_time += 1.0 / 60.0;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);

    // 11b. wake_for timer wait followed by first frame reports frame_late == 0 and increments frame_calls_by_wid[0] by 1.
    fake_media_time = 310.0;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    int callsBeforeWake = frame_calls_by_wid[0];
    wake_for = (fake_media_time + 0.100) * 1000.0;
    ((FakeDisplayLink *)s0.view.link).paused = NO;
    fake_media_time += 0.050;
    [(FakeDisplayLink *)s0.view.link fire];  // before wake_for: returns early
    CHECK(frame_calls_by_wid[0] == callsBeforeWake);
    fake_media_time += 0.060;
    [(FakeDisplayLink *)s0.view.link fire];  // at/past wake_for: draws frame
    CHECK(frame_calls_by_wid[0] == callsBeforeWake + 1 && last_frame_late_by_wid[0] == 0.0);

    // 11c. Dual-window interleaving: window B idle/settling does not clear window A's real late frame, and window A's
    //      timestamp does not leak into window B.
    fake_media_time = 320.0;
    test_want_next_by_wid[0] = 1;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);
    // Window B draws an idle frame and runs an adaptive settle step while window A is mid-animation.
    fake_media_time += 0.010;
    test_adaptive_settling[1] = 1;
    [s1.view requestFrame];
    [(FakeDisplayLink *)s1.view.link fire];
    CHECK(last_frame_late_by_wid[1] == 0.0);
    fake_media_time += 0.010;
    [(FakeDisplayLink *)s1.view.link fire];  // settle step on window B
    test_adaptive_settling[1] = 0;
    // Window A now fires 33.33 ms after its previous frame (1 beat late over 16.67 ms period).
    fake_media_time = 320.0 + (2.0 / 60.0);
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] > 15.0 && last_frame_late_by_wid[0] < 18.0);
    // Window B draws a fresh frame right after: must NOT inherit window A's lastTick.
    fake_media_time += 0.050;
    [s1.view requestFrame];
    [(FakeDisplayLink *)s1.view.link fire];
    CHECK(last_frame_late_by_wid[1] == 0.0);

    // 11d. Synchronous resize (drawWithWindow) clears prior non-zero frame_late and starts next tick clean.
    fake_media_time = 330.0;
    test_want_next_by_wid[0] = 2;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    fake_media_time += (2.0 / 60.0);
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] > 15.0 && last_frame_late_by_wid[0] < 18.0);
    fake_media_time += 0.080;
    [s0.view drawWithWindow];
    CHECK(last_frame_late_by_wid[0] == 0.0);
    // Following tick after drawWithWindow also starts clean.
    fake_media_time += 0.050;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);

    // 11e. Two consecutive continuous frames exceeding budget by 1 beat report frame_late > 0.
    fake_media_time = 340.0;
    test_want_next_by_wid[0] = 1;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);
    fake_media_time += (2.0 / 60.0);
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] > 15.0 && last_frame_late_by_wid[0] < 18.0);

    // 11f. viewDidMoveToWindow detach + 100ms + reattach resets s0.view.lastTick without affecting s1.view.lastTick.
    fake_media_time = 350.0;
    test_want_next_by_wid[0] = 1;
    test_want_next_by_wid[1] = 1;
    [s0.view requestFrame];
    [s1.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    [(FakeDisplayLink *)s1.view.link fire];
    double s1TickBefore = s1.view.lastTick;
    CHECK(s0.view.lastTick > 0.0 && s1TickBefore > 0.0);
    [s0.view removeFromSuperview];
    CHECK(s0.view.lastTick == -1.0 && s1.view.lastTick == s1TickBefore);
    fake_media_time += 0.100;
    [s0.box addSubview:s0.view];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);
    test_want_next_by_wid[0] = 0;
    test_want_next_by_wid[1] = 0;

    // 11g. Frame ends with wantFrame=NO while adaptive_settling=1; external input re-arms wantFrame before next tick:
    //      next tick must report frame_late == 0 (chain was broken immediately at frame end).
    fake_media_time = 360.0;
    test_adaptive_settling[0] = 1;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(s0.view.lastTick == -1.0 && !((FakeDisplayLink *)s0.view.link).paused);
    fake_media_time += 0.100;
    [s0.view requestFrame];
    [(FakeDisplayLink *)s0.view.link fire];
    CHECK(last_frame_late_by_wid[0] == 0.0);
    test_adaptive_settling[0] = 0;
  }
  // 10. The menu bar given again with only its items' enabled changed (a chat opened or closed) keeps every menu and
  //     item and sets only the app's items; anything else changed (keys, words, items, the tray) makes it anew.
  @autoreleasepool {
    test_menu_setup(test_menus(NO, @"Mod+F", @"Go", NO, NO, NO));
    NSMenu *bar = NSApp.mainMenu;
    CHECK(bar != nil && bar.numberOfItems == 4);
    NSMenu *go = [bar itemAtIndex:1].submenu, *window = [bar itemAtIndex:3].submenu;
    NSMenuItem *latest = test_menu_item(bar, 1, 2), *find = test_menu_item(bar, 1, 3), *quit = test_menu_item(bar, 0, 4);
    NSMenuItem *stop = test_menu_item(bar, 2, 0);
    NSMenu *services = NSApp.servicesMenu;
    CHECK(!latest.enabled && !find.enabled && !stop.enabled && quit.enabled && test_menu_item(bar, 1, 0).enabled);
    CHECK(NSApp.windowsMenu == window && !go.autoenablesItems && [go isKindOfClass:MBShownKeysMenu.class]);
    CHECK([find.keyEquivalent isEqualToString:@"f"] && find.keyEquivalentModifierMask == NSEventModifierFlagCommand);
    CHECK(tray_item == nil);

    // (the system's list of windows after the window menu's own items)
    [window addItem:[[NSMenuItem alloc] initWithTitle:@"A window" action:@selector(makeKeyAndOrderFront:)
                                        keyEquivalent:@""]];
    test_menu_setup(test_menus(YES, @"Mod+F", @"Go", NO, NO, NO));
    CHECK(NSApp.mainMenu == bar && [bar itemAtIndex:1].submenu == go && test_menu_item(bar, 1, 2) == latest);
    CHECK(test_menu_item(bar, 1, 3) == find && test_menu_item(bar, 2, 0) == stop && NSApp.windowsMenu == window);
    CHECK(latest.enabled && find.enabled && stop.enabled && quit.enabled && NSApp.servicesMenu == services);
    CHECK(window.numberOfItems == 4);
    test_menu_setup(test_menus(NO, @"Mod+F", @"Go", NO, NO, NO));
    CHECK(NSApp.mainMenu == bar && !latest.enabled && !find.enabled && !stop.enabled && quit.enabled);

    // keys changed: made anew, with them
    test_menu_setup(test_menus(YES, @"Mod+Shift+F", @"Go", NO, NO, NO));
    NSMenu *bar2 = NSApp.mainMenu;
    CHECK(bar2 != bar && test_menu_item(bar2, 1, 3).enabled);
    CHECK(test_menu_item(bar2, 1, 3).keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagShift));
    // words changed (another language), an item more: made anew
    test_menu_setup(test_menus(YES, @"Mod+Shift+F", @"前往", NO, NO, NO));
    NSMenu *bar3 = NSApp.mainMenu;
    CHECK(bar3 != bar2 && [[bar3 itemAtIndex:1].title isEqualToString:@"前往"]);
    test_menu_setup(test_menus(YES, @"Mod+Shift+F", @"前往", YES, NO, NO));
    NSMenu *bar4 = NSApp.mainMenu;
    CHECK(bar4 != bar3 && [bar4 itemAtIndex:1].submenu.numberOfItems == 5);
    // the bar put in place by someone else: made anew
    NSApp.mainMenu = [NSMenu new];
    test_menu_setup(test_menus(NO, @"Mod+Shift+F", @"前往", YES, NO, NO));
    CHECK(NSApp.mainMenu != bar4 && NSApp.mainMenu.numberOfItems == 4 && !test_menu_item(NSApp.mainMenu, 1, 2).enabled);

    // a tray of its own: its items set again in place too; it going makes the bar anew and takes the tray away
    test_menu_setup(test_menus(NO, @"Mod+F", @"Go", NO, YES, NO));
    NSMenu *bar5 = NSApp.mainMenu, *tmenu = tray_item.menu;
    CHECK(tray_item != nil && tmenu.numberOfItems == 3 && ![tmenu itemAtIndex:2].enabled);
    test_menu_setup(test_menus(YES, @"Mod+F", @"Go", NO, YES, YES));
    CHECK(NSApp.mainMenu == bar5 && tray_item.menu == tmenu && [tmenu itemAtIndex:2].enabled);
    CHECK(test_menu_item(bar5, 1, 2).enabled);
    test_menu_setup(test_menus(YES, @"Mod+F", @"Go", NO, NO, YES));
    CHECK(NSApp.mainMenu != bar5 && tray_item == nil);
  }
  if (!failed) printf("mac_app_test: ok\n");
  return failed;
}
