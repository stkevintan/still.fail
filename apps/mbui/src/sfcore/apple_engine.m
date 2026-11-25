// The core's engine on Apple's systems, for an app's native stub to #include (moon.pkg cannot pick stubs per OS, and
// cc-link-flags go only on a main package, so the app links it: src/coredemo/core_engine.m, src/stillfail/core_engine.m;
// moon does not track this file: touch the app's stub after changing it). Hermes on the Rust shell (src/host/apple_core.mm,
// built by scripts/core.sh engine into out/core/<target>/libmbui_core.a, which the app links with
// out/core/<target>/libstillfail_shell.a and Hermes's framework) and, on iOS, the browser session that brings a sign-in
// back (src/host/apple_auth.m), handed to mbui/core as the app loads. On macOS none (web_auth NULL): the app signs in on
// @hostapi.browser_login (a loopback listener and the default browser, as the desktop app's), not in
// ASWebAuthenticationSession's, which is Safari's whatever the browser chosen.
#include "../host/apple_auth.m"
#include "../core/core_client.h"
#include "../host/apple.h"
#if TARGET_OS_IPHONE
#include "apple_product.h"
#endif

// $MBUI_CORE_DATA, else ~/Library/Application Support/<bundle id, or mbui>/core: the app's own, never the installed
// still.fail app's. Built as still.fail's desktop app itself (scripts/mac-app.sh's stable and beta: Electron's ids,
// fail.still.desktop and .beta), that app's data where it kept it (its userData, named as the app: still.fail,
// youdid.wtf; core/ there, as its core's: apps/desktop/src/main.ts): signed in, its prefs and its chats as they were,
// its sealed keys taken as they are first asked for (src/host/apple_core.mm electron_sealed).
static const char *core_data_dir(void) {
  static char *dir;
  if (dir) return dir;
  const char *env = getenv("MBUI_CORE_DATA");
  NSString *path = env && *env ? @(env) : nil;
  if (!path) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *app = NSBundle.mainBundle.bundleIdentifier ?: @"mbui";
    NSString *electron = @{@"fail.still.desktop" : @"still.fail", @"fail.still.desktop.beta" : @"youdid.wtf"}[app];
    path = [[support.path stringByAppendingPathComponent:electron ?: app] stringByAppendingPathComponent:@"core"];
  }
  [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
  dir = strdup(path.fileSystemRepresentation);
  return dir;
}

#if TARGET_OS_IPHONE
static const mbc_engine hermes_engine = {mb_core_start, mb_core_send, mb_core_stop, core_data_dir, mb_web_auth, mb_post, mb_post_drop, mb_core_screen_ack, NULL, mb_core_screen_input};
#else
static const mbc_engine hermes_engine = {mb_core_start, mb_core_send, mb_core_stop, core_data_dir, NULL, mb_post, mb_post_drop, mb_core_screen_ack, NULL, mb_core_screen_input};
#endif

#ifdef STILLFAIL_CORE_PION
extern void mb_core_attach_pion_runtime(void);
#endif

__attribute__((constructor)) static void use_hermes_engine(void) {
#ifdef STILLFAIL_CORE_PION
  mb_core_attach_pion_runtime();
#endif
#if TARGET_OS_IPHONE
  sf_product_environment(NSBundle.mainBundle.infoDictionary[@"MBUIEnvironment"]);
#endif
  mbc_use(&hermes_engine);
  // a remote screen's frames and sound the shell reads itself go to the stream the app routed them to, past its queue
  // (mbui's apple_stream.m), acknowledged to the station through the shell
  mb_core_route_media(mb_stream_route_take);
  mb_stream_route_acks(mb_core_screen_ack);
  mb_stream_route_acks_wait(mb_core_screen_ack_wait);
}

#if TARGET_OS_IPHONE && !defined(STILLFAIL_CORE_PION)
#include <fcntl.h>
#include <time.h>
#include <unistd.h>

int mb_core_start_alone(const char *data_dir, const char *cloud_origin, int beta);
void mb_core_stop_alone(void);
void mb_core_ask(const char *call, const char *params, void (^done)(int));
void mb_perf_note(const char *text);

// How long a push's work may take: iOS gives a woken app about 30 s, and suspends or ends one that has not said it is done.
static const int64_t PUSH_BRING_NS = 25 * NSEC_PER_SEC;
// Pushes being brought (main thread): the core started for them goes once the last is done.
static int pushes_bringing;

// Whether the core's files can be read: not before the device's first unlock, when a core started would find its
// database and Keychain closed and take them for empty. An empty directory has no account to bring anything for.
static BOOL core_files_open(const char *dir) {
  NSString *root = @(dir);
  NSDirectoryEnumerator<NSString *> *files = [NSFileManager.defaultManager enumeratorAtPath:root];
  for (NSString *name in files) {
    if (![files.fileAttributes.fileType isEqualToString:NSFileTypeRegular] || files.fileAttributes.fileSize == 0) continue;
    int fd = open([root stringByAppendingPathComponent:name].fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    char byte;
    ssize_t got = read(fd, &byte, 1);
    close(fd);
    return got == 1;
  }
  return NO;
}

static NSString *json_of(NSDictionary *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

// What a push is about, onto the device (`notice.bring`, as Android's Push.java): the core told how long the app was
// away first, since its connections likely went while it was frozen. Replaces ios_app.m's weak one.
void mb_core_pushed(NSString *workspace, NSString *station, NSString *session, NSString *seq, double away, void (^finish)(BOOL)) {
  const char *dir = core_data_dir();
  if (!core_files_open(dir)) {
    mb_perf_note("push: bring skipped, files closed");
    finish(NO);
    return;
  }
  const char *cloud = getenv("MBUI_CLOUD");
  const char *beta = getenv("MBUI_BETA");
  if (!mb_core_start_alone(dir, cloud && *cloud ? cloud : "https://app.still.fail", beta && !strcmp(beta, "1"))) {
    finish(NO);
    return;
  }
  pushes_bringing++;
  uint64_t began = clock_gettime_nsec_np(CLOCK_MONOTONIC);
  __block BOOL ended = NO;
  void (^end)(BOOL, const char *) = ^(BOOL brought, const char *how) {
    if (ended) return;
    ended = YES;
    char line[80];
    snprintf(line, sizeof line, "push: bring %s %.0f ms", how, (clock_gettime_nsec_np(CLOCK_MONOTONIC) - began) / 1e6);
    mb_perf_note(line);
    BOOL last = --pushes_bringing == 0;
    // (stopping waits for the core's thread: off the main thread, the handler called once its files are let go)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      if (last) mb_core_stop_alone();
      dispatch_async(dispatch_get_main_queue(), ^{ finish(brought); });
    });
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, PUSH_BRING_NS), dispatch_get_main_queue(), ^{ end(NO, "timed out"); });
  NSMutableDictionary *bring = [@{@"station" : [NSString stringWithFormat:@"%@/%@", workspace, station], @"session" : session} mutableCopy];
  NSCharacterSet *notDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
  if (seq.length && [seq rangeOfCharacterFromSet:notDigits].location == NSNotFound) bring[@"seq"] = @(seq.longLongValue);
  NSString *params = json_of(bring);
  void (^ask_bring)(void) = ^{
    mb_core_ask("notice.bring", params.UTF8String, ^(int ok) {
      dispatch_async(dispatch_get_main_queue(), ^{ end(ok != 0, ok ? "done" : "failed"); });
    });
  };
  if (away < 0) {
    ask_bring();
    return;
  }
  mb_core_ask("client.wake", json_of(@{@"away" : @(away)}).UTF8String, ^(int ok) {
    (void)ok;
    dispatch_async(dispatch_get_main_queue(), ask_bring);
  });
}
#endif

#if TARGET_OS_IPHONE
#include <sys/utsname.h>
// The phone's model, as Android's CoreHost.java puts its maker's and model in MBUI_DEVICE_MODEL (the device's name the
// core makes: signin.mbt tell_device): its machine identifier (iPhone17,1; the simulator's the device it plays).
__attribute__((constructor)) static void device_model(void) {
  const char *sim = getenv("SIMULATOR_MODEL_IDENTIFIER");
  struct utsname u;
  if (!sim && uname(&u) != 0) return;
  setenv("MBUI_DEVICE_MODEL", sim ? sim : u.machine, 0);
}
// Whether this is the App Store's build (MBUI_STORE=appstore): no prompt then to update from TestFlight
// (updates.mbt stale_build), which is TestFlight's and a development build's alone. The App Store's receipt is
// `receipt`, TestFlight's and a development build's `sandboxReceipt`; the simulator's none. Not over one given.
__attribute__((constructor)) static void store_build(void) {
#if !TARGET_OS_SIMULATOR
  @autoreleasepool {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSURL *receipt = NSBundle.mainBundle.appStoreReceiptURL;
#pragma clang diagnostic pop
    if (receipt && ![receipt.lastPathComponent isEqualToString:@"sandboxReceipt"]) setenv("MBUI_STORE", "appstore", 0);
  }
#endif
}
#else
#include <SystemConfiguration/SystemConfiguration.h>
// The Mac's name as its owner knows it (系统设置 › 通用 › 关于本机: 左子健的 MacBook Air) in MBUI_DEVICE_NAME, the
// machine the core names this device by where the person's devices are listed (signin.mbt tell_device): which of their
// Macs it is. Not over one given (a scripted run's empty one: e2e/run.sh, the same wherever it is recorded).
__attribute__((constructor)) static void device_name(void) {
  CFStringRef name = SCDynamicStoreCopyComputerName(NULL, NULL);
  if (!name) return;
  char utf8[256];
  if (CFStringGetCString(name, utf8, sizeof utf8, kCFStringEncodingUTF8) && *utf8) setenv("MBUI_DEVICE_NAME", utf8, 0);
  CFRelease(name);
}
#endif

// The device's language for the app's words until the core says, and the core's when none is chosen (signin.mbt
// tell_device): MBUI_LOCALE, as Android's CoreHost.java and linux_engine.c put it, from the person's first preferred
// language (en-US, zh-Hans-CN: a BCP 47 tag); not over one given (a scripted run's own).
__attribute__((constructor)) static void device_locale(void) {
  @autoreleasepool {
    NSString *lang = NSLocale.preferredLanguages.firstObject;
    if (lang.length) setenv("MBUI_LOCALE", lang.UTF8String, 0);
  }
}
