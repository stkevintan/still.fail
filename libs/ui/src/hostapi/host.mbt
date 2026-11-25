// The host's side, for every package that is not an app's main: the window, the text and pictures the system draws, what the
// device does. Everything mbui and an app ask of their host goes through `Host`; which host answers is set as the
// program starts: an app's main imports mbui/host, whose `init` gives the platform's (macOS, iOS, Android, Windows, a
// browser); a test's Tester gives its fake (@ui's FakeHost). A test's program links no host's code (Objective-C, C++,
// JNI): it builds and runs on any machine.
//
// A method answers as a host with nothing for it does (nothing done, 0, false, empty, None) unless the host says
// otherwise: mbui/host's Native says every one (its native_host.mbt), as a new method must there too.
//
// The methods without docs here are what this package's own wrappers ask (pick.mbt's pk_*, keep.mbt's kp_*…).

///|
pub(all) struct Host {
  mut set_window_zoom : (Double) -> Unit
  mut set_window_key : (FuncRef[(Int, Int) -> Int]) -> Unit
  mut wheel_kept : (Bool) -> Unit
  mut window_setup : (Double, Double, Double, Double, Bool) -> Unit
  mut window_inset : () -> Bool
  mut window_buttons_down : (Double, Double) -> Unit
  mut window_hold : () -> Unit
  mut window_show : () -> Unit
  mut full_screen : () -> Bool
  mut set_full_screen : (Bool) -> Unit
  mut window_corner : () -> Double
  mut window_corner_at : ((Int) -> Double)?
  mut window_drag : () -> Unit
  mut window_act : (Int) -> Unit
  mut window_zoomed : () -> Bool
  mut window_snap : (Double, Double, Double, Double) -> Unit
  mut window_snap_state : () -> Int
  mut window_opens : () -> Bool
  mut window_open : (String) -> Bool
  mut window_front : (String) -> Bool
  mut windows_in_process : () -> Bool
  mut window_open_id : (String) -> Int
  mut window_front_id : (Int) -> Bool
  mut window_close_id : (Int) -> Unit
  mut window_current : () -> Int
  mut set_cursor : (Int) -> Unit
  mut set_badge : (Int) -> Unit
  mut menu_setup : (String) -> Unit
  mut app_said : (String) -> String
  mut app_tell : (String, String) -> Unit
  mut set_site_name : (String) -> Unit
  mut mods_held : () -> Int
  mut run : (String, FuncRef[(Double, Double, Double, Double) -> Unit], FuncRef[(Int, Double, Double, Int) -> Unit], FuncRef[(Double, Double, Double, Double, Int) -> Unit], FuncRef[(Int, Int) -> Unit], FuncRef[(Int, String, Int, Int) -> Unit]) -> Unit
  mut now : () -> Double
  mut wall_ms : () -> Double
  mut clock_at_wall : ((Double) -> Double)?
  mut utc_offset_min : (Double) -> Int
  mut event_time : () -> Double
  mut event_finger : () -> Int
  mut frame_late : () -> Double
  mut platform : () -> Int
  mut request_frame : () -> Unit
  mut request_frame_on : (() -> Unit)?
  mut frames_paced : ((Double) -> Unit)?
  mut wake_after : (Double) -> Unit
  mut font_metrics : (Double, Int, Int, FixedArray[Double]) -> Unit
  mut shape : (String, Double, Int, Int, FixedArray[Double]) -> Int
  mut text_key : (String, Double, Int, Int) -> Int
  mut glyph : (Int, FixedArray[Double]) -> Unit
  mut glyph_put : (Int, Int, Int) -> Unit
  mut atlas_size : (Bool) -> Int
  mut glyphs_ahead : (FixedArray[Int], Int) -> Unit
  mut glyph_picture : (Int, FixedArray[Byte]) -> Bool
  mut atlas_put : (Int, Int, Int, Int, FixedArray[Byte]) -> Bool
  mut face_add : (Int, String, Int) -> Bool
  mut face_add_bytes : (Int, Bytes, Int) -> Bool
  mut face_clear : (Int) -> Unit
  mut face_add_family : (Int, String) -> Bool
  mut local_font_families : () -> String
  mut atlas_generation : () -> Int
  mut present : (FixedArray[Double], Int, Double, Double, Double) -> Unit
  mut groups_here : () -> Bool
  mut group_set : (Int, FixedArray[Double], FixedArray[Double], Int) -> Unit
  mut group_drop : (Int) -> Unit
  mut set_ime : (Bool, Double, Double, Double, Double, String, Int, Int) -> Unit
  mut text_menu : (Bool, Double, Double, Double, Double, Int) -> Unit
  mut text_menu_own : (String) -> Unit
  mut edit_can : (Int) -> Unit
  mut clipboard_set : (String) -> Unit
  mut clipboard_set_html : ((String, String) -> Unit)?
  mut clipboard_set_secret : (String, Double) -> Unit
  mut clipboard_secret_off : () -> Unit
  mut clipboard_set_image : (Bytes) -> Unit
  mut log : (String) -> Unit
  mut bench_mode : () -> Int
  mut set_outside : (FuncRef[(Int, Int, Int) -> Unit]) -> Bool
  mut answers_by_frame : (Int) -> Bool
  mut script_step : (String, String) -> String
  mut rows_on_pixels : () -> Bool
  mut keeps_sources : () -> Bool
  mut lines_on_pixels : (() -> Bool)?
  mut frame_awaiting : (Int, String) -> Unit
  mut own_clock : () -> Bool
  mut reduce_motion : () -> Bool
  mut keys_platform : () -> Int
  mut exit : (Int) -> Unit
  mut mem_bytes : () -> Double
  mut set_back : (FuncRef[(Int, Double, Double, Int) -> Unit]) -> Unit
  mut back_enabled : (Bool) -> Unit
  mut reduce_transparency : () -> Bool
  mut increase_contrast : () -> Bool
  mut thermal_throttled : () -> Bool
  mut gpu_ms : () -> Double
  mut frames_dropped : () -> Int
  mut cpu_ms : () -> Double
  mut thread_cpu_ms : () -> Double
  mut display_hz : () -> Double
  mut env : (String) -> String
  mut set_app_state : (FuncRef[(Int) -> Unit]) -> Unit
  mut system_dark : () -> Bool
  mut font_scale : () -> Double
  mut native_pointing : () -> Int
  mut pointing : () -> Int
  mut keyboard : () -> Int
  mut a11y_on : () -> Bool
  mut a11y_tree : (String) -> Unit
  mut set_dark : (Bool) -> Unit
  mut set_sideways : (Bool) -> Unit
  mut set_turnable : (Bool) -> Bool
  mut share : (String, String, String, Bytes) -> Bool
  mut perf_state : () -> Int
  mut set_perf : (Bool) -> Unit
  mut perf_line : (String) -> Unit
  mut perf_where : () -> String
  mut perf_size : () -> Double
  mut perf_read : () -> Bytes
  mut perf_open : (Bool) -> Bool
  mut reveal_file : (String, Bool) -> Bool
  mut shared_in : () -> String
  mut shared_in_file : (Int) -> Bytes
  mut app_version : () -> Int
  mut update_fetch : (String, String, Double, String, Bool, String) -> Unit
  mut update_apply : (String) -> Unit
  mut update_state : () -> String
  mut install_package : (String, Bytes) -> Unit
  mut drive : (Int, String) -> Bool
  mut image_load : (String, Int) -> Int
  mut image_load_bytes : (Bytes, Int) -> Int
  mut image_info : (Int, FixedArray[Double]) -> Int
  mut image_free : (Int) -> Unit
  mut image_pixels : (Int, FixedArray[Byte]) -> Bool
  mut drawn_pixels : (Int, Int, Int, Int, FixedArray[Byte]) -> Bool
  mut drawn_pixels_of : (FixedArray[Double], Int, Double, Double, Double, Double, Int, Int, FixedArray[Byte]) -> Bool
  mut view_site_next : (Int) -> String
  mut view_site_body : (Int, Int) -> Bytes
  mut view_site_head : (Int, Int, Int, String) -> Unit
  mut view_site_chunk : (Int, Int, Bytes) -> Unit
  mut view_site_end : (Int, Int, String) -> Unit
  mut view_site_state : (Int) -> String
  mut view_site_load : (Int, String) -> Unit
  mut view_tell : (Int, Int, String) -> Unit
  mut view_open : (Int, String) -> Int
  mut view_place : (Int, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Bool) -> Unit
  mut view_close : (Int) -> Unit
  mut view_control : (Int, Int, Double) -> Unit
  mut view_info : (Int, FixedArray[Double]) -> Int
  mut view_read_next : (Int, FixedArray[Double]) -> Int
  mut view_read_answer : (Int, Int, Bytes, Double, Bool) -> Unit
  mut pdf_open : (Bytes) -> Int
  mut pdf_pages : (Int) -> Int
  mut pdf_page_size : (Int, Int, FixedArray[Double]) -> Unit
  mut pdf_page_load : (Int, Int, Int) -> Int
  mut pdf_close : (Int) -> Unit
  mut view_text : (Int, Int) -> String?
  mut view_still : (Int) -> Bytes
  mut save_file : (String, Bytes) -> Bool
  mut word_at : (String, Int) -> (Int, Int)
  mut open_url : (String) -> Bool
  mut over_done : (Bool) -> Unit
  mut open_tab : (String) -> Bool
  mut hold_words : (String, String, String) -> Unit
  mut post_take : () -> Int
  mut post_next : () -> (String, String, Bytes)?
  mut ref_begin : (Double, Double, Double, Int) -> Unit
  mut ref_text : (String, Double, Int, Int, Double, Double, Int, FixedArray[Double]) -> Unit
  mut ref_end : (String) -> Bool
  mut ref_frame : (String) -> Bool
  mut bl_start : (String, String) -> Int
  mut bl_port : (Int) -> Int
  mut bl_open : (Int, String) -> Int
  mut bl_back : (Int) -> String
  mut bl_end : (Int) -> Unit
  mut pw_able : () -> Bool
  mut pw_run : (String) -> Int
  mut pw_out : (Int) -> String
  mut pw_end : (Int) -> Unit
  mut af_able : () -> Bool
  mut af_ask : (String) -> Int
  mut af_take : () -> String
  mut af_end : () -> Unit
  mut wa_able : () -> Bool
  mut wa_get : (String) -> Int
  mut wa_out : (Int) -> String
  mut wa_end : (Int) -> Unit
  mut pk_start : (Int) -> Int
  mut pk_state : (Int) -> Int
  mut pk_count : (Int) -> Int
  mut pk_name : (Int, Int) -> String
  mut pk_bytes : (Int, Int) -> Bytes
  mut pk_info : (Int, Int) -> String
  mut pk_end : (Int) -> Unit
  mut kp_begin : (String, String, Int) -> Int
  mut kp_append : (Int, Bytes) -> Int
  mut kp_finish : (Int) -> Unit
  mut kp_state : (Int) -> Int
  mut kp_where : (Int) -> String
  mut kp_end : (Int) -> Unit
  mut ga_access : () -> Int
  mut ga_ask : () -> Unit
  mut ga_answers : () -> Int
  mut ga_read : () -> Int
  mut ga_read_state : (Int) -> Int
  mut ga_read_rows : (Int) -> String
  mut ga_read_end : (Int) -> Unit
  mut pk_photo : (String) -> Int
  mut cs_known : (String) -> Int
  mut cs_decode : (Bytes, String) -> String
  mut mk_start : (Bytes, String) -> Int
  mut mk_state : (Int) -> Int
  mut mk_png : (Int) -> Bytes
  mut nt_show : (String, String, String, String, String) -> Unit
  mut rn_dirty : (Double, Double, Double, Double) -> Unit
  mut rn_glass_light_angle : (Double) -> Unit
  mut nv_bar : (String) -> Int
  mut nv_able : () -> Bool
  mut nt_cancel : (String) -> Unit
  mut nt_state : (Int) -> Int
  mut nt_text : (Int) -> String
  mut st_audio_here : () -> Int
  mut st_audio : (Int, Bytes) -> Unit
  mut st_audio_played : (Int) -> Double
  mut st_audio_queued : (Int) -> Double
  mut st_audio_wanted : (Int) -> Double
  mut st_audio_volume : (Int, Double) -> Unit
  mut st_frame_shown : ((Int, Bytes, Int, Double, Int) -> Int)?
  mut st_flush : (Int, Int) -> Unit
  mut st_layers : () -> Int
  mut st_pointer : (Int, Bytes, Double, Double, Double, Double) -> Unit
  mut st_pointer_named : ((Int, String, () -> Bytes, Double, Double, Double, Double) -> Unit)?
  mut st_pointer_at : (Int, Double, Double, Int) -> Unit
  mut st_direct : (Int, Double, Double, Int) -> Unit
  mut st_h265_here : () -> Int
  mut st_hevc : (Int, Bytes, Int, Int) -> Unit
  mut st_av1_here : () -> Int
  mut st_av1 : (Int, Bytes, Int, Int) -> Unit
  mut st_open : () -> Int
  mut st_h264 : (Int, Bytes, Int, Int) -> Unit
  mut st_frame : (Int, Bytes, Int, Double) -> Unit
  mut st_jpeg : (Int, Bytes, Double) -> Unit
  mut st_next : (Int) -> String
  mut st_show : (Int, Double) -> Unit
  mut st_close : (Int) -> Unit
  mut st_h264_here : () -> Int
  mut st_feeds : () -> Int
  mut st_codec : (Int, String, Bytes) -> Unit
  mut cl_read : () -> Int
  mut cl_state : (Int) -> Int
  mut cl_picture : (Int) -> Int
  mut tm_open : (Int, Int) -> Int
  mut tm_write : (Int, Bytes) -> Unit
  mut tm_resize : (Int, Int, Int, Int, Int) -> Unit
  mut tm_frame : (Int, Int) -> Bytes
  mut tm_modes : (Int) -> Int
  mut tm_scroll : (Int, Int, Int) -> Unit
  mut tm_select : (Int, Int, Int, Int, Int, Int) -> Int
  mut tm_text : (Int, Int) -> String
  mut tm_mouse : (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) -> Bytes
  mut tm_close : (Int) -> Unit
  mut cl_text : (Int) -> String
  mut cl_png : (Int) -> Bytes
  mut cl_files : (Int) -> Int
  mut cl_file_name : (Int, Int) -> String
  mut cl_file : (Int, Int) -> Bytes
  mut cl_end : (Int) -> Unit
  mut cl_set : (String, Bytes, String) -> Unit
  mut dv_copy_shown : () -> Int
  mut dv_key_catch : (Int) -> Unit
  mut dv_ime_inset : () -> Double
  mut dv_keep_awake : (Int) -> Unit
  mut dv_haptic : (Int) -> Unit
  mut dv_ime_action : (Int) -> Unit
  mut dv_ime_let_go : () -> Unit
  mut ncall_call : (String, String) -> Int
  mut ncall_state : (Int) -> Int
  mut ncall_result : (Int) -> String
  mut ncall_end : (Int) -> Unit
  mut words_spaced : (() -> Int)?
  mut window_set_title : (Int, String) -> Unit
  mut auto_launch : () -> Bool
  mut set_auto_launch : (Bool) -> Bool
  mut hotkey_set : (String, String) -> Bool
  mut hotkey_clear : (String) -> Unit
  mut pointer_lock : (Bool) -> Unit
  mut pointer_locked : () -> Bool
  mut pointer_delta : (FixedArray[Double]) -> Unit
  mut gamepads : (FixedArray[Double]) -> Int
  mut glyphs_ahead_able : () -> Bool
  mut has_local_fonts : () -> Bool
  mut face_set_ligatures : (Int, Bool) -> Unit
  mut set_host_autospace : (Bool) -> Unit
  mut local_font_info : () -> String
  mut has_async_local_font_info : () -> Bool
}

///|
/// Found from a host's own shapes (MBUI_AUTOSPACE=off: none wanted; see words_spaced).
pub fn words_spaced_of(h : Host) -> Int {
  if (h.env)("MBUI_AUTOSPACE") == "off" {
    return words_spaced_none
  }
  // a Han character and a Latin letter shaped together a sixteenth of an em wider than each on its own (Core Text's:
  // an eighth, on whichever of the two it puts it)
  let size = 16.0
  let pair = FixedArray::make(8, 0.0)
  let han = FixedArray::make(4, 0.0)
  let latin = FixedArray::make(4, 0.0)
  if (h.shape)("\u{56FD}a", size, 400, 0, pair) == 2 &&
    (h.shape)("\u{56FD}", size, 400, 0, han) == 1 &&
    (h.shape)("a", size, 400, 0, latin) == 1 &&
    pair[2] + pair[6] - han[2] - latin[2] > size / 16.0 {
    words_spaced_by_host
  } else {
    words_spaced_here
  }
}

///|
/// A host with nothing for any call (nothing done, 0, false, empty, None).
pub fn Host::noop() -> Host {
  {
    set_window_zoom: fn(_) { () },
    set_window_key: fn(_) { () },
    wheel_kept: fn(_) { () },
    window_setup: fn(_, _, _, _, _) { () },
    window_inset: fn() { false },
    window_buttons_down: fn(_, _) { () },
    window_hold: fn() { () },
    window_show: fn() { () },
    full_screen: fn() { false },
    set_full_screen: fn(_) { () },
    window_corner: fn() { 0.0 },
    window_corner_at: None,
    window_drag: fn() { () },
    window_act: fn(_) { () },
    window_zoomed: fn() { false },
    window_snap: fn(_, _, _, _) { () },
    window_snap_state: fn() { 0 },
    window_opens: fn() { false },
    window_open: fn(_) { false },
    window_front: fn(_) { false },
    windows_in_process: fn() { false },
    window_open_id: fn(_) { 0 },
    window_front_id: fn(_) { false },
    window_close_id: fn(_) { () },
    window_current: fn() { 0 },
    set_cursor: fn(_) { () },
    set_badge: fn(_) { () },
    menu_setup: fn(_) { () },
    app_said: fn(_) { "" },
    app_tell: fn(_, _) { () },
    set_site_name: fn(_) { () },
    mods_held: fn() { 0 },
    run: fn(_, _, _, _, _, _) { @halt.saying("mbui: no host: an app's main imports mbui/host") },
    now: fn() { 0.0 },
    wall_ms: fn() { 0.0 },
    clock_at_wall: None,
    utc_offset_min: fn(_) { 0 },
    event_time: fn() { -1.0 },
    event_finger: fn() { -1 },
    frame_late: fn() { 0.0 },
    platform: fn() { 0 },
    request_frame: fn() { () },
    request_frame_on: None,
    frames_paced: None,
    wake_after: fn(_) { () },
    font_metrics: fn(_, _, _, _) { () },
    shape: fn(_, _, _, _, _) { 0 },
    text_key: fn(_, _, _, _) { 0 },
    glyph: fn(_, _) { () },
    glyph_put: fn(_, _, _) { () },
    atlas_size: fn(_) { 0 },
    glyphs_ahead: fn(_, _) { () },
    glyph_picture: fn(_, _) { false },
    atlas_put: fn(_, _, _, _, _) { false },
    face_add: fn(_, _, _) { false },
    face_add_bytes: fn(_, _, _) { false },
    face_clear: fn(_) { () },
    face_add_family: fn(_, _) { false },
    local_font_families: fn() { "" },
    atlas_generation: fn() { 0 },
    present: fn(_, _, _, _, _) { () },
    groups_here: fn() { false },
    group_set: fn(_, _, _, _) { () },
    group_drop: fn(_) { () },
    set_ime: fn(_, _, _, _, _, _, _, _) { () },
    text_menu: fn(_, _, _, _, _, _) { () },
    text_menu_own: fn(_) { () },
    edit_can: fn(_) { () },
    clipboard_set: fn(_) { () },
    clipboard_set_html: None,
    clipboard_set_secret: fn(_, _) { () },
    clipboard_secret_off: fn() { () },
    clipboard_set_image: fn(_) { () },
    log: fn(_) { () },
    bench_mode: fn() { 0 },
    set_outside: fn(_) { false },
    answers_by_frame: fn(_) { false },
    script_step: fn(step, _) { "\{step}: this host takes no such step of a script" },
    rows_on_pixels: fn() { false },
    keeps_sources: fn() { false },
    lines_on_pixels: None,
    frame_awaiting: fn(_, _) { () },
    own_clock: fn() { false },
    reduce_motion: fn() { false },
    keys_platform: fn() { -1 },
    exit: fn(_) { () },
    mem_bytes: fn() { -1.0 },
    set_back: fn(_) { () },
    back_enabled: fn(_) { () },
    reduce_transparency: fn() { false },
    increase_contrast: fn() { false },
    thermal_throttled: fn() { false },
    gpu_ms: fn() { -1.0 },
    frames_dropped: fn() { 0 },
    cpu_ms: fn() { -1.0 },
    thread_cpu_ms: fn() { -1.0 },
    display_hz: fn() { 0.0 },
    env: fn(_) { "" },
    set_app_state: fn(_) { () },
    system_dark: fn() { false },
    font_scale: fn() { 1.0 },
    native_pointing: fn() { 0 },
    pointing: fn() { -1 },
    keyboard: fn() { -1 },
    a11y_on: fn() { false },
    a11y_tree: fn(_) { () },
    set_dark: fn(_) { () },
    set_sideways: fn(_) { () },
    set_turnable: fn(_) { false },
    share: fn(_, _, _, _) { false },
    perf_state: fn() { -1 },
    set_perf: fn(_) { () },
    perf_line: fn(_) { () },
    perf_where: fn() { "" },
    perf_size: fn() { 0.0 },
    perf_read: fn() { b"" },
    perf_open: fn(_) { false },
    reveal_file: fn(_, _) { false },
    shared_in: fn() { "" },
    shared_in_file: fn(_) { b"" },
    app_version: fn() { 0 },
    update_fetch: fn(_, _, _, _, _, _) { () },
    update_apply: fn(_) { () },
    update_state: fn() { "" },
    install_package: fn(_, _) { () },
    drive: fn(_, _) { false },
    image_load: fn(_, _) { 0 },
    image_load_bytes: fn(_, _) { 0 },
    image_info: fn(_, _) { 0 },
    image_free: fn(_) { () },
    image_pixels: fn(_, _) { false },
    drawn_pixels: fn(_, _, _, _, _) { false },
    drawn_pixels_of: fn(_, _, _, _, _, _, _, _, _) { false },
    view_site_next: fn(_) { "" },
    view_site_body: fn(_, _) { b"" },
    view_site_head: fn(_, _, _, _) { () },
    view_site_chunk: fn(_, _, _) { () },
    view_site_end: fn(_, _, _) { () },
    view_site_state: fn(_) { "" },
    view_site_load: fn(_, _) { () },
    view_tell: fn(_, _, _) { () },
    view_open: fn(_, _) { 0 },
    view_place: fn(_, _, _, _, _, _, _, _, _, _, _, _, _, _) { () },
    view_close: fn(_) { () },
    view_control: fn(_, _, _) { () },
    view_info: fn(_, _) { -1 },
    view_read_next: fn(_, _) { 0 },
    view_read_answer: fn(_, _, _, _, _) { () },
    pdf_open: fn(_) { 0 },
    pdf_pages: fn(_) { 0 },
    pdf_page_size: fn(_, _, _) { () },
    pdf_page_load: fn(_, _, _) { 0 },
    pdf_close: fn(_) { () },
    view_text: fn(_, _) { None },
    view_still: fn(_) { b"" },
    save_file: fn(_, _) { false },
    word_at: fn(_, _) { (-1, -1) },
    open_url: fn(_) { false },
    over_done: fn(_) { () },
    open_tab: fn(_) { false },
    hold_words: fn(_, _, _) { () },
    post_take: fn() { 0 },
    post_next: fn() { None },
    ref_begin: fn(_, _, _, _) { () },
    ref_text: fn(_, _, _, _, _, _, _, _) { () },
    ref_end: fn(_) { false },
    ref_frame: fn(_) { false },
    bl_start: fn(_, _) { 0 },
    bl_port: fn(_) { 0 },
    bl_open: fn(_, _) { 0 },
    bl_back: fn(_) { "" },
    bl_end: fn(_) { () },
    pw_able: fn() { false },
    pw_run: fn(_) { 0 },
    pw_out: fn(_) { "" },
    pw_end: fn(_) { () },
    af_able: fn() { false },
    af_ask: fn(_) { 0 },
    af_take: fn() { "" },
    af_end: fn() { () },
    wa_able: fn() { false },
    wa_get: fn(_) { 0 },
    wa_out: fn(_) { "" },
    wa_end: fn(_) { () },
    pk_start: fn(_) { 0 },
    pk_state: fn(_) { 0 },
    pk_count: fn(_) { 0 },
    pk_name: fn(_, _) { "" },
    pk_bytes: fn(_, _) { b"" },
    pk_info: fn(_, _) { "" },
    pk_end: fn(_) { () },
    kp_begin: fn(_, _, _) { 0 },
    kp_append: fn(_, _) { 0 },
    kp_finish: fn(_) { () },
    kp_state: fn(_) { 0 },
    kp_where: fn(_) { "" },
    kp_end: fn(_) { () },
    ga_access: fn() { 0 },
    ga_ask: fn() { () },
    ga_answers: fn() { 0 },
    ga_read: fn() { 0 },
    ga_read_state: fn(_) { 0 },
    ga_read_rows: fn(_) { "" },
    ga_read_end: fn(_) { () },
    pk_photo: fn(_) { 0 },
    cs_known: fn(_) { 0 },
    cs_decode: fn(_, _) { "" },
    mk_start: fn(_, _) { 0 },
    mk_state: fn(_) { 0 },
    mk_png: fn(_) { b"" },
    nt_show: fn(_, _, _, _, _) { () },
    rn_dirty: fn(_, _, _, _) { () },
    rn_glass_light_angle: fn(_) { () },
    nv_bar: fn(_) { 0 },
    nv_able: fn() { false },
    nt_cancel: fn(_) { () },
    nt_state: fn(_) { 0 },
    nt_text: fn(_) { "" },
    st_audio_here: fn() { 0 },
    st_audio: fn(_, _) { () },
    st_audio_played: fn(_) { 0.0 },
    st_audio_queued: fn(_) { 0.0 },
    st_audio_wanted: fn(_) { 0.0 },
    st_audio_volume: fn(_, _) { () },
    st_frame_shown: None,
    st_flush: fn(_, _) { () },
    st_layers: fn() { 0 },
    st_pointer: fn(_, _, _, _, _, _) { () },
    st_pointer_named: None,
    st_pointer_at: fn(_, _, _, _) { () },
    st_direct: fn(_, _, _, _) { () },
    st_h265_here: fn() { 0 },
    st_hevc: fn(_, _, _, _) { () },
    st_av1_here: fn() { 0 },
    st_av1: fn(_, _, _, _) { () },
    st_open: fn() { 0 },
    st_h264: fn(_, _, _, _) { () },
    st_frame: fn(_, _, _, _) { () },
    st_jpeg: fn(_, _, _) { () },
    st_next: fn(_) { "" },
    st_show: fn(_, _) { () },
    st_close: fn(_) { () },
    st_h264_here: fn() { 0 },
    st_feeds: fn() { 0 },
    st_codec: fn(_, _, _) { () },
    cl_read: fn() { 0 },
    cl_state: fn(_) { 0 },
    cl_picture: fn(_) { 0 },
    tm_open: fn(_, _) { 0 },
    tm_write: fn(_, _) { () },
    tm_resize: fn(_, _, _, _, _) { () },
    tm_frame: fn(_, _) { b"" },
    tm_modes: fn(_) { 0 },
    tm_scroll: fn(_, _, _) { () },
    tm_select: fn(_, _, _, _, _, _) { 0 },
    tm_text: fn(_, _) { "" },
    tm_mouse: fn(_, _, _, _, _, _, _, _, _, _) { b"" },
    tm_close: fn(_) { () },
    cl_text: fn(_) { "" },
    cl_png: fn(_) { b"" },
    cl_files: fn(_) { 0 },
    cl_file_name: fn(_, _) { "" },
    cl_file: fn(_, _) { b"" },
    cl_end: fn(_) { () },
    cl_set: fn(_, _, _) { () },
    dv_copy_shown: fn() { 0 },
    dv_key_catch: fn(_) { () },
    dv_ime_inset: fn() { 0.0 },
    dv_keep_awake: fn(_) { () },
    dv_haptic: fn(_) { () },
    dv_ime_action: fn(_) { () },
    dv_ime_let_go: fn() { () },
    ncall_call: fn(_, _) { 0 },
    ncall_state: fn(_) { 0 },
    ncall_result: fn(_) { "" },
    ncall_end: fn(_) { () },
    words_spaced: None,
    window_set_title: fn(_, _) { () },
    auto_launch: fn() { false },
    set_auto_launch: fn(_) { false },
    hotkey_set: fn(_, _) { false },
    hotkey_clear: fn(_) { () },
    pointer_lock: fn(_) { () },
    pointer_locked: fn() { false },
    pointer_delta: fn(_) { () },
    gamepads: fn(_) { 0 },
    glyphs_ahead_able: fn() { false },
    has_local_fonts: fn() { false },
    face_set_ligatures: fn(_, _) { () },
    set_host_autospace: fn(_) { () },
    local_font_info: fn() { "" },
    has_async_local_font_info: fn() { true },
  }
}

///|
pub fn Host::window_corner_at(self : Host, k : Int) -> Double {
  match self.window_corner_at {
    Some(f) => f(k)
    None => (self.window_corner)()
  }
}

///|
pub fn Host::clock_at_wall(self : Host, ms : Double) -> Double {
  match self.clock_at_wall {
    Some(f) => f(ms)
    None => ms - ((self.wall_ms)() - (self.now)())
  }
}

///|
pub fn Host::request_frame_on(self : Host) -> Unit {
  match self.request_frame_on {
    Some(f) => f()
    None => (self.request_frame)()
  }
}

///|
pub fn Host::frames_paced(self : Host, hz : Double) -> Unit {
  match self.frames_paced {
    Some(f) => f(hz)
    None => self.request_frame_on()
  }
}

///|
pub fn Host::words_spaced(self : Host) -> Int {
  match self.words_spaced {
    Some(f) => f()
    None => words_spaced_of(self)
  }
}

///|
pub fn Host::clipboard_set_html(self : Host, text : String, html : String) -> Unit {
  match self.clipboard_set_html {
    Some(f) => f(text, html)
    None => (self.clipboard_set)(text)
  }
}

///|
pub fn Host::lines_on_pixels(self : Host) -> Bool {
  match self.lines_on_pixels {
    Some(f) => f()
    None => {
      let o = FixedArray::make(6, -1.0)
      (self.font_metrics)(15.0, 400, 0, o)
      o[5] == 1.0
    }
  }
}

///|
pub fn Host::st_frame_shown(self : Host, id : Int, data : Bytes, key : Int, ts : Double, show : Int) -> Int {
  match self.st_frame_shown {
    Some(f) => f(id, data, key, ts, show)
    None =>
      if show != 0 {
        (self.st_frame)(id, data, key, ts)
        1
      } else {
        0
      }
  }
}

///|
pub fn Host::st_pointer_named(
  self : Host,
  id : Int,
  key : String,
  png : () -> Bytes,
  w : Double,
  h : Double,
  hx : Double,
  hy : Double,
) -> Unit {
  match self.st_pointer_named {
    Some(f) => f(id, key, png, w, h, hx, hy)
    None => (self.st_pointer)(id, png(), w, h, hx, hy)
  }
}

///|
// set as the program starts (mbui/host's init), or by a Tester for its test
let current : Ref[Host] = { val: Host::noop() }

///|
/// Who answers from now on: the platform's (mbui/host's init, as the program starts), a Tester's fake.
pub fn set_host(h : Host) -> Unit {
  current.val = h
  sideways_now.set(false)
  turnable_now.set(false)
  // (a new host has been handed nothing)
  nav_said.val = None
}

///|
/// Who answers now: the platform's in a program with mbui/host, asked before a Tester gives its fake (a film's,
/// ui/src/film: its text and pictures the platform's, Tester::new's `live`).
pub fn host() -> Host {
  current.val
}

///|
/// The desktop's window as the app wants it, said before `run`: its first size (`w` by `h`; MBUI_WIN=<w>x<h> still
/// has the last word) and its least (`min_w` by `min_h`), and with `inset` no title bar of the system's: the app's own
/// top row is it (macOS: the window's buttons in it, 16 in and centred on its first 44; the app drags the window by
/// it, Ctx::window_drag). Nothing where there is no window to size (iOS, Android, a browser's page).
pub fn window_setup(min_w : Double, min_h : Double, w : Double, h : Double, inset? : Bool = false) -> Unit {
  (current.val.window_setup)(min_w, min_h, w, h, inset)
}

///|
/// The desktop's window kept out of sight as it opens, till the app shows it (window_show), said before `run`: its
/// frames drawn meanwhile, it comes up with what the app has drawn by then, not its ground before that. Nothing where
/// the system shows the app's window itself (iOS, Android, a browser's page). Each desktop's host keeps its own way
/// (the Mac's see-through, Windows' cloaked by its compositor, Linux's made and not shown till then).
pub fn window_hold() -> Unit {
  (current.val.window_hold)()
}

///|
/// The window held (window_hold) shown now; nothing once it is.
pub fn window_show() -> Unit {
  (current.val.window_show)()
}

///|
/// Whether the window's buttons are in the app's top row now (an inset window, not full screen): the room the app
/// leaves them there.
pub fn window_inset() -> Bool {
  (current.val.window_inset)()
}

///|
/// The window's buttons in the app's top row (window_inset) moved to `by` lower than centred on its first 44, where the
/// app's top row starts that much under the window's top (macOS's; a panel inset from the window's edges): from where
/// they are, over `ms` on a Move's way (Ease::Move), at once where the window is not seen yet. Nothing where the system
/// has no such buttons there.
pub fn window_buttons_down(by : Double, ms : Double) -> Unit {
  (current.val.window_buttons_down)(by, ms)
}

///|
/// Whether the desktop's window fills the screen now (macOS's full screen). False where there is no such window.
pub fn full_screen() -> Bool {
  (current.val.full_screen)()
}

///|
/// The desktop's window made to fill the screen, or back as it was (macOS's full screen, as its green button does).
/// Nothing where there is no window to size.
pub fn set_full_screen(on : Bool) -> Unit {
  (current.val.set_full_screen)(on)
}

///|
/// Draw content at this many window points per content point; it takes effect on the next frame.
pub fn set_window_zoom(zoom : Double) -> Unit {
  (current.val.set_window_zoom)(zoom)
}

///|
/// An app's window-wide key, offered before an embedded native page takes it; nonzero when the app took it.
pub fn set_window_key(f : FuncRef[(Int, Int) -> Int]) -> Unit {
  (current.val.set_window_key)(f)
}

///|
/// Whether the wheel just handed in (a pinch, or with ⌃ held) zoomed something of the app's (a picture, a remote
/// screen): said as the wheel is handled. A browser's page leaves one the app kept nothing of to the browser, which
/// zooms the page by it.
pub fn wheel_kept(kept : Bool) -> Unit {
  (current.val.wheel_kept)(kept)
}

///|
/// How round the system draws the window's corners now, in points: the outermost corner of all, what lies in it
/// concentric with it as with any container's (@ui's corners.mbt). 0 where they are square (filling the screen,
/// maximised, a browser's page, Windows 10) or where the system says nothing of them.
pub fn window_corner() -> Double {
  (current.val.window_corner)()
}

///|
/// How round the system draws the window's corner `k` (0 top left, then round it): each its own where they differ (an
/// iPhone Duo's outer screen: the two along its hinge 8, the others 59), window_corner the roundest of them.
pub fn window_corner_at(k : Int) -> Double {
  current.val.window_corner_at(k)
}

///|
/// The press under way moves the window (a press on the app's own top row, @ui's Ctx::window_drag): the host's from
/// here, as its title bar's would be.
pub fn window_drag() -> Unit {
  (current.val.window_drag)()
}

///|
/// What the window's own buttons do, asked by the app where it draws them (a window whose top row is the app's and
/// whose system draws no buttons in it: Windows'): 1 minimized, 2 maximized or back as it was, 3 closed (as its close
/// button closes it). Nothing where there is no such window.
pub fn window_act(what : Int) -> Unit {
  (current.val.window_act)(what)
}

///|
/// Whether the window is maximized now (Windows: what its maximize button brings back as it was). False where there
/// is no such window.
pub fn window_zoomed() -> Bool {
  (current.val.window_zoomed)()
}

///|
/// Where the app draws the window's maximize button this frame, in points in the window (w 0: none): the host's there,
/// as its title bar's own (Windows: hit as its maximize button, so the system's Snap Layouts open from it as the
/// pointer rests on it; the press on it the host's, which maximizes the window or brings it back). The pointer there is
/// the host's, not the app's: window_snap_state says how it stands. Nothing where there is no such window.
pub fn window_snap(x : Double, y : Double, w : Double, h : Double) -> Unit {
  (current.val.window_snap)(x, y, w, h)
}

///|
/// How the pointer stands on the window's maximize button the app draws (window_snap): 0 not on it, 1 on it, 2
/// pressing it. The app is drawn again as it changes.
pub fn window_snap_state() -> Int {
  (current.val.window_snap_state)()
}

///|
/// Whether the app can open a window of its own beside this one (window_open): a desktop's (macOS, Windows, Linux);
/// false on a phone, a tablet and the web.
pub fn window_opens() -> Bool {
  (current.val.window_opens)()
}

///|
/// Another window of the app opened beside this one, for `what` (the app's words for what it shows there): another run
/// of the same program, as the system starts it, with MBUI_WINDOW=`what` in its environment; it runs once, as many
/// times as asked (not handed to the one running, as the app started again is), and ends as its window closes or as
/// this run ends, however it ends. Whether it was started (false where window_opens is not).
pub fn window_open(what : String) -> Bool {
  (current.val.window_open)(what)
}

///|
/// The window this run opened for exactly `what` (window_open) brought to the front, out of the Dock or the taskbar
/// where it was minimized: whether there is one still open (false once it has closed, and where window_opens is not).
pub fn window_front(what : String) -> Bool {
  (current.val.window_front)(what)
}

///|
/// Whether a window of the app's own opens in this run, beside its first (window_open_id), rather than as another run
/// of the program (window_open): one app, one process, every window drawn by the same program and the same core. A
/// host that has not that (a phone's, the web's), or a run that is itself a window of its own (MBUI_WINDOW), says
/// false, and window_open is still its way.
pub fn windows_in_process() -> Bool {
  (current.val.windows_in_process)()
}

///|
/// Another window of this run, for `what`: its id (1 and up, the first window being 0), 0 where none opened. The app
/// is asked to draw it as it draws its first (@ui's window_slots.mbt: each window its own tree, the same program).
pub fn window_open_id(what : String) -> Int {
  (current.val.window_open_id)(what)
}

///|
/// Window `wid` of this run (window_open_id) out of the Dock where it was minimized and to the front: whether it is
/// still open.
pub fn window_front_id(wid : Int) -> Bool {
  (current.val.window_front_id)(wid)
}

///|
/// Window `wid` of this run closed (never the first, 0, nor the run): what it showed let go of as the host tells it
/// closed (an outside event, @ui's window_slots.mbt).
pub fn window_close_id(wid : Int) -> Unit {
  (current.val.window_close_id)(wid)
}

///|
/// The window of this run the host is drawing a frame of or handing input from now (0, the first, between them).
pub fn window_current() -> Int {
  (current.val.window_current)()
}

///|
/// The title the system shows for window `wid` of this run (0 the first; its title bar, the Dock's and the switcher's
/// list), from now on. Nothing where the host has no title of a window.
pub fn window_set_title(wid : Int, title : String) -> Unit {
  (current.val.window_set_title)(wid, title)
}

///|
/// The pointer's shape from now on: 0 the arrow, 1 a hand, 2 the text's I-beam, 3 resizing sideways, 4 up and down,
/// 5 an open hand, 6 a closed hand, 7 a crosshair, 8 what cannot be done, 9 resizing from a top left or bottom right
/// corner, 10 from a top right or bottom left one. Nothing where there is no pointer.
pub fn set_cursor(kind : Int) -> Unit {
  (current.val.set_cursor)(kind)
}

///|
/// The number on the app's icon (macOS's Dock tile: what waits for the person); 0 none. Nothing where the system
/// shows none.
pub fn set_badge(n : Int) -> Unit {
  (current.val.set_badge)(n)
}

///|
/// The app's menus in the system's menu bar (macOS's), as JSON: an array of menus, each
/// `{"title": …, "items": [item, …]}` (the first the app's own, its title the system's), an item
/// `{"title": …, "role": …}` the system's own (`about`, `hide`, `hideOthers`, `showAll`, `quit`, `undo`, `redo`,
/// `cut`, `copy`, `paste`, `selectAll`, `services`, `close`, `minimize`, `zoom`, `fullScreen`, `front`: their keys
/// the system's),
/// `{"title": …, "action": …, "keys"?: "Mod+Shift+H", "enabled"?: false}` the app's (chosen, said on `system_channel` as
/// `{"menu": action}`; its keys shown, the app's to take), or `{"separator": true}`; a menu `"role": "window"` is the
/// system's list of windows too, `"role": "actions"` one of the app's actions only (their keys never taken by the
/// menu), `"role": "tray"` the menu of the app's icon in Windows' notification area and among a Linux desktop's apps'
/// icons (no menu bar's: its items' roles `show`, the window brought back, and `quit`; the Mac leaves it out). Given
/// again as what it shows changes. Nothing where the system has no menu bar nor such an icon.
pub fn menu_setup(json : String) -> Unit {
  (current.val.menu_setup)(json)
}

///|
/// What the app's own native code says of `name` (the app's, not mbui's: an app hands its host its own calls as it
/// starts, `mb_host_app_calls` in `src/host/app_calls.h`), as text the app reads (JSON by its own convention); "" where
/// the app gave none or says nothing of it. Under a Tester: as it is set (Tester::set_app_said).
pub fn app_said(name : String) -> String {
  (current.val.app_said)(name)
}

///|
/// Something the app asks its own native code to do (`name`, with `arg`): the app's call, as `app_said`. Nothing where
/// the app gave none. Under a Tester: kept (Tester::app_told).
pub fn app_tell(name : String, arg : String) -> Unit {
  (current.val.app_tell)(name, arg)
}

///|
/// The name the app's native views are served under, said once as it starts, before it opens one (`mbui` till then):
/// a site's own scheme `<name>-preview` (Apple's, Linux's) or host `preview.<name>.invalid` (Windows', Android's), a
/// page's `page.<name>.invalid`, a player's `player.<name>.invalid`, and the messages a site's frame and its host trade
/// in a browser, `<name>-preview-…`. Where a site keeps what it keeps (its storage, by its origin), so an app keeps it.
pub fn set_site_name(name : String) -> Unit {
  (current.val.set_site_name)(name)
}

///|
/// The keys held down now that change what a press or a drag does (shift 1, control 2, option/alt 4, command 8: as a
/// key's own modifiers are told): what a drag let go does by them (Finder's ⌥ a copy). None where there is no keyboard.
pub fn mods_held() -> Int {
  (current.val.mods_held)()
}

///|
pub fn run(
  title : String,
  frame : FuncRef[(Double, Double, Double, Double) -> Unit],
  pointer : FuncRef[(Int, Double, Double, Int) -> Unit],
  wheel : FuncRef[(Double, Double, Double, Double, Int) -> Unit],
  key : FuncRef[(Int, Int) -> Unit],
  text : FuncRef[(Int, String, Int, Int) -> Unit],
) -> Unit {
  (current.val.run)(title, frame, pointer, wheel, key, text)
}

///|
pub fn now() -> Double {
  (current.val.now)()
}

///|
/// The time of day, in ms since 1970 (UTC), as the machine's clock has it: for what is shown of it only (@ui.wall_ms).
/// A run to a declared moment (a scripted shot) has its own: from a fixed day, on with its frames' clock.
pub fn wall_ms() -> Double {
  (current.val.wall_ms)()
}

///|
/// The moment on now()'s clock the time of day is `ms` (as wall_ms has it): how far the day is ahead of the clock
/// taken from it. A run on a clock of its own (a scripted shot, a Tester's) has its day at its clock's 0 taken from it,
/// as it is.
pub fn clock_at_wall(ms : Double) -> Double {
  current.val.clock_at_wall(ms)
}

///|
/// What the pointer's event being delivered came from, where one machine has both: 1 a finger on the screen, 0 a
/// mouse, a trackpad or a pen (Windows: a touch screen beside a mouse); -1 where the host does not say (its system's
/// hand: Android's and iOS's fingers, a Mac's pointer).
pub fn event_finger() -> Int {
  (current.val.event_finger)()
}

///|
/// How far the machine's local time is ahead of UTC at `at_ms` (ms since 1970), in minutes (its zone and summer time):
/// for a date or a time of day shown only. A run to a declared moment (a scripted shot) has 0, as its wall_ms is its own.
pub fn utc_offset_min(at_ms : Double) -> Int {
  (current.val.utc_offset_min)(at_ms)
}

///|
/// When the input event being delivered happened, on now()'s clock (ms):
/// a touch's own time, which comes before it is handled (a frame's touches
/// are handled together); negative when the host doesn't say.
pub fn event_time() -> Double {
  (current.val.event_time)()
}

///|
/// How much later than its time (the moment it was drawn for: the frame's `t`) the frame before this one reached the
/// screen, in ms: 0 on time, as a host says where it cannot tell (a Tester's, a browser's), and where frames are not
/// drawn one after the other (the first after a pause).
pub fn frame_late() -> Double {
  (current.val.frame_late)()
}

///|
/// The system: 0 macOS, 1 iOS, 2 Android, 3 Windows, 4 a browser, 5 Linux.
pub fn platform() -> Int {
  (current.val.platform)()
}

///|
pub fn request_frame() -> Unit {
  (current.val.request_frame)()
}

///|
/// A frame asked for what moves on by the clock (a motion going on, a cycle shown), not for what changed: a host's
/// next display frame, as request_frame; a run whose time goes by as it says (a Tester's) owes none at this moment.
pub fn request_frame_on() -> Unit {
  current.val.request_frame_on()
}

///|
/// A frame asked for what moves on by the clock (as request_frame_on, in the frame that asks) that needs only `hz`
/// frames a second: drawn at the display's frame about `1000 / hz` ms after this one's, those between drawing nothing,
/// and the display told it may refresh that slowly meanwhile (iOS's and macOS's CADisplayLink preferredFrameRateRange,
/// Android's Surface.setFrameRate); anything asking for a frame before then (request_frame: an input, a change) has
/// the display's next and every frame again. A host with nothing for it draws the display's next (request_frame_on).
pub fn frames_paced(hz : Double) -> Unit {
  current.val.frames_paced(hz)
}

///|
pub fn wake_after(ms : Double) -> Unit {
  (current.val.wake_after)(ms)
}

///|
/// Ascent, descent and line height of the system font (or its code face,
/// `style` & style_mono; slanted with style_italic) at this size and weight,
/// then the ascent and descent of the font a Han ideograph falls back to, then
/// 1 where the host sets lines of words on whole device pixels (Android), 0
/// where not (six numbers in `out`).
pub fn font_metrics(
  size : Double,
  weight : Int,
  style : Int,
  out : FixedArray[Double],
) -> Unit {
  (current.val.font_metrics)(size, weight, style, out)
}

///|
/// `text` shaped in that font into grapheme clusters: four numbers each
/// (start, length, advance, glyph key; -1 for none) in `out`; returns how
/// many.
pub fn shape(
  text : String,
  size : Double,
  weight : Int,
  style : Int,
  out : FixedArray[Double],
) -> Int {
  (current.val.shape)(text, size, weight, style, out)
}

///|
/// The glyph key of `text` drawn whole as one piece (the way the platform draws it in a line: a word whose letters
/// join), for `glyph`.
pub fn text_key(text : String, size : Double, weight : Int, style : Int) -> Int {
  (current.val.text_key)(text, size, weight, style)
}

///|
/// words_spaced: the host's shaper spaces nothing, mbui does (ui's text.mbt `words_spaced_in`).
pub let words_spaced_here : Int = 0

///|
/// words_spaced: the host's shaper spaces Chinese and Japanese words itself (Core Text since iOS 26 and macOS 27).
pub let words_spaced_by_host : Int = 1

///|
/// words_spaced: nothing spaced, by the host or by mbui (MBUI_AUTOSPACE=off: a picture of words set as a shaper that
/// spaces none sets them, Android's).
pub let words_spaced_none : Int = 2

///|
/// Who spaces Chinese and Japanese words (an eighth of an em between a Han character or kana and a Latin letter or a
/// digit; a full-width mark set a half em closer before another): one of words_spaced_here, words_spaced_by_host,
/// words_spaced_none. Asked once a run: a host found to space them by its own shapes, where a Latin letter after a Han
/// character comes out wider than on its own; MBUI_AUTOSPACE=off for none (and for the Apple hosts =off or =mbui
/// their shaper's own left out: apple_text.m's make_line).
pub fn words_spaced() -> Int {
  current.val.words_spaced()
}

///|
/// Glyph `key` (a cluster `shape` or `text_key` gave) drawn, its picture held for `glyph_put`: in `out` 0 and 0 (where
/// it goes in the atlas is the caller's: atlas.mbt), its picture's width and height in points (its pixels at the
/// host's scale; 0: nothing to draw), where its top left is from the pen on the baseline, and 1 where it is in colours
/// of its own (an emoji), else 0. Drawn again each time it is asked for: the caller asks for what its atlas lacks.
pub fn glyph(key : Int, out : FixedArray[Double]) -> Unit {
  (current.val.glyph)(key, out)
}

///|
/// The picture of glyph `key`, drawn by the `glyph` asked last, put in its atlas with its top left at pixel `x`, `y`
/// (there before the next frame is drawn), over whatever was there: in colour glyphs' own atlas (where the host has
/// one) `x` is `colour_atlas_u` past its place across in it, as its instances say it.
pub fn glyph_put(key : Int, x : Int, y : Int) -> Unit {
  (current.val.glyph_put)(key, x, y)
}

///|
/// The side of the host's atlas the glyphs of its words are drawn from, in pixels, or (`colour`) of colour glyphs'
/// own (an emoji's: 0, they are in the words' atlas with the others); 0: none.
pub fn atlas_size(colour : Bool) -> Int {
  (current.val.atlas_size)(colour)
}

///|
/// How far across past its place in it a glyph in colour glyphs' own atlas is said, to the host (glyph_put) and in its
/// instances (scene.mbt: its renderer takes the atlas by it).
pub let colour_atlas_u : Int = 16384

///|
/// The glyphs of the first `n` of `keys`, shaped and not drawn yet (on a page still off the screen, or below what is
/// shown), for the host to draw ahead, off the frames' thread, so that `glyph` finds them drawn when they come into
/// view. What `glyph` answers is the same either way: only when the work is done changes. A host may do nothing.
pub fn glyphs_ahead(keys : FixedArray[Int], n : Int) -> Unit {
  (current.val.glyphs_ahead)(keys, n)
}

///|
/// Whether the current host supports drawing glyphs ahead off the frames' thread (`glyphs_ahead`).
pub fn glyphs_ahead_able() -> Bool {
  (current.val.glyphs_ahead_able)()
}

///|
/// The picture of glyph `key` drawn by the `glyph` asked last, as `glyph_put` would put it in the atlas, its pixels into
/// `out` (its width by its height at the host's scale, as `glyph` says them; RGBA premultiplied, rows from the top: a
/// mask's colour as its cover): what words' halo is blurred from (mbui/ui's halo.mbt). False where the host holds none
/// or gives none back (no halo drawn then).
pub fn glyph_picture(key : Int, out : FixedArray[Byte]) -> Bool {
  (current.val.glyph_picture)(key, out)
}

///|
/// Pixels made by the caller (`w` by `h`, RGBA premultiplied, rows from the top) put in the words' atlas with their top
/// left at pixel `x`, `y`, as `glyph_put` puts a glyph's (there before the next frame is drawn): a halo blurred from
/// glyphs (mbui/ui's halo.mbt). False where the host takes none (nothing put).
pub fn atlas_put(x : Int, y : Int, w : Int, h : Int, px : FixedArray[Byte]) -> Bool {
  (current.val.atlas_put)(x, y, w, h, px)
}

///|
/// A font file (TrueType or OpenType, at `path`) made part of face `face` (style.mbt: face_ui, face_text, face_code,
/// or 4 to 15 for what names it), for `weight` (0: a variable file, every weight from it). False when the host could
/// not read it as a font (the face as it was). What was shaped or drawn before is the host's to forget
/// (atlas_generation moves on).
/// Face `face` set in a family installed on this machine (`family`, as local_font_families names it): its every style
/// the system's. False where the host has none of that name (or no way to it).
pub fn face_add_family(face : Int, family : String) -> Bool {
  (current.val.face_add_family)(face, family)
}

///|
/// Cheap capability check for whether this host can enumerate locally installed font families without triggering a
/// synchronous scan.
pub fn has_local_fonts() -> Bool {
  (current.val.has_local_fonts)()
}

///|
/// The font families installed on this machine, as a JSON array of their names, in the order of the user's
/// language (the system's hidden ones left out); "" where the host has no way to them (a phone, a browser).
pub fn local_font_families() -> String {
  (current.val.local_font_families)()
}

///|
pub fn face_add(face : Int, path : String, weight : Int) -> Bool {
  (current.val.face_add)(face, path, weight)
}

///|
/// As face_add, the font's file being `data` (one the app carries in itself, or has fetched and kept).
pub fn face_add_bytes(face : Int, data : Bytes, weight : Int) -> Bool {
  (current.val.face_add_bytes)(face, data, weight)
}

///|
/// Face `face` given up: what was in it is in the system's face again.
pub fn face_clear(face : Int) -> Unit {
  (current.val.face_clear)(face)
}

///|
/// Whether programming / contextual ligatures (calt, liga, clig) are enabled for face `face`.
pub fn face_set_ligatures(face : Int, on : Bool) -> Unit {
  (current.val.face_set_ligatures)(face, on)
}

///|
/// Whether the host's own CJK/Latin autospace is enabled (e.g. Core Text on macOS/iOS; env MBUI_AUTOSPACE takes priority).
pub fn set_host_autospace(on : Bool) -> Unit {
  (current.val.set_host_autospace)(on)
}

///|
/// Metadata for locally installed font families as a JSON array (name, localized, mono, serif, cjk); "" if unavailable
/// or still scanning in the background.
pub fn local_font_info() -> String {
  (current.val.local_font_info)()
}

///|
/// Whether the host scans `local_font_info()` asynchronously in the background (true on real desktop hosts; false on
/// test hosts that only populate `local_font_families()`).
pub fn has_async_local_font_info() -> Bool {
  (current.val.has_async_local_font_info)()
}

///|
/// Moves on as what the host drew and measured before is gone: its faces or its scale changed, its atlas lost (a new
/// drawing surface). Never as its atlas fills: what goes where in it is the caller's (atlas.mbt).
pub fn atlas_generation() -> Int {
  (current.val.atlas_generation)()
}

///|
pub fn present(
  buf : FixedArray[Double],
  count : Int,
  r : Double,
  g : Double,
  b : Double,
) -> Unit {
  (current.val.present)(buf, count, r, g, b)
}

///|
/// Whether the host keeps groups of instances (group_set) and draws a header of one among a frame's in its place
/// (kind 13, ui/src/ui/scene.mbt): a row of a list kept, moved, drawn by its header alone.
pub fn groups_here() -> Bool {
  (current.val.groups_here)()
}

///|
/// Group `id` kept by the host: `n` instances (`inst`, as `present` takes them), and which of each one's numbers a
/// header moves with it (`moves`, one each: bits 0-3 its clip's 16-19, 4-7 its outer's 40-43, 8 its turn's point
/// 33-34; its rect's 0-1 always, a shape's band's first piece 12 by the header's 15). A number is never another
/// group's.
pub fn group_set(id : Int, inst : FixedArray[Double], moves : FixedArray[Double], n : Int) -> Unit {
  (current.val.group_set)(id, inst, moves, n)
}

///|
/// Group `id` let go: no frame presented from here on has a header of it.
pub fn group_drop(id : Int) -> Unit {
  (current.val.group_drop)(id)
}

///|
pub fn set_ime(
  active : Bool,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  text : String,
  sel_start : Int,
  sel_end : Int,
) -> Unit {
  (current.val.set_ime)(active, x, y, w, h, text, sel_start, sel_end)
}

///|
/// What a field's selected words can have done to them: cut, copy, paste, select all (text_menu's `can`).
pub let text_menu_cut : Int = 1

///|
pub let text_menu_copy : Int = 2

///|
pub let text_menu_paste : Int = 4

///|
pub let text_menu_select_all : Int = 8

///|
/// What a field has to undo and to do again (edit_can's `can`, beside the four above).
pub let text_menu_undo : Int = 16

///|
pub let text_menu_redo : Int = 32

///|
/// The app's own items (text_menu's `can`): those text_menu_own last said, in its order, after the system's; the k-th
/// chosen comes as the key key_menu_own + k, the menu then gone.
pub let text_menu_own_item : Int = 64

///|
/// The key the app's own first item of the floating text menu comes as, chosen (text_menu_own_item): the k-th
/// key_menu_own + k, as many as text_menu_own_most.
pub let key_menu_own : Int = 60

///|
/// How many items of its own the app offers in the floating text menu at most (text_menu_own: the rest left out).
pub let text_menu_own_most : Int = 8

///|
/// The system's floating menu for a field's words (Android's text toolbar: ActionMode.TYPE_FLOATING) `shown` over the
/// window's rectangle (`x`, `y`, `w`, `h`: the words picked, or the caret), offering what `can` says (text_menu_*); or
/// put away. What is chosen comes as the keys and the paste the field already takes (select all, copy, cut: keys 12,
/// 13, 14; paste: the clipboard's words as text), the menu then gone. A host with none shows nothing.
pub fn text_menu(shown : Bool, x : Double, y : Double, w : Double, h : Double, can : Int) -> Unit {
  (current.val.text_menu)(shown, x, y, w, h, can)
}

///|
/// The words of the app's own items of the floating text menu, a line each in their order (a chat's 引用, 分享这一轮,
/// 复制链接 of a message's words a finger picked; text_menu_own_most at most), offered where text_menu's `can` has
/// text_menu_own_item, after the system's items; said before the menu that offers them, again as they change. The k-th
/// chosen comes as the key key_menu_own + k, the menu then gone. Android's text toolbar (its overflow where they do
/// not fit) and iOS's edit menu offer them, the web's bar too; a host with no floating menu nothing.
pub fn text_menu_own(words : String) -> Unit {
  (current.val.text_menu_own)(words)
}

///|
/// What the menu bar's editing items (a Mac's 编辑: 撤销, 重做, 剪切, 拷贝, 粘贴, 全选) can do now, said as it changes:
/// text_menu_* (text_menu_undo, text_menu_redo with them) for the field with the focus, or copy for the words picked
/// with the pointer where no field has it; an item it does not say is greyed, as the system's fields have theirs. A
/// host with no menu bar does nothing with it.
pub fn edit_can(can : Int) -> Unit {
  (current.val.edit_can)(can)
}

///|
pub fn clipboard_set(s : String) -> Unit {
  (current.val.clipboard_set)(s)
}

///|
/// Words on the system's clipboard as `text` and, for what pastes them with their shape (a document, a mail, a
/// page), as `html` (a fragment: lists, headings, code): Windows' "HTML Format", a Mac's public.html. A host that puts
/// no HTML there puts the words alone, as clipboard_set.
pub fn clipboard_set_html(text : String, html : String) -> Unit {
  current.val.clipboard_set_html(text, html)
}

///|
/// A secret put on the system's clipboard: marked sensitive where the system masks such (Android 13 on), kept out of
/// the clipboard's history and the cloud's where it keeps them (Windows), kept to this device (iOS, which takes it off
/// itself `clear_ms` later). Elsewhere as clipboard_set. The app takes it off `clear_ms` later on its own clock
/// (Ctx::copy_secret: clipboard_secret_off).
pub fn clipboard_set_secret(s : String, clear_ms~ : Double) -> Unit {
  (current.val.clipboard_set_secret)(s, clear_ms)
}

///|
/// The last secret put on the clipboard (clipboard_set_secret) taken off, unless something else was copied since
/// (the app's or another's: the system says whether the clipboard changed). As the app ends before then, a desktop
/// host takes it off itself (Windows).
pub fn clipboard_secret_off() -> Unit {
  (current.val.clipboard_secret_off)()
}

///|
/// A picture put on the system's clipboard (an image file's bytes: PNG, JPEG…), as a picture other apps paste. A host
/// with no such clipboard (a browser's page, Android) puts nothing.
pub fn clipboard_set_image(data : Bytes) -> Unit {
  (current.val.clipboard_set_image)(data)
}

///|
pub fn log(s : String) -> Unit {
  (current.val.log)(s)
}

///|
pub fn bench_mode() -> Int {
  (current.val.bench_mode)()
}

///|
/// Who is told as what the host does for the app is done (`f(kind, id, state)`: kind 1 an image or a PDF's page
/// decoded, 2 a native view ready — a page loaded and its picture taken, a video's first frame —; state 1 done, -1
/// failed), on the main thread, between frames. False where the host sends no such events.
pub fn set_outside(f : FuncRef[(Int, Int, Int) -> Unit]) -> Bool {
  (current.val.set_outside)(f)
}

///|
/// Whether what the host does for the app of `kind` (as set_outside numbers them) is done by the next frame, told by
/// no event: what waits on it reads it again at each frame while it waits. False where the host tells each as it is
/// done (set_outside).
pub fn answers_by_frame(kind : Int) -> Bool {
  (current.val.answers_by_frame)(kind)
}

///|
/// Whether the host draws each glyph on its device's pixels, a list's rows set on them as it moves (@ui's
/// rows_on_grid): every platform's does.
pub fn rows_on_pixels() -> Bool {
  (current.val.rows_on_pixels)()
}

///|
/// Whether the window's tree keeps where in the source each node was made and its properties said (view's source.mbt):
/// a Tester's fake host does, for what it finds to say where to change it; a device's does not, its calls only passing
/// their places on.
pub fn keeps_sources() -> Bool {
  (current.val.keeps_sources)()
}

///|
/// Whether the host sets things on whole device pixels, its lengths as its lines (Android's: Compose rounds each
/// length to pixels, StaticLayout each line), as it says of its fonts (font_metrics' sixth number).
pub fn lines_on_pixels() -> Bool {
  current.val.lines_on_pixels()
}

///|
/// A scripted run's step only a host can carry out (@ui's drive: what the system says on its channel `system`, what a
/// native view's host says `viewsaid`, the keyboard's height `ime`, the pickers' answers `picks`), `arg` as the script
/// says it: "" done, else why not.
pub fn script_step(step : String, arg : String) -> String {
  (current.val.script_step)(step, arg)
}

///|
/// As the frame just built left it: how many of the app's asks the host has not answered yet (effect.mb's outside)
/// and what they are ("" when none). A run to a declared moment keeps its clock still while any is awaited.
pub fn frame_awaiting(awaiting : Int, what : String) -> Unit {
  (current.val.frame_awaiting)(awaiting, what)
}

///|
/// Whether the run is on a clock of its own (its frames', 1/60 s a frame from 0, still while the app awaits the host:
/// a picture's run, mac_app.m's settle, MBView's shot_at), not the machine's.
pub fn own_clock() -> Bool {
  (current.val.own_clock)()
}

///|
/// Whether the system asks for less motion (macOS and iOS: Reduce Motion;
/// Android: animations off, its animator duration scale 0). Read at most
/// once a second.
pub fn reduce_motion() -> Bool {
  (current.val.reduce_motion)()
}

///|
/// The system whose keys the person types with, as `platform` numbers them, where it is not the host's own: a
/// browser's, the system under it (⌥← a word on a Mac's, Ctrl+← on Windows'); -1 the host's own.
pub fn keys_platform() -> Int {
  (current.val.keys_platform)()
}

///|
pub fn exit(code : Int) -> Unit {
  (current.val.exit)(code)
}

///|
pub fn mem_bytes() -> Double {
  (current.val.mem_bytes)()
}

///|
/// Where the system's back goes (Android's back gesture, predictive or not,
/// and its back button; a mouse's back button): `back(kind, x, progress,
/// edge)`, kind 0 a back gesture started at x (logical pixels), 1 it moved
/// (to x, `progress` 0-1 as the system has it), 2 let go to go back (or a
/// back with no gesture), 3 called off; edge 0 the left, 1 the right.
/// Called before `run`.
pub fn set_back(back : FuncRef[(Int, Double, Double, Int) -> Unit]) -> Unit {
  (current.val.set_back)(back)
}

///|
/// Whether the app takes back now (a page to go back to): when not, the
/// system does what it does (Android leaves the app).
pub fn back_enabled(on : Bool) -> Unit {
  (current.val.back_enabled)(on)
}

///|
/// Whether the system asks for less transparency (glass drawn solid):
/// macOS's and iOS's Reduce Transparency, Windows' transparency effects
/// turned off; Android has no such setting (never).
pub fn reduce_transparency() -> Bool {
  (current.val.reduce_transparency)()
}

///|
/// Whether the system asks for more contrast (lines and quiet words drawn stronger): macOS's Increase Contrast,
/// iOS's Increase Contrast (darker system colours), Windows' high contrast on; Android and Linux have no such setting
/// an app reads (never).
pub fn increase_contrast() -> Bool {
  (current.val.increase_contrast)()
}

///|
/// Whether the system is slowing the device down for its heat (glass drawn solid till it cools, its blur's passes
/// left undone): Android's thermal status moderate or worse (API 29 on), macOS's and iOS's thermal state serious or
/// critical; Windows and Linux say none an app reads (never). The host asks a frame as it changes.
pub fn thermal_throttled() -> Bool {
  (current.val.thermal_throttled)()
}

///|
/// The GPU's time for the last frame it finished, in ms (-1: not known on
/// this host).
pub fn gpu_ms() -> Double {
  (current.val.gpu_ms)()
}

///|
/// How many frames the app made were never drawn, each's place taken by a newer one while it waited for a drawing
/// thread slower than the app's (Android's GL thread: FrameMail), since the run began (0: none, or a host that draws
/// each frame on the app's own thread).
pub fn frames_dropped() -> Int {
  (current.val.frames_dropped)()
}

///|
/// The CPU's time the whole process has had since it started, every thread's (the app's and what runs beside it: a
/// core's, the system's for it), in ms (-1: not known on this host): a probe's (MBUI_PROBE) share of a CPU.
pub fn cpu_ms() -> Double {
  (current.val.cpu_ms)()
}

///|
/// The calling thread's CPU time in ms (-1: unsupported or fake clock): used by the journal to separate OS preemption
/// from real CPU work.
pub fn thread_cpu_ms() -> Double {
  (current.val.thread_cpu_ms)()
}

///|
/// The display's refresh rate in Hz (0.0: unknown or fake host).
pub fn display_hz() -> Double {
  (current.val.display_hz)()
}

///|
/// An environment variable ("" when unset; in a browser, the page's query
/// parameter of that name).
pub fn env(name : String) -> String {
  (current.val.env)(name)
}

///|
/// Who to tell when the app comes to the front or leaves it: `f` gets 1 while its window is shown, | 2 while it is
/// also in front (the key window of the active app; Android: the activity resumed with the window's focus), | 4 where
/// the app goes on with its window not shown (a desktop's app put away to the notification area or minimized: what
/// comes from outside, the core's words, still runs its frames, though nothing of them is shown: Windows'). Told on
/// each change, on the app's thread (Android: before the GL thread pauses). Hosts that never tell leave the app as
/// shown and in front.
pub fn set_app_state(f : FuncRef[(Int) -> Unit]) -> Unit {
  (current.val.set_app_state)(f)
}

///|
/// Whether something reads the app's widgets out (Android: an accessibility service on, TalkBack's or another's): the
/// app then tells the host what of its widgets changed (`a11y_tree`, @ui's a11y.mbt).
pub fn a11y_on() -> Bool {
  (current.val.a11y_on)()
}

///|
/// What of the app's widgets changed, for the system's accessibility: an update of what the host keeps of them (@ui's
/// a11y.mbt's head says it: the nodes that changed, each whole, and the focus). What is asked of one comes back on the
/// channel `a11y_channel`.
pub fn a11y_tree(tree : String) -> Unit {
  (current.val.a11y_tree)(tree)
}

///|
/// The channel what the system's accessibility asks of a widget is posted on (`{"id": widget, "action": name}`; a host
/// that lost what it kept, `{"action": "resend"}`): the framework's own (@ui takes it).
pub let a11y_channel : String = "a11y"

///|
/// How much bigger the system's setting for the size of words makes them (Android's fontScale: 1 as it is, 1.3 the
/// largest of most phones' steps; Windows' Text size, up to 2.25; Linux's text scaling): words are drawn that much
/// bigger, as Compose's sp are; lengths are not.
pub fn font_scale() -> Double {
  (current.val.font_scale)()
}

///|
/// What the system was started to be used with (the native input), as the host can tell at launch: 1 touch (iOS and
/// iPadOS with no pointing device, Android with no mouse or touchpad among its input devices, Windows with a touch
/// screen and no mouse or in tablet mode), 2 keyboard and mouse (macOS; iOS and iPadOS with a pointer, Android with a
/// mouse or a touchpad: DeX, ChromeOS; Windows otherwise), 0 where it cannot tell (the platform's then: @ui).
pub fn native_pointing() -> Int {
  (current.val.native_pointing)()
}

///|
/// What the person points with as the host knows it before any event says (event_finger): 1 a finger, 0 a mouse, a
/// trackpad or a pen; -1 where it does not say (its system's hand then: @ui).
pub fn pointing() -> Int {
  (current.val.pointing)()
}

///|
/// Whether a keyboard is at hand now, as the host can tell it as it is asked (it asks for a frame as one comes or
/// goes): 1 yes (macOS and Windows always; Android with a physical keyboard of letters among its input devices, iOS and
/// iPadOS with one connected: GCKeyboard), 0 no, -1 where it cannot tell (the platform's then: @ui).
pub fn keyboard() -> Int {
  (current.val.keyboard)()
}

///|
/// Whether the system is set to dark (macOS's appearance, Android's night mode, iOS's interface style, the browser's
/// prefers-color-scheme): what an app that follows the system shows. Asked each frame; a host asks for a frame when
/// it changes. Hosts that cannot tell say light.
pub fn system_dark() -> Bool {
  (current.val.system_dark)()
}

///|
/// The app is drawn dark (or light) from now on: the host's own parts follow it (Android's status and navigation
/// bars' icons, the Mac window's title bar). Said when it changes.
pub fn set_dark(dark : Bool) -> Unit {
  (current.val.set_dark)(dark)
}

///|
/// Turned sideways for a film (still.fail's player): landscape asked for (a phone with rotation locked
/// turns too) and the system's bars out of the way (a swipe brings them for a while); `false`, upright as it was.
/// Android does it (the activity's requested orientation, its window's insets controller), and iOS (the scene's
/// orientations, the status bar and the home indicator hidden); elsewhere nothing turns.
pub fn set_sideways(on : Bool) -> Unit {
  sideways_now.set(on)
  (current.val.set_sideways)(on)
}

///|
/// A phone held upright only (Android's portrait, an iPhone's) let turn as the person holds it while `on` (a station's
/// screen looked at): the system's rotation lock honoured, so with it on Android offers its turn button as the phone is
/// turned (a fixed portrait gets none); `false`, upright only again. Set_sideways still turns it while it asks. Android
/// and iOS do it where the app is held upright (a phone; a tablet turns anyway); elsewhere nothing changes.
pub fn set_turnable(on : Bool) -> Unit {
  turnable_now.set((current.val.set_turnable)(on) && on)
}

///|
/// Whether the app has the device turned sideways (set_sideways), or lets a phone held upright only turn as it is held
/// (set_turnable): its window as wide as it is because the app turned it or let it turn, for a film or a screen over
/// all of it, not because the screen is another kind (what a layout goes by is not this turn: still.fail's @sf.layout
/// keeps the one it had).
pub fn sideways() -> Bool {
  sideways_now.get() || turnable_now.get()
}

///|
/// Whether the app has turned the device sideways itself (set_sideways on): a film or a screen over all of the window,
/// to its edges, under what the system has at its sides (@ui.system_bars `left` and `right`, a phone's cutout) too.
pub fn turned_sideways() -> Bool {
  sideways_now.get()
}

///|
// kept across runs: put back as a host is set
let sideways_now : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
// kept across runs: put back as a host is set
let turnable_now : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// Whether this device can keep a performance record, and keeps one (-1 it cannot, 0 off, 1 on): the host remembers it
/// across launches (a setting of this device's, not synced) and starts recording as the app starts when it is on. Every
/// 5 s while on, the host writes a line of what the process takes (its share of a CPU, by thread, the device's thermal
/// state, …) to a file of the app's own, and the app's frames their summary (perf_line): nothing leaves the device.
/// iOS and Windows keep one; elsewhere -1.
/// Reading it for a warm phone: find when (thermal, then the cpu lines before it), then which thread: main is the
/// app's frames (fps near 0 at rest; `frames why` names what drew), the core's is its JS (`core js:`, `core: in` by
/// topic), the stream's is a screen, Apple's the system working for the app. Read it against background, a screen
/// open, charging and low power.
pub fn perf_state() -> Int {
  (current.val.perf_state)()
}

///|
/// Whether a performance record is being kept now (perf_state 1): asked each frame by the frame probe (a flag the host
/// reads, nothing more).
pub fn perf_recording() -> Bool {
  perf_state() == 1
}

///|
/// The performance record kept from now on, or no longer (perf_state), at once and from the next launch on; nothing
/// where the device keeps none.
pub fn set_perf(on : Bool) -> Unit {
  if perf_state() < 0 {
    return
  }
  (current.val.set_perf)(on)
}

///|
/// A line of the app's into the performance record while it is kept (the host puts the wall time before it): the
/// frame probe's summary, what the app is doing that warms a device (a station's screen looked at). Nothing while it
/// is not kept.
pub fn perf_line(line : String) -> Unit {
  if perf_recording() {
    (current.val.perf_line)(line)
  }
}

///|
/// Where the performance record's files are, as the device's files show the app's ("Documents/perf"): "" where none is
/// kept.
pub fn perf_where() -> String {
  (current.val.perf_where)()
}

///|
/// How many bytes the performance record's files have on the device now (the last few files, each at most a few MB).
pub fn perf_size() -> Double {
  (current.val.perf_size)()
}

///|
/// The performance record's files as one, the oldest first (what is written meanwhile in it too), to hand on through
/// the system's share sheet (@hostapi.share): a release build's files are nowhere a person can take them from. Empty
/// where none is kept.
pub fn perf_read() -> Bytes {
  (current.val.perf_read)()
}

///|
/// Whether the device can show the performance record's folder, and the logs beside it (perf_open), where it has no
/// share sheet to hand them on through (Windows).
pub fn perf_opens() -> Bool {
  (current.val.perf_open)(false)
}

///|
/// The performance record's folder, and the logs beside it, shown in the system's own file manager; false where it
/// cannot be (perf_opens). Asked off the thread that draws: nothing waits for the file manager.
pub fn perf_open() -> Bool {
  (current.val.perf_open)(true)
}

///|
/// Whether the device can show a file of its own where it is, in the system's file manager (reveal_file): macOS's
/// Finder, Windows' Explorer, a Linux desktop's file manager; not a phone's nor the web's.
pub fn reveals_files() -> Bool {
  (current.val.reveal_file)("", false)
}

///|
/// The file at `path` (on this device) shown chosen in its folder in the system's file manager (在访达中显示); false
/// where it cannot be (reveals_files) or is not there.
pub fn reveal_file(path : String) -> Bool {
  path != "" && (current.val.reveal_file)(path, true)
}

///|
/// Words (`text`), or a file of `data` named `name` (`mime`), handed to another app through the system's share sheet
/// (Android's chooser, macOS's sharing picker); false where there is none (or no app takes it).
pub fn share(text : String, name : String, mime : String, data : Bytes) -> Bool {
  (current.val.share)(text, name, mime, data)
}

///|
/// What another app shared into this one since last asked (Android's ACTION_SEND of text or files, ACTION_SEND_MULTIPLE
/// of files; iOS's share extension, what it kept taken as the app comes to the front: src/host/ios_share.m;
/// MBUI_SHARE_FILES, paths split by |, on macOS and iOS for scripted runs), as JSON text `{"text","title","files"}`,
/// `files` each `{"name","type","size"}` (absent when none); "" when nothing was.
pub fn shared_in() -> String {
  (current.val.shared_in)()
}

///|
/// The i-th of the files shared in (`shared_in`'s `files`), taken once: empty after, or where there is none.
pub fn shared_in_file(i : Int) -> Bytes {
  (current.val.shared_in_file)(i)
}

///|
/// This build's version code, as the system has it (Android's); 0 where the app does not update itself.
pub fn app_version() -> Int {
  (current.val.app_version)()
}

///|
/// A newer build at `url` (its `sha256`, `size` bytes) downloaded as `name` by itself and checked, made ready to be put
/// in this app's place (`update_apply`; Android's Updates.java puts it in place by itself once the app has been out of
/// sight a while). `now`: asked by the person, downloaded at once; else it may wait for a network that costs nothing
/// (Android's: none metered). One already ready, or coming, by that name: nothing more. Nothing where the app does
/// not update itself. How it goes: `update_state`. `delta`: "" or the JSON `{"url","sha256","size","makes_sha256",
/// "makes_size"}` of a delta from this build that makes the package (`makes_sha256`, `makes_size`: the made bytes, which
/// `sha256`, `size` say where the made package is the file itself) out of what is installed: a host that takes it
/// downloads it, applies it and checks what it made, and downloads the whole package as before on any failure.
pub fn update_fetch(
  url : String,
  sha256 : String,
  size : Double,
  name : String,
  now : Bool,
  delta : String,
) -> Unit {
  (current.val.update_fetch)(url, sha256, size, name, now, delta)
}

///|
/// The build made ready (`update_fetch`) put in this app's place now: the app ends, and is opened again as the newer
/// build where the system lets it (macOS, Windows, Linux); where it does not (Android: no app opens itself from
/// behind), the newer build says `said` in a notification that opens it. Where the person's leave to install apps
/// is wanted (Android's), the system's page for it is opened first, and once it is given the build is put in place.
pub fn update_apply(said : String) -> Unit {
  (current.val.update_apply)(said)
}

///|
/// How an update goes, as JSON text: `{"phase","percent","error","file"}`: phase idle, waiting (for a network that
/// costs nothing), downloading, retrying, ready (downloaded and checked, waiting to be put in place), allow (the
/// person's leave to install apps wanted), installing, failed; `file` the build's name (update_fetch's) while there is
/// one; `away` true where a build ready is put in place by itself while the app is out of sight (Android's); "" where
/// the app does not update itself.
pub fn update_state() -> String {
  (current.val.update_state)()
}

///|
/// A package (an APK a chat has) handed to the system's installer, which asks the person to confirm (Android:
/// still.fail's Install.kt installApk). What comes of it, when it is not installed, comes on @hostapi.system_channel
/// (system.mbt `install`: the leave to install apps asked for, or why it failed: "unsupported" where there is no
/// installer).
pub fn install_package(name : String, data : Bytes) -> Unit {
  (current.val.install_package)(name, data)
}

///|
/// A scripted run's input given to the host to send as its own (src/ui/drive.mbt): `drive_insert` words committed and
/// `drive_mark` composed by the input method (macOS: NSTextInputClient's insertText and setMarkedText; Android: the
/// view's InputConnection), `drive_newline` its Enter, `drive_paste` the system's paste of the clipboard (Cmd+V,
/// KEYCODE_PASTE), `drive_backspace`, `drive_shot` the window's picture saved at `text` (a path); 6 and 7 one of the
/// app's notifications (notify.mbt) whose title or words hold `text`, tapped (6) or only looked for (7), false when none
/// does; 8 the window resized to "<w>x<h>"; 9 the directory `text` watched for what the run's runner has done, each
/// file come there posted on channel "runner" (done_watch.h: macOS, Android, Windows); 10 the canvas's GL context made
/// anew, as one lost (Linux and the browser: the images' contract, scripts/host_contract.sh), 11 whether it has been since;
/// 12 input to the screen measured by the host, `text` "MODE X Y" (macOS's mac_latency.h, Android's Latency.java: its
/// own events from then on, the process ending with what it measured); 13 files let go on the window, `text` "X Y
/// PATH|PATH…", as the system's drop of them (Linux's linux_app.c drop_drive). False where
/// the host has no such path (the caller sends it to the app itself).
pub fn drive(kind : Int, text : String) -> Bool {
  (current.val.drive)(kind, text)
}

///|
/// Starts decoding the image at `src` (a file path or an http(s) URL);
/// returns its id.
pub fn image_load(src : String, max_px : Int) -> Int {
  (current.val.image_load)(src, max_px)
}

///|
/// Starts decoding an encoded image (JPEG, PNG, HEIC, WebP…) in memory.
pub fn image_load_bytes(data : Bytes, max_px : Int) -> Int {
  (current.val.image_load_bytes)(data, max_px)
}

///|
/// 0 while decoding, 1 when ready, -1 if it failed. Ready, `out` gets the
/// decoded width and height and the original's, in pixels.
pub fn image_info(id : Int, out : FixedArray[Double]) -> Int {
  (current.val.image_info)(id, out)
}

///|
pub fn image_free(id : Int) -> Unit {
  (current.val.image_free)(id)
}

///|
/// A ready image's pixels as decoded (image_info's width by height, rows from the top, RGBA premultiplied) into `out`
/// (at least w × h × 4 long): false where it is not ready or cannot be read back.
pub fn image_pixels(id : Int, out : FixedArray[Byte]) -> Bool {
  (current.val.image_pixels)(id, out)
}

///|
/// The frame presented last, drawn again by the renderer as it was, and its pixels in the rectangle `x`, `y`, `w` by `h`
/// (device pixels from its top left) into `out` (at least w × h × 4 long: RGBA premultiplied, rows from the top): false
/// where the rectangle is not all in it, or the frame cannot be read back here.
pub fn drawn_pixels(x : Int, y : Int, w : Int, h : Int, out : FixedArray[Byte]) -> Bool {
  (current.val.drawn_pixels)(x, y, w, h, out)
}

///|
/// Instances never presented (`count` of them in `inst`, as `present` takes a frame's: a shot's, ui/src/ui/shot.mbt)
/// drawn by the renderer as a frame is, but `scale` device pixels a point (whatever the window's) into a picture of
/// their own `w` by `h` device pixels, their 0, 0 its top left, on its ground `r`, `g`, `b`, and its pixels into `out`
/// as drawn_pixels gives the frame's (RGBA premultiplied, rows from the top); the frame presented stays as it was
/// (drawn again, it is the same). False where nothing can be read back here.
pub fn drawn_pixels_of(
  inst : FixedArray[Double],
  count : Int,
  r : Double,
  g : Double,
  b : Double,
  scale : Double,
  w : Int,
  h : Int,
  out : FixedArray[Byte],
) -> Bool {
  (current.val.drawn_pixels_of)(inst, count, r, g, b, scale, w, h, out)
}

///|
/// What a site (a view of kind 3) has to say, oldest first: a JSON text, "" when nothing waits. `{"req":n,"method",
/// "path","headers":[[k,v]…],"page":true|false}` a request of its own host the app answers (`view_site_head`, then
/// `view_site_chunk`s, then `view_site_end`); `{"gone":n}` a request the page let go of (nothing more of it is taken);
/// `{"leave":url}` a link to elsewhere tapped (not followed); `{"late":n}` a request with no head after `head_wait_ms`
/// (view_tell 3; it waits on); `{"slow":n}` an answer more of which waits than `backlog` (the host takes no more of
/// it, and fails its body once what waits is read: the app ends it). Of a page's or a site's, `{"said":text}`: what
/// its page's scripts said to the app (`mbuiHost.post(text)`), in the order said.
pub fn view_site_next(id : Int) -> String {
  (current.val.view_site_next)(id)
}

///|
/// A request's body (empty when it has none, or the host's web view does not hand it over: Android's).
pub fn view_site_body(id : Int, req : Int) -> Bytes {
  (current.val.view_site_body)(id, req)
}

///|
/// A request's answer begins: its status and headers (`[[k,v]…]` as JSON text).
pub fn view_site_head(id : Int, req : Int, status : Int, headers : String) -> Unit {
  (current.val.view_site_head)(id, req, status, headers)
}

///|
/// The next piece of a request's answer's body.
pub fn view_site_chunk(id : Int, req : Int, data : Bytes) -> Unit {
  (current.val.view_site_chunk)(id, req, data)
}

///|
/// A request's answer ends ("" whole; else why it broke off). A request with no head yet fails with it.
pub fn view_site_end(id : Int, req : Int, error : String) -> Unit {
  (current.val.view_site_end)(id, req, error)
}

///|
/// Where the site's page is: `{"path","back","forward","loading","title"}` as JSON text.
pub fn view_site_state(id : Int) -> String {
  (current.val.view_site_state)(id)
}

///|
/// The site's page at `path` of its own host.
pub fn view_site_load(id : Int, path : String) -> Unit {
  (current.val.view_site_load)(id, path)
}

///|
/// What the app tells a view beyond its controls: `what` 1 a script to run in its page (a page's or a site's): in the
/// page there once it has loaded, or has said something (`{"said":…}`) since it started; one sent while a page loads
/// waits for it, all in the order sent. 2 who takes a finger on it: "all", "through", "pinch" or "vertical", then the
/// slop in points (ui's NativeView::touch). 3 a site's settings, as JSON: `head_wait_ms` (how long a request waits for
/// its head before the host says `{"late":n}`, still waiting), `backlog` (how many bytes of an answer may wait for the
/// page to read them before the host says `{"slow":n}` and takes no more of it). 4 where the app draws what takes a
/// press over it. 5 (any view, `text` "") raised over all the others: stacked under none of them, the one a press goes
/// to where they meet (ui's stack_views, as the app paints them); a view opened goes over those opened before it.
/// 6 (a video) how the host's own reader, where it has one, reads its bytes itself rather than asking the app
/// (`view_read_next`): what the app's reader of it gave it (still.fail's: a core call; Android's NativeViews.Direct).
pub fn view_tell(id : Int, what : Int, text : String) -> Unit {
  (current.val.view_tell)(id, what, text)
}

///|
/// A native view of `kind`: 1 a video (and audio) player, its bytes read through the app (`view_read_next`), `arg`
/// its MIME type ("video/mp4"); 2 a web page of `arg`'s HTML, its scripts on, nothing of the device's files or the
/// app's reachable, its links not followed; 3 a site served by the app: a web view at `arg` (a path) of a host of its
/// own, each of whose requests the app answers (`view_site_next`). Hidden until placed. 0 when this host has no such
/// view.
pub fn view_open(kind : Int, arg : String) -> Int {
  (current.val.view_open)(kind, arg)
}

///|
/// What the image (scene.mbt's slot 20) of the instance the app paints where a native view shows (kind 9) is: this plus
/// the view's id (exact in the renderers' 32-bit floats, above `stream_tex_base`'s). Its c2 says the part of the view's
/// content it covers (u0 v0 du dv, shares of the content's rect). A host whose views are under its surface (macOS,
/// iOS, Windows, the browser) leaves the canvas clear there, a hole the view shows through, and draws nothing of it; a
/// host that draws each view into a picture of its own (Android: NativeViews.Picture) draws that part of it there, in
/// the frame, so it moves as what is around it does.
pub let view_tex_base : Int = 8388608

///|
/// Where the view shows, in the app's coordinates (logical pixels from the window's top left): its content in (x, y,
/// w, h) (a video's picture is stretched to it), its corners round by `r0` to `r3` (top left, then round it; 0:
/// square), seen only within the clip (cx0, cy0)-(cx1, cy1); hidden when not `shown`. Told again whenever it moves
/// (each frame it does).
pub fn view_place(
  id : Int,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  cx0 : Double,
  cy0 : Double,
  cx1 : Double,
  cy1 : Double,
  r0 : Double,
  r1 : Double,
  r2 : Double,
  r3 : Double,
  shown : Bool,
) -> Unit {
  (current.val.view_place)(id, x, y, w, h, cx0, cy0, cx1, cy1, r0, r1, r2, r3, shown)
}

///|
/// The view gone (its player stopped, its page closed).
pub fn view_close(id : Int) -> Unit {
  (current.val.view_close)(id)
}

///|
/// A player told: `op` 1 play, 2 pause, 3 to `value` ms (the frame there, exactly), 4 at `value` times its speed, 11
/// to about `value` ms at once (the nearest key frame: nothing before it decoded); a site: 5 back, 6 forward, 7
/// reload, 8 laid out at its rect over `value` and drawn at `value` times (a viewport's own size shown smaller).
pub fn view_control(id : Int, op : Int, value : Double) -> Unit {
  (current.val.view_control)(id, op, value)
}

///|
/// How the view stands: -1 failed, -2 a player's format unsupported, -3 its file not parseable, -4 unsupported or
/// damaged, 0 opening, 1 ready, 2 all file bytes delivered but still waiting for its first frame.
/// `out` (10): its length in ms (-1 not known), where it is (ms), playing (1; and while it seeks within what it has, if
/// it is to play), the picture's own width and height (pixels), the bytes it has been given, whether a frame has been
/// drawn (a page: loaded), buffering (1: to play and waiting on bytes still to come through the app, not a seek
/// within what it has, nor one while paused), how far on it has what it needs to play (ms; 0 not said), played to its
/// end (1).
pub fn view_info(id : Int, out : FixedArray[Double]) -> Int {
  (current.val.view_info)(id, out)
}

///|
/// A read the player waits on: its id (0: none waiting), `out` [0] its offset, [1] how many bytes it wants; or minus
/// the id of one it let go of (it wants none of what is left of it: the app stops reading it, answers it no more).
/// Each is answered as its bytes come (`view_read_answer`); the host asks for a frame when one comes.
pub fn view_read_next(id : Int, out : FixedArray[Double]) -> Int {
  (current.val.view_read_next)(id, out)
}

///|
/// Read `req`'s next bytes, as they come: those after what it was answered before (all of them at most as many as it
/// wanted; fewer is fine, none only at the file's end), `more` while more of it comes (its last answer may bring
/// none); `total` the file's whole size (-1 not known: Apple's player needs it, so give it, at the latest with its
/// last answer); -2: it could not be read (its last: the player fails).
pub fn view_read_answer(id : Int, req : Int, data : Bytes, total : Double, more : Bool) -> Unit {
  (current.val.view_read_answer)(id, req, data, total, more)
}

///|
/// A PDF opened from its bytes: its id, or 0 where the host draws none.
pub fn pdf_open(data : Bytes) -> Int {
  (current.val.pdf_open)(data)
}

///|
/// How many pages it has; -1 when it could not be opened.
pub fn pdf_pages(doc : Int) -> Int {
  (current.val.pdf_pages)(doc)
}

///|
/// A page's size in points (`out` [0] width, [1] height).
pub fn pdf_page_size(doc : Int, page : Int, out : FixedArray[Double]) -> Unit {
  (current.val.pdf_page_size)(doc, page, out)
}

///|
/// A page drawn (on white, off the app's thread) at most `max_px` on its longer side: an image's id, as image_load's
/// (image_info, image_free).
pub fn pdf_page_load(doc : Int, page : Int, max_px : Int) -> Int {
  (current.val.pdf_page_load)(doc, page, max_px)
}

///|
pub fn pdf_close(doc : Int) -> Unit {
  (current.val.pdf_close)(doc)
}

///|
/// What a video view says beyond its info: `what` 1 its frames' times (ms, comma between: view_control 20 asks them
/// read), 2 how a frame grabbed stands (view_control 21 at a time in ms: "1" grabbing, "2" here, "-1" failed, "0"
/// none, view_control 23 ending one given up); None while not known.
pub fn view_text(id : Int, what : Int) -> String? {
  (current.val.view_text)(id, what)
}

///|
/// A video view's frame grabbed (PNG), taken once.
pub fn view_still(id : Int) -> Bytes {
  (current.val.view_still)(id)
}

///|
/// A file put where the system keeps downloads (Android: Downloads, through MediaStore; macOS: ~/Downloads): true
/// once it is there.
pub fn save_file(name : String, data : Bytes) -> Bool {
  (current.val.save_file)(name, data)
}

///|
/// The word of `text` around `off` (UTF-16 offsets, its start and end) as the system finds words (Android's
/// BreakIterator, Apple's CFStringTokenizer: a dictionary's words in Chinese and Japanese); (-1, -1) where the host has
/// no such thing (Windows here) or `off` is in no word.
pub fn word_at(text : String, off : Int) -> (Int, Int) {
  (current.val.word_at)(text, off)
}

///|
/// `url` handed to the system: the browser, or the app it belongs to (Android's ACTION_VIEW, macOS's NSWorkspace,
/// iOS's UIApplication, Windows' ShellExecute). False when nothing took it.
pub fn open_url(url : String) -> Bool {
  (current.val.open_url)(url)
}

///|
/// The app over another app (system.mbt `over`: Android's OverActivity, a share sheet over the app it came from) done:
/// it goes, back to the app it was over; `open_app`, on into the app's own window. Nothing where it never is over one.
pub fn over_done(open_app~ : Bool) -> Unit {
  (current.val.over_done)(open_app)
}

///|
/// A page shown in a browser's tab over the app, the app under it (Android's Custom Tab, the system's browser where
/// none takes one; iOS's SFSafariViewController); elsewhere as open_url. False when nothing took it.
pub fn open_tab(url : String) -> Bool {
  (current.val.open_tab)(url)
}

///|
/// What the notice says that holds the app up while it listens for a browser coming back (@hostapi.browser_login, the
/// core's loopback listeners: Android's foreground service, in `channel`, named as the system's settings list it);
/// said before the browser opens, kept for the next. Other hosts keep no notice.
pub fn hold_words(channel~ : String, title~ : String, body~ : String) -> Unit {
  (current.val.hold_words)(channel, title, body)
}

///|
/// What was posted from outside the frames since the last take (`mb_post`, any thread: post.h), taken now as a frame
/// begins: how many. They are handed on one at a time (`post_next`), in the order posted.
pub fn post_take() -> Int {
  (current.val.post_take)()
}

///|
/// The next message taken (`post_take`): its channel, its JSON and the bytes beside it (empty: none). None when all
/// taken are handed on, or dropped since (`mb_post_drop`: a core stopped).
pub fn post_next() -> (String, String, Bytes)? {
  (current.val.post_next)()
}

///|
/// Starts a picture `w`×`h` points at `scale` pixels a point, on a ground of `bg` (0xRRGGBB).
pub fn ref_begin(w : Double, h : Double, scale : Double, bg : Int) -> Unit {
  (current.val.ref_begin)(w, h, scale, bg)
}

///|
/// `text` drawn into it by the platform, in its system font (style: style_italic, style_mono) at `size` and
/// `weight`, starting at `x` with its baseline at `base`, in `color` (0xRRGGBB), as one line. `out`: the width it
/// advances, then its ink box (left, top, right, bottom, in points from x and the baseline, y down; all 0 if the host
/// does not say).
pub fn ref_text(
  text : String,
  size : Double,
  weight : Int,
  style : Int,
  x : Double,
  base : Double,
  color : Int,
  out : FixedArray[Double],
) -> Unit {
  (current.val.ref_text)(text, size, weight, style, x, base, color, out)
}

///|
/// The picture written as `name`.png.
pub fn ref_end(name : String) -> Bool {
  (current.val.ref_end)(name)
}

///|
/// The window's picture as `name`.png: the frame last drawn, or (Android, a browser) the one drawn next; the caller
/// keeps both the same.
pub fn ref_frame(name : String) -> Bool {
  (current.val.ref_frame)(name)
}

///|
fn bl_start(path : String, done : String) -> Int {
  (current.val.bl_start)(path, done)
}

///|
fn bl_port(id : Int) -> Int {
  (current.val.bl_port)(id)
}

///|
fn bl_open(id : Int, url : String) -> Int {
  (current.val.bl_open)(id, url)
}

///|
fn bl_back(id : Int) -> String {
  (current.val.bl_back)(id)
}

///|
fn bl_end(id : Int) -> Unit {
  (current.val.bl_end)(id)
}

// This device's password manager (passwords.mbt): `op`, run with the arguments given (a JSON array), how it ended.

///|
fn pw_able() -> Bool {
  (current.val.pw_able)()
}

///|
fn pw_run(args : String) -> Int {
  (current.val.pw_run)(args)
}

///|
fn pw_out(id : Int) -> String {
  (current.val.pw_out)(id)
}

///|
fn pw_end(id : Int) -> Unit {
  (current.val.pw_end)(id)
}

// The system's autofill (autofill.mbt): a login of a site asked of its service, the one picked taken.

///|
fn af_able() -> Bool {
  (current.val.af_able)()
}

///|
fn af_ask(host : String) -> Int {
  (current.val.af_ask)(host)
}

///|
fn af_take() -> String {
  (current.val.af_take)()
}

///|
fn af_end() -> Unit {
  (current.val.af_end)()
}

// This device's passkeys (passkeys.mbt): a sign-in signed, how it ended.

///|
fn wa_able() -> Bool {
  (current.val.wa_able)()
}

///|
fn wa_get(ask : String) -> Int {
  (current.val.wa_get)(ask)
}

///|
fn wa_out(id : Int) -> String {
  (current.val.wa_out)(id)
}

///|
fn wa_end(id : Int) -> Unit {
  (current.val.wa_end)(id)
}

///|
fn pk_start(kind : Int) -> Int {
  (current.val.pk_start)(kind)
}

///|
fn pk_state(id : Int) -> Int {
  (current.val.pk_state)(id)
}

///|
fn pk_count(id : Int) -> Int {
  (current.val.pk_count)(id)
}

///|
fn pk_name(id : Int, i : Int) -> String {
  (current.val.pk_name)(id, i)
}

///|
fn pk_info(id : Int, i : Int) -> String {
  (current.val.pk_info)(id, i)
}

///|
fn pk_bytes(id : Int, i : Int) -> Bytes {
  (current.val.pk_bytes)(id, i)
}

///|
fn pk_end(id : Int) -> Unit {
  (current.val.pk_end)(id)
}

///|
fn kp_begin(name : String, mime : String, way : Int) -> Int {
  (current.val.kp_begin)(name, mime, way)
}

///|
fn kp_append(id : Int, data : Bytes) -> Int {
  (current.val.kp_append)(id, data)
}

///|
fn kp_finish(id : Int) -> Unit {
  (current.val.kp_finish)(id)
}

///|
fn kp_state(id : Int) -> Int {
  (current.val.kp_state)(id)
}

///|
fn kp_where(id : Int) -> String {
  (current.val.kp_where)(id)
}

///|
fn kp_end(id : Int) -> Unit {
  (current.val.kp_end)(id)
}

///|
fn ga_access() -> Int {
  (current.val.ga_access)()
}

///|
fn ga_ask() -> Unit {
  (current.val.ga_ask)()
}

///|
fn ga_answers() -> Int {
  (current.val.ga_answers)()
}

///|
fn ga_read() -> Int {
  (current.val.ga_read)()
}

///|
fn ga_read_state(id : Int) -> Int {
  (current.val.ga_read_state)(id)
}

///|
fn ga_read_rows(id : Int) -> String {
  (current.val.ga_read_rows)(id)
}

///|
fn ga_read_end(id : Int) -> Unit {
  (current.val.ga_read_end)(id)
}

///|
fn pk_photo(src : String) -> Int {
  (current.val.pk_photo)(src)
}

///|
fn cs_known(charset : String) -> Int {
  (current.val.cs_known)(charset)
}

///|
fn cs_decode(data : Bytes, charset : String) -> String {
  (current.val.cs_decode)(data, charset)
}

///|
fn mk_start(image : Bytes, marks : String) -> Int {
  (current.val.mk_start)(image, marks)
}

///|
fn mk_state(id : Int) -> Int {
  (current.val.mk_state)(id)
}

///|
fn mk_png(id : Int) -> Bytes {
  (current.val.mk_png)(id)
}

///|
fn nt_show(channel : String, tag : String, title : String, body : String, opens : String) -> Unit {
  (current.val.nt_show)(channel, tag, title, body, opens)
}

///|
fn nv_bar(spec : String) -> Int {
  (current.val.nv_bar)(spec)
}

///|
fn nt_cancel(tag : String) -> Unit {
  (current.val.nt_cancel)(tag)
}

///|
fn nt_state(what : Int) -> Int {
  (current.val.nt_state)(what)
}

///|
fn nt_text(what : Int) -> String {
  (current.val.nt_text)(what)
}

///|
fn st_open() -> Int {
  (current.val.st_open)()
}

///|
fn st_h264(id : Int, avcc : Bytes, w : Int, h : Int) -> Unit {
  (current.val.st_h264)(id, avcc, w, h)
}

///|
fn st_frame(id : Int, data : Bytes, key : Int, ts : Double) -> Unit {
  (current.val.st_frame)(id, data, key, ts)
}

///|
fn st_jpeg(id : Int, data : Bytes, ts : Double) -> Unit {
  (current.val.st_jpeg)(id, data, ts)
}

///|
fn st_next(id : Int) -> String {
  (current.val.st_next)(id)
}

///|
fn st_show(id : Int, ts : Double) -> Unit {
  (current.val.st_show)(id, ts)
}

///|
fn st_close(id : Int) -> Unit {
  (current.val.st_close)(id)
}

///|
fn st_h264_here() -> Int {
  (current.val.st_h264_here)()
}

///|
fn st_feeds() -> Int {
  (current.val.st_feeds)()
}

///|
fn st_codec(id : Int, cmd : String, data : Bytes) -> Unit {
  (current.val.st_codec)(id, cmd, data)
}

///|
fn cl_read() -> Int {
  (current.val.cl_read)()
}

///|
fn cl_state(id : Int) -> Int {
  (current.val.cl_state)(id)
}

///|
fn cl_picture(id : Int) -> Int {
  (current.val.cl_picture)(id)
}

///|
fn tm_open(cols : Int, rows : Int) -> Int {
  (current.val.tm_open)(cols, rows)
}

///|
fn tm_write(id : Int, data : Bytes) -> Unit {
  (current.val.tm_write)(id, data)
}

///|
fn tm_resize(id : Int, cols : Int, rows : Int, cw : Int, ch : Int) -> Unit {
  (current.val.tm_resize)(id, cols, rows, cw, ch)
}

///|
fn tm_frame(id : Int, flags : Int) -> Bytes {
  (current.val.tm_frame)(id, flags)
}

///|
fn tm_modes(id : Int) -> Int {
  (current.val.tm_modes)(id)
}

///|
fn tm_scroll(id : Int, kind : Int, value : Int) -> Unit {
  (current.val.tm_scroll)(id, kind, value)
}

///|
fn tm_select(id : Int, kind : Int, x0 : Int, y0 : Int, x1 : Int, y1 : Int) -> Int {
  (current.val.tm_select)(id, kind, x0, y0, x1, y1)
}

///|
fn tm_text(id : Int, sel : Int) -> String {
  (current.val.tm_text)(id, sel)
}

///|
fn tm_mouse(
  id : Int,
  action : Int,
  button : Int,
  mods : Int,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  cw : Int,
  ch : Int,
) -> Bytes {
  (current.val.tm_mouse)(id, action, button, mods, x, y, w, h, cw, ch)
}

///|
fn tm_close(id : Int) -> Unit {
  (current.val.tm_close)(id)
}

///|
fn cl_text(id : Int) -> String {
  (current.val.cl_text)(id)
}

///|
fn cl_png(id : Int) -> Bytes {
  (current.val.cl_png)(id)
}

///|
fn cl_files(id : Int) -> Int {
  (current.val.cl_files)(id)
}

///|
fn cl_file_name(id : Int, i : Int) -> String {
  (current.val.cl_file_name)(id, i)
}

///|
fn cl_file(id : Int, i : Int) -> Bytes {
  (current.val.cl_file)(id, i)
}

///|
fn cl_end(id : Int) -> Unit {
  (current.val.cl_end)(id)
}

///|
fn cl_set(text : String, png : Bytes, label : String) -> Unit {
  (current.val.cl_set)(text, png, label)
}

///|
fn dv_copy_shown() -> Int {
  (current.val.dv_copy_shown)()
}

///|
fn dv_key_catch(on : Int) -> Unit {
  (current.val.dv_key_catch)(on)
}

///|
fn dv_ime_inset() -> Double {
  (current.val.dv_ime_inset)()
}

///|
fn dv_keep_awake(on : Int) -> Unit {
  (current.val.dv_keep_awake)(on)
}

///|
fn dv_haptic(kind : Int) -> Unit {
  (current.val.dv_haptic)(kind)
}

///|
fn dv_ime_action(kind : Int) -> Unit {
  (current.val.dv_ime_action)(kind)
}

///|
fn dv_ime_let_go() -> Unit {
  (current.val.dv_ime_let_go)()
}

///|
fn ncall_call(name : String, params : String) -> Int {
  (current.val.ncall_call)(name, params)
}

///|
fn ncall_state(id : Int) -> Int {
  (current.val.ncall_state)(id)
}

///|
fn ncall_result(id : Int) -> String {
  (current.val.ncall_result)(id)
}

///|
fn ncall_end(id : Int) -> Unit {
  (current.val.ncall_end)(id)
}

///|
/// A part of the next frame presented that changed from the one before (points), for a host that keeps its picture
/// and draws only those parts again, the rest as it drew it: said once for each part before
/// `present`; `w` < 0, all of it; once with `w` 0, none. A frame nothing was said for is drawn whole.
pub fn render_dirty(x : Double, y : Double, w : Double, h : Double) -> Unit {
  (current.val.rn_dirty)(x, y, w, h)
}

///|
/// Set the global ambient light axis angle (radians) for liquid glass surfaces on the active renderer.
pub fn set_glass_light_angle(radians : Double) -> Unit {
  (current.val.rn_glass_light_angle)(radians)
}

///|
fn st_audio_here() -> Int { (current.val.st_audio_here)() }

///|
fn st_audio(id : Int, data : Bytes) -> Unit { (current.val.st_audio)(id, data) }

///|
fn st_audio_played(id : Int) -> Double { (current.val.st_audio_played)(id) }

///|
fn st_audio_queued(id : Int) -> Double { (current.val.st_audio_queued)(id) }

///|
fn st_audio_wanted(id : Int) -> Double { (current.val.st_audio_wanted)(id) }

///|
fn st_audio_volume(id : Int, v : Double) -> Unit { (current.val.st_audio_volume)(id, v) }

///|
fn st_frame_shown(id : Int, data : Bytes, key : Int, ts : Double, show : Int) -> Int {
  current.val.st_frame_shown(id, data, key, ts, show)
}

///|
fn st_flush(id : Int, drain : Int) -> Unit { (current.val.st_flush)(id, drain) }

///|
fn st_layers() -> Int { (current.val.st_layers)() }

///|
fn st_pointer_at(id : Int, x : Double, y : Double, shown : Int) -> Unit {
  (current.val.st_pointer_at)(id, x, y, shown)
}

///|
fn st_direct(id : Int, route : Double, after : Double, what : Int) -> Unit {
  (current.val.st_direct)(id, route, after, what)
}
///|
fn st_h265_here() -> Int { (current.val.st_h265_here)() }

///|
fn st_hevc(id : Int, hvcc : Bytes, w : Int, h : Int) -> Unit { (current.val.st_hevc)(id, hvcc, w, h) }

///|
fn st_av1_here() -> Int { (current.val.st_av1_here)() }

///|
fn st_av1(id : Int, av1c : Bytes, w : Int, h : Int) -> Unit { (current.val.st_av1)(id, av1c, w, h) }

///|
/// Whether the app is registered to start automatically at user login.
pub fn auto_launch() -> Bool {
  (current.val.auto_launch)()
}

///|
/// Enable or disable starting the app automatically at user login. Returns true on success.
pub fn set_auto_launch(enabled : Bool) -> Bool {
  (current.val.set_auto_launch)(enabled)
}

///|
/// Register a desktop global hotkey (`accel`, e.g. "CmdOrCtrl+Shift+Space") under `id`.
/// Triggered hotkeys arrive as host posts on channel `"mbui.hotkey"` with `{"id":"<id>"}`.
pub fn hotkey_set(id : String, accel : String) -> Bool {
  (current.val.hotkey_set)(id, accel)
}

///|
/// Unregister a previously registered global hotkey by `id`.
pub fn hotkey_clear(id : String) -> Unit {
  (current.val.hotkey_clear)(id)
}
