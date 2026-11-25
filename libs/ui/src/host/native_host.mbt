// The platform's host (host_native.mbt and its C, Objective-C, C++; host_js.mbt and web/host.js) as mbui/hostapi's
// `Host`, set as the program starts: an app's main imports this package for it (and for its code linked in). Nothing
// else imports it: a test's program, given a Tester's fake host, links none of it.

///|
/// What the platform says once of what stays the same while the app runs, kept: asked (`ask`) the first time only.
fn said_once(kept : Ref[Int?], ask : () -> Int) -> Int {
  match kept.val {
    Some(v) => v
    None => {
      let v = ask()
      kept.val = Some(v)
      v
    }
  }
}

///|
// what the platform said once (said_once): its system, the keys typed, the native input, whether it says a copy itself,
// its decoders and video layers
let platform_said : Ref[Int?] = Ref(None)

///|
let keys_said : Ref[Int?] = Ref(None)

///|
let native_pointing_said : Ref[Int?] = Ref(None)

///|
let copy_shown_said : Ref[Int?] = Ref(None)

///|
let h264_said : Ref[Int?] = Ref(None)

///|
let h265_said : Ref[Int?] = Ref(None)

///|
let av1_said : Ref[Int?] = Ref(None)

///|
let feeds_said : Ref[Int?] = Ref(None)

///|
let layers_said : Ref[Int?] = Ref(None)

///|
fn make_native_host() -> @hostapi.Host {
  let h = @hostapi.Host::noop()
  h.set_window_zoom = fn(zoom) { set_window_zoom(zoom) }
  h.set_window_key = fn(f) { set_window_key(f) }
  h.wheel_kept = fn(kept) { wheel_kept(kept) }
  h.window_setup = fn(min_w, min_h, w, hh, inset) { window_setup(min_w, min_h, w, hh, inset~) }
  h.window_hold = fn() { window_hold() }
  h.window_show = fn() { window_show() }
  h.window_inset = fn() { window_inset() }
  h.full_screen = fn() { full_screen() }
  h.set_full_screen = fn(on) { set_full_screen(on) }
  h.window_buttons_down = fn(by, ms) { window_buttons_down(by, ms) }
  h.window_corner = fn() { window_corner() }
  h.window_corner_at = Some(fn(k) { window_corner_at(k) })
  h.window_drag = fn() { window_drag() }
  h.window_act = fn(what) { window_act(what) }
  h.window_zoomed = fn() { window_zoomed() }
  h.window_snap = fn(x, y, w, hh) { window_snap(x, y, w, hh) }
  h.window_snap_state = fn() { window_snap_state() }
  h.window_opens = fn() { window_opens() }
  h.window_open = fn(what) { window_open(what) }
  h.window_front = fn(what) { window_front(what) }
  h.windows_in_process = fn() { windows(0, 0, "") != 0 }
  h.window_open_id = fn(what) { windows(1, 0, what) }
  h.window_front_id = fn(wid) { windows(2, wid, "") != 0 }
  h.window_close_id = fn(wid) { windows(3, wid, "") |> ignore }
  h.window_current = fn() { windows(4, 0, "") }
  h.window_set_title = fn(wid, title) { windows(5, wid, title) |> ignore }
  h.set_cursor = fn(kind) { set_cursor(kind) }
  h.set_badge = fn(n) { set_badge(n) }
  h.menu_setup = fn(json) { menu_setup(json) }
  h.app_said = fn(name) { app_said(name) }
  h.app_tell = fn(name, arg) { app_tell(name, arg) }
  h.set_site_name = fn(name) { set_site_name(name) }
  h.mods_held = fn() { mods_held() }
  h.pointer_lock = fn(on) { pointer_lock(on) }
  h.pointer_locked = fn() { pointer_locked() }
  h.pointer_delta = fn(out) { pointer_delta(out) }
  h.gamepads = fn(out) { gamepads(out) }
  h.run = fn(title, frame, pointer, wheel, key, text) { run(title, frame, pointer, wheel, key, text) }
  h.now = fn() { now() }
  h.wall_ms = fn() { wall_ms() }
  h.utc_offset_min = fn(at_ms) { utc_offset_min(at_ms) }
  h.event_time = fn() { event_time() }
  h.event_finger = fn() { event_finger() }
  h.frame_late = fn() { frame_late() }
  h.platform = fn() { said_once(platform_said, fn() { platform() }) }
  h.request_frame = fn() { request_frame() }
  h.frames_paced = Some(fn(hz) { frames_paced(hz) })
  h.wake_after = fn(ms) { wake_after(ms) }
  h.font_metrics = fn(size, weight, style, out) { font_metrics(size, weight, style, out) }
  h.shape = fn(text, size, weight, style, out) { shape(text, size, weight, style, out) }
  h.text_key = fn(text, size, weight, style) { text_key(text, size, weight, style) }
  h.glyph = fn(key, out) { glyph(key, out) }
  h.glyph_put = fn(key, x, y) { glyph_put(key, x, y) }
  h.glyph_picture = fn(key, out) { glyph_picture(key, out) }
  h.atlas_put = fn(x, y, w, hh, px) { atlas_put(x, y, w, hh, px) }
  h.atlas_size = fn(colour) { atlas_size(colour) }
  h.glyphs_ahead = fn(keys, n) { glyphs_ahead(keys, n) }
  h.glyphs_ahead_able = fn() { true }
  h.face_add = fn(face, path, weight) { face_add(face, path, weight) }
  h.face_add_bytes = fn(face, data, weight) { face_add_bytes(face, data, weight) }
  h.face_clear = fn(face) { face_clear(face) }
  h.face_add_family = fn(face, family) { face_add_family(face, family) }
  h.has_local_fonts = fn() {
    let p = platform()
    p == 0 || p == 3 || p == 5
  }
  h.local_font_families = fn() { local_font_families() }
  h.face_set_ligatures = fn(face, on) { face_set_ligatures(face, on) }
  h.set_host_autospace = fn(on) { set_host_autospace(on) }
  h.local_font_info = fn() { local_font_info() }
  h.atlas_generation = fn() { atlas_generation() }
  h.present = fn(buf, count, r, g, b) { present(buf, count, r, g, b) }
  h.groups_here = fn() { groups_here() }
  h.group_set = fn(id, inst, moves, n) { group_set(id, inst, moves, n) }
  h.group_drop = fn(id) { group_drop(id) }
  h.set_ime = fn(active, x, y, w, h, text, sel_start, sel_end) { set_ime(active, x, y, w, h, text, sel_start, sel_end) }
  h.text_menu = fn(shown, x, y, w, h, can) { ffi_text_menu(if shown { 1 } else { 0 }, x, y, w, h, can) }
  h.text_menu_own = fn(words) { ffi_text_menu_own(words) }
  h.edit_can = fn(can) { ffi_edit_can(can) }
  h.clipboard_set = fn(s) { clipboard_set(s) }
  h.clipboard_set_html = Some(fn(text, html) { clipboard_set_html(text, html) })
  h.clipboard_set_image = fn(data) { clipboard_set_image(data) }
  h.clipboard_set_secret = fn(s, clear_ms) { clipboard_set_secret(s, clear_ms~) }
  h.clipboard_secret_off = fn() { clipboard_secret_off() }
  h.log = fn(s) { log(s) }
  h.bench_mode = fn() { bench_mode() }
  h.set_outside = fn(f) { set_outside(f) }
  h.frame_awaiting = fn(awaiting, what) { frame_awaiting(awaiting, what) }
  h.own_clock = fn() { own_clock() }
  h.reduce_motion = fn() { reduce_motion() }
  h.keys_platform = fn() { said_once(keys_said, fn() { keys_platform() }) }
  h.exit = fn(code) { exit(code) }
  h.mem_bytes = fn() { mem_bytes() }
  h.set_back = fn(back) { set_back(back) }
  h.back_enabled = fn(on) { back_enabled(on) }
  h.reduce_transparency = fn() { reduce_transparency() }
  h.increase_contrast = fn() { increase_contrast() }
  h.thermal_throttled = fn() { thermal_throttled() }
  h.gpu_ms = fn() { gpu_ms() }
  h.frames_dropped = fn() { frames_dropped() }
  h.cpu_ms = fn() { cpu_ms() }
  h.thread_cpu_ms = fn() { thread_cpu_ms() }
  h.display_hz = fn() { display_hz() }
  h.perf_state = fn() { perf_state() }
  h.set_perf = fn(on) { set_perf(on) }
  h.perf_line = fn(line) { perf_line(line) }
  h.perf_where = fn() { perf_where() }
  h.perf_size = fn() { perf_size() }
  h.perf_open = fn(go) { perf_open(go) }
  h.reveal_file = fn(path, go) { reveal_file(path, go) }
  h.perf_read = fn() { perf_read() }
  h.env = fn(name) { env(name) }
  h.set_app_state = fn(f) { set_app_state(f) }
  h.system_dark = fn() { system_dark() }
  h.font_scale = fn() { font_scale() }
  h.native_pointing = fn() { said_once(native_pointing_said, fn() { native_pointing() }) }
  h.keyboard = fn() { keyboard() }
  h.a11y_on = fn() { a11y_on() }
  h.a11y_tree = fn(s) { a11y_tree(s) }
  h.set_dark = fn(dark) { set_dark(dark) }
  h.set_sideways = fn(on) { set_sideways(on) }
  h.set_turnable = fn(on) { set_turnable(on) }
  h.share = fn(text, name, mime, data) { share(text, name, mime, data) }
  h.shared_in = fn() { shared_in() }
  h.shared_in_file = fn(i) { shared_in_file(i) }
  h.app_version = fn() { app_version() }
  h.update_fetch = fn(url, sha256, size, name, now, delta) { update_fetch(url, sha256, size, name, now, delta) }
  h.update_apply = fn(said) { update_apply(said) }
  h.update_state = fn() { update_state() }
  h.install_package = fn(name, data) { install_package(name, data) }
  h.drive = fn(kind, text) { drive(kind, text) }
  h.image_load = fn(src, max_px) { image_load(src, max_px) }
  h.image_load_bytes = fn(data, max_px) { image_load_bytes(data, max_px) }
  h.image_info = fn(id, out) { image_info(id, out) }
  h.image_free = fn(id) { image_free(id) }
  h.image_pixels = fn(id, out) { image_pixels(id, out) }
  h.drawn_pixels = fn(x, y, w, hh, out) { drawn_pixels(x, y, w, hh, out) }
  h.drawn_pixels_of = fn(inst, count, r, g, b, scale, w, h, out) { drawn_pixels_of(inst, count, r, g, b, scale, w, h, out) }
  h.view_site_next = fn(id) { view_site_next(id) }
  h.view_site_body = fn(id, req) { view_site_body(id, req) }
  h.view_site_head = fn(id, req, status, headers) { view_site_head(id, req, status, headers) }
  h.view_site_chunk = fn(id, req, data) { view_site_chunk(id, req, data) }
  h.view_site_end = fn(id, req, error) { view_site_end(id, req, error) }
  h.view_site_state = fn(id) { view_site_state(id) }
  h.view_site_load = fn(id, path) { view_site_load(id, path) }
  h.view_tell = fn(id, what, text) { view_tell(id, what, text) }
  h.view_open = fn(kind, arg) { view_open(kind, arg) }
  h.view_place = fn(id, x, y, w, hh, cx0, cy0, cx1, cy1, r0, r1, r2, r3, shown) { view_place(id, x, y, w, hh, cx0, cy0, cx1, cy1, r0, r1, r2, r3, shown) }
  h.view_close = fn(id) { view_close(id) }
  h.view_control = fn(id, op, value) { view_control(id, op, value) }
  h.view_info = fn(id, out) { view_info(id, out) }
  h.view_read_next = fn(id, out) { view_read_next(id, out) }
  h.view_read_answer = fn(id, req, data, total, more) { view_read_answer(id, req, data, total, more) }
  h.pdf_open = fn(data) { pdf_open(data) }
  h.pdf_pages = fn(doc) { pdf_pages(doc) }
  h.pdf_page_size = fn(doc, page, out) { pdf_page_size(doc, page, out) }
  h.pdf_page_load = fn(doc, page, max_px) { pdf_page_load(doc, page, max_px) }
  h.pdf_close = fn(doc) { pdf_close(doc) }
  h.view_text = fn(id, what) { view_text(id, what) }
  h.view_still = fn(id) { view_still(id) }
  h.save_file = fn(name, data) { save_file(name, data) }
  h.word_at = fn(text, off) { word_at(text, off) }
  h.open_url = fn(url) { open_url(url) }
  h.over_done = fn(open_app) { over_done(open_app~) }
  h.open_tab = fn(url) { open_tab(url) }
  h.hold_words = fn(channel, title, body) { hold_words(channel~, title~, body~) }
  h.post_take = fn() { post_take() }
  h.post_next = fn() { post_next() }
  h.ref_begin = fn(w, h, scale, bg) { ref_begin(w, h, scale, bg) }
  h.ref_text = fn(text, size, weight, style, x, base, color, out) { ref_text(text, size, weight, style, x, base, color, out) }
  h.ref_end = fn(name) { ref_end(name) }
  h.ref_frame = fn(name) { ref_frame(name) }
  h.bl_start = fn(path, done) { bl_start(path, done) }
  h.bl_port = fn(id) { bl_port(id) }
  h.bl_open = fn(id, url) { bl_open(id, url) }
  h.bl_back = fn(id) { bl_back(id) }
  h.bl_end = fn(id) { bl_end(id) }
  h.pw_able = fn() { pw_able() != 0 }
  h.pw_run = fn(args) { pw_run(args) }
  h.pw_out = fn(id) { pw_out(id) }
  h.pw_end = fn(id) { pw_end(id) }
  h.af_able = fn() { af_able() != 0 }
  h.af_ask = fn(host) { af_ask(host) }
  h.af_take = fn() { af_take() }
  h.af_end = fn() { af_end() }
  h.wa_able = fn() { wa_able() != 0 }
  h.wa_get = fn(ask) { wa_get(ask) }
  h.wa_out = fn(id) { wa_out(id) }
  h.wa_end = fn(id) { wa_end(id) }
  h.pk_start = fn(kind) { pk_start(kind) }
  h.pk_state = fn(id) { pk_state(id) }
  h.pk_count = fn(id) { pk_count(id) }
  h.pk_name = fn(id, i) { pk_name(id, i) }
  h.pk_bytes = fn(id, i) { pk_bytes(id, i) }
  h.pk_info = fn(id, i) { pk_info(id, i) }
  h.pk_end = fn(id) { pk_end(id) }
  h.kp_begin = fn(name, mime, way) { kp_begin(name, mime, way) }
  h.kp_append = fn(id, data) { kp_append(id, data) }
  h.kp_finish = fn(id) { kp_finish(id) }
  h.kp_state = fn(id) { kp_state(id) }
  h.kp_where = fn(id) { kp_where(id) }
  h.kp_end = fn(id) { kp_end(id) }
  h.ga_access = fn() { ga_access() }
  h.ga_ask = fn() { ga_ask() }
  h.ga_answers = fn() { ga_answers() }
  h.ga_read = fn() { ga_read() }
  h.ga_read_state = fn(id) { ga_read_state(id) }
  h.ga_read_rows = fn(id) { ga_read_rows(id) }
  h.ga_read_end = fn(id) { ga_read_end(id) }
  h.pk_photo = fn(src) { pk_photo(src) }
  h.cs_known = fn(charset) { cs_known(charset) }
  h.cs_decode = fn(data, charset) { cs_decode(data, charset) }
  h.mk_start = fn(image, marks) { mk_start(image, marks) }
  h.mk_state = fn(id) { mk_state(id) }
  h.mk_png = fn(id) { mk_png(id) }
  h.nt_show = fn(channel, tag, title, body, opens) { nt_show(channel, tag, title, body, opens) }
  h.nt_cancel = fn(tag) { nt_cancel(tag) }
  h.rn_dirty = fn(x, y, w, h) { rn_dirty(x, y, w, h) }
  h.rn_glass_light_angle = fn(rad) { rn_glass_light_angle(rad) }
  h.nv_bar = fn(spec) { nv_bar(spec) }
  h.nv_able = fn() { nv_able() != 0 }
  h.nt_state = fn(what) { nt_state(what) }
  h.nt_text = fn(what) { nt_text(what) }
  h.st_open = fn() { st_open() }
  h.st_h264 = fn(id, avcc, w, hh) { st_h264(id, avcc, w, hh) }
  h.st_frame = fn(id, data, key, ts) { st_frame(id, data, key, ts) }
  h.st_jpeg = fn(id, data, ts) { st_jpeg(id, data, ts) }
  h.st_next = fn(id) { st_next(id) }
  h.st_show = fn(id, ts) { st_show(id, ts) }
  h.st_close = fn(id) { st_close(id) }
  h.st_h264_here = fn() { said_once(h264_said, fn() { st_h264_here() }) }
  h.st_feeds = fn() { said_once(feeds_said, fn() { st_feeds() }) }
  h.st_codec = fn(id, cmd, data) { st_codec(id, cmd, data) }
  h.cl_read = fn() { cl_read() }
  h.cl_state = fn(id) { cl_state(id) }
  h.cl_picture = fn(id) { cl_picture(id) }
  h.tm_open = fn(cols, rows) { tm_open(cols, rows) }
  h.tm_write = fn(id, data) { tm_write(id, data) }
  h.tm_resize = fn(id, cols, rows, cw, ch) { tm_resize(id, cols, rows, cw, ch) }
  h.tm_frame = fn(id, flags) { tm_frame(id, flags) }
  h.tm_modes = fn(id) { tm_modes(id) }
  h.tm_scroll = fn(id, kind, value) { tm_scroll(id, kind, value) }
  h.tm_select = fn(id, kind, x0, y0, x1, y1) { tm_select(id, kind, x0, y0, x1, y1) }
  h.tm_text = fn(id, sel) { tm_text(id, sel) }
  h.tm_mouse = fn(id, action, button, mods, x, y, w, h, cw, ch) { tm_mouse(id, action, button, mods, x, y, w, h, cw, ch) }
  h.tm_close = fn(id) { tm_close(id) }
  h.cl_text = fn(id) { cl_text(id) }
  h.cl_png = fn(id) { cl_png(id) }
  h.cl_files = fn(id) { cl_files(id) }
  h.cl_file_name = fn(id, i) { cl_file_name(id, i) }
  h.cl_file = fn(id, i) { cl_file(id, i) }
  h.cl_end = fn(id) { cl_end(id) }
  h.cl_set = fn(text, png, label) { cl_set(text, png, label) }
  h.dv_copy_shown = fn() { said_once(copy_shown_said, fn() { dv_copy_shown() }) }
  h.dv_key_catch = fn(on) { dv_key_catch(on) }
  h.dv_ime_inset = fn() { dv_ime_inset() }
  h.dv_keep_awake = fn(on) { dv_keep_awake(on) }
  h.dv_haptic = fn(kind) { dv_haptic(kind) }
  h.dv_ime_action = fn(kind) { dv_ime_action(kind) }
  h.dv_ime_let_go = fn() { dv_ime_let_go() }
  h.ncall_call = fn(name, params) { ncall_call(name, params) }
  h.ncall_state = fn(id) { ncall_state(id) }
  h.ncall_result = fn(id) { ncall_result(id) }
  h.ncall_end = fn(id) { ncall_end(id) }
  h.st_audio_here = fn() { st_audio_here() }
  h.st_audio = fn(id, data) { st_audio(id, data) }
  h.st_layers = fn() { said_once(layers_said, fn() { st_layers() }) }
  h.st_pointer = fn(id, png, w, hh, hx, hy) { st_pointer(id, png, w, hh, hx, hy) }
  h.st_pointer_at = fn(id, x, y, shown) { st_pointer_at(id, x, y, shown) }
  h.st_direct = fn(id, route, after, what) { st_direct(id, route, after, what) }
  h.st_h265_here = fn() { said_once(h265_said, fn() { st_h265_here() }) }
  h.st_hevc = fn(id, hvcc, w, hh) { st_hevc(id, hvcc, w, hh) }
  h.st_av1_here = fn() { said_once(av1_said, fn() { st_av1_here() }) }
  h.st_av1 = fn(id, av1c, w, hh) { st_av1(id, av1c, w, hh) }
  h.rows_on_pixels = fn() { true }
  h.st_frame_shown = Some(fn(id, data, key, ts, show) { st_frame_shown(id, data, key, ts, show) })
  h.st_flush = fn(id, drain) { st_flush(id, drain) }
  h.st_audio_played = fn(id) { st_audio_played(id) }
  h.st_audio_queued = fn(id) { st_audio_queued(id) }
  h.st_audio_wanted = fn(id) { st_audio_wanted(id) }
  h.st_audio_volume = fn(id, v) { st_audio_volume(id, v) }
  h.auto_launch = fn() { auto_launch() }
  h.set_auto_launch = fn(enabled) { set_auto_launch(enabled) }
  h.hotkey_set = fn(id, accel) { hotkey_set(id, accel) }
  h.hotkey_clear = fn(id) { hotkey_clear(id) }
  h
}

///|
fn init {
  @hostapi.set_host(make_native_host())
}
