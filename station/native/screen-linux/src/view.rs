// Linux view session orchestration: `status` probe + `view` capture/encode/input pipeline.

use crate::diff;
use crate::encode::{self, H264Encoder};
use crate::input_queue::{InputOp, InputQueue};
use crate::pace::{self, Gate, StillRefiner};
use crate::protocol::{
    self, Out, IN_BOUNDS, IN_INPUT, IN_KEYFRAME, IN_NEXT, IN_RATE, MAX_IN_MESSAGE, OUT_CONFIG,
    OUT_CURSOR, OUT_CURSOR_IMAGE, OUT_FRAME, OUT_INFO, OUT_REGION,
};
use crate::region::{self, Region};
use crate::wayland::{self, WaylandCapture, WaylandInputDriver, WaylandProbe};
use crate::x11::{self, X11Capture, X11InputDriver};
use serde_json::{json, Value};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

fn wants_wayland() -> bool {
    let session_type = std::env::var("XDG_SESSION_TYPE").unwrap_or_default();
    let wl_display = std::env::var("WAYLAND_DISPLAY").unwrap_or_default();
    session_type.eq_ignore_ascii_case("wayland") || !wl_display.trim().is_empty()
}

fn has_x11_display() -> bool {
    !std::env::var("DISPLAY").unwrap_or_default().trim().is_empty()
}

/// Implement `stillfail-screen-linux status`.
pub fn status() -> Value {
    if wants_wayland() {
        match wayland::probe() {
            WaylandProbe::Ready { width, height } => json!({
                "ok": true,
                "backend": "wayland",
                "display": { "id": 0, "width": width, "height": height },
                "capture": true,
            }),
            WaylandProbe::NoWlr(err) => json!({
                "ok": false,
                "capture": false,
                "unsupported": "waylandNoWlr",
                "error": err,
            }),
            WaylandProbe::Unavailable(err) => json!({
                "ok": false,
                "capture": false,
                "unsupported": "unavailable",
                "error": err,
            }),
        }
    } else if has_x11_display() {
        match x11::probe() {
            Ok((width, height)) => json!({
                "ok": true,
                "backend": "x11",
                "display": { "id": 0, "width": width, "height": height },
                "capture": true,
            }),
            Err(err) => json!({
                "ok": false,
                "capture": false,
                "unsupported": "unavailable",
                "error": err,
            }),
        }
    } else {
        json!({
            "ok": false,
            "capture": false,
            "unsupported": "noDisplay",
            "error": "neither DISPLAY nor WAYLAND_DISPLAY is set",
        })
    }
}

struct ControlState {
    next_pending: usize,
    force_keyframe: bool,
    rate: Option<u32>,
    bounds: Option<(u32, u32, Option<Region>)>,
    closed: bool,
}

struct Control {
    state: Mutex<ControlState>,
    cv: Condvar,
}

impl Control {
    fn new() -> Self {
        Self {
            state: Mutex::new(ControlState {
                next_pending: 0,
                force_keyframe: false,
                rate: None,
                bounds: None,
                closed: false,
            }),
            cv: Condvar::new(),
        }
    }
}

enum Backend {
    X11(X11Capture),
    Wayland(WaylandCapture),
}

impl Backend {
    fn open() -> Result<Self, String> {
        if wants_wayland() {
            WaylandCapture::open().map(Backend::Wayland)
        } else if has_x11_display() {
            X11Capture::open().map(Backend::X11)
        } else {
            Err("neither DISPLAY nor WAYLAND_DISPLAY is set".to_string())
        }
    }

    fn width(&self) -> u32 {
        match self {
            Backend::X11(x) => x.width(),
            Backend::Wayland(w) => w.width(),
        }
    }

    fn height(&self) -> u32 {
        match self {
            Backend::X11(x) => x.height(),
            Backend::Wayland(w) => w.height(),
        }
    }

    fn is_wayland(&self) -> bool {
        matches!(self, Backend::Wayland(_))
    }

    fn capture_label(&self) -> &'static str {
        match self {
            Backend::X11(x) => x.capture_label(),
            Backend::Wayland(_) => "Wayland (wlr-screencopy)",
        }
    }

    fn capture_bgra(
        &mut self,
        out: &mut Vec<u8>,
        with_damage: bool,
        overlay_cursor: bool,
        should_abort: &dyn Fn() -> bool,
    ) -> Result<bool, String> {
        match self {
            Backend::X11(x) => x.capture_bgra(out).map(|()| true),
            Backend::Wayland(w) => w.capture_bgra(out, with_damage, overlay_cursor, should_abort),
        }
    }
}

/// Implement `stillfail-screen-linux view`.
pub fn run(request: &Value, out: Out) {
    let codec = match request["codec"].as_str() {
        Some("jpeg") => "jpeg",
        _ => "h264",
    };
    let mut max_w = request["maxWidth"].as_u64().unwrap_or(1920).clamp(2, 16384) as u32;
    let mut max_h = request["maxHeight"].as_u64().unwrap_or(1080).clamp(2, 16384) as u32;
    let mut normal_bitrate = request["bitrate"]
        .as_u64()
        .map(|b| b.clamp(encode::MIN_BITRATE as u64, encode::MAX_BITRATE as u64) as u32)
        .unwrap_or(encode::DEFAULT_BITRATE);
    let asked_fps = pace::fps(request["fps"].as_u64());
    let enc_fps = pace::encoder_fps(asked_fps);

    let mut backend = match Backend::open() {
        Ok(b) => b,
        Err(err) => {
            out.json(OUT_INFO, json!({ "error": err, "code": "capture" }));
            return;
        }
    };

    let src_w = backend.width();
    let src_h = backend.height();
    let is_wayland = backend.is_wayland();
    let mut crop_rect = (0u32, 0u32, src_w, src_h);
    let (mut enc_w, mut enc_h) = diff::fitted_size(src_w, src_h, max_w, max_h);

    // Initialize encoder BEFORE sending OUT_INFO or spawning worker threads so any init error
    // sends exactly one error OUT_INFO and exits immediately.
    let mut h264 = if codec == "h264" {
        match H264Encoder::new(enc_w, enc_h, normal_bitrate, enc_fps) {
            Ok(e) => Some(e),
            Err(err) => {
                out.json(OUT_INFO, json!({ "error": err, "code": "encoder" }));
                return;
            }
        }
    } else {
        None
    };

    out.json(
        OUT_INFO,
        json!({
            "width": src_w,
            "height": src_h,
            "encoder": if codec == "jpeg" { "JPEG (software)" } else { "OpenH264 (software)" },
            "codec": codec,
            "regions": true,
            "capture": backend.capture_label(),
        }),
    );

    let control = Arc::new(Control::new());
    let input_queue = Arc::new(InputQueue::new());

    // Spawn dedicated input worker thread so input never blocks capture/encode and cleanly
    // cancels pending text + releases held keys/buttons on exit.
    let input_q_worker = Arc::clone(&input_queue);
    let input_thread = thread::spawn(move || {
        if is_wayland {
            if let Ok(mut driver) = WaylandInputDriver::open(src_w, src_h) {
                while let Some(op) = input_q_worker.pop_blocking() {
                    driver.apply(&op);
                }
                let (keys, buttons) = input_q_worker.take_held();
                driver.release(&keys, &buttons);
            }
        } else if let Ok(mut driver) = X11InputDriver::open(src_w, src_h) {
            let cancelled = || input_q_worker.is_cancelled();
            while let Some(op) = input_q_worker.pop_blocking() {
                driver.apply(&op, &cancelled);
            }
            let (keys, buttons) = input_q_worker.take_held();
            driver.release(&keys, &buttons);
        }
    });

    // Spawn stdin reader thread.
    let ctrl_reader = Arc::clone(&control);
    let input_q_reader = Arc::clone(&input_queue);
    let reader_thread = thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut lock = stdin.lock();
        while let Some((kind, payload)) = protocol::read_message(&mut lock, MAX_IN_MESSAGE) {
            match kind {
                IN_NEXT => {
                    let mut s = ctrl_reader.state.lock().unwrap();
                    s.next_pending += 1;
                    ctrl_reader.cv.notify_all();
                }
                IN_KEYFRAME => {
                    let mut s = ctrl_reader.state.lock().unwrap();
                    s.force_keyframe = true;
                    ctrl_reader.cv.notify_all();
                }
                IN_INPUT => {
                    if let Ok(v) = serde_json::from_slice::<Value>(&payload) {
                        if let Some(op) = InputOp::parse(&v) {
                            input_q_reader.push(op);
                        }
                    }
                }
                IN_RATE => {
                    if payload.len() >= 4 {
                        let bps =
                            u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                        let mut s = ctrl_reader.state.lock().unwrap();
                        s.rate = Some(bps);
                        ctrl_reader.cv.notify_all();
                    }
                }
                IN_BOUNDS => {
                    if let Ok(v) = serde_json::from_slice::<Value>(&payload) {
                        let mw = v["maxWidth"].as_u64().unwrap_or(1920).clamp(2, 16384) as u32;
                        let mh = v["maxHeight"].as_u64().unwrap_or(1080).clamp(2, 16384) as u32;
                        let reg = region::of(&v["region"]);
                        let mut s = ctrl_reader.state.lock().unwrap();
                        s.bounds = Some((mw, mh, reg));
                        ctrl_reader.cv.notify_all();
                    }
                }
                _ => {}
            }
        }
        // Stdin closed: immediately cancel input queue and wake capture loop.
        input_q_reader.cancel();
        let mut s = ctrl_reader.state.lock().unwrap();
        s.closed = true;
        ctrl_reader.cv.notify_all();
    });

    // Main capture / encode loop.
    let started = Instant::now();
    let mut gate = Gate::new(asked_fps);
    let mut still_refiner = StillRefiner::default();
    let mut sent_region: Option<Region> = None;
    let mut region_dirty = false;
    let mut first_frame = true;
    let mut config_dirty = true;
    let mut refined_bitrate_active = false;
    let mut raw_bgra = Vec::new();
    let mut scaled_bgra = Vec::new();
    let mut jpeg_bgra = Vec::new();
    let mut prev_scaled = Vec::new();
    let (mut y_plane, mut u_plane, mut v_plane) = (Vec::new(), Vec::new(), Vec::new());

    loop {
        // 1. Wait until a frame is requested (`next_pending > 0`) or stdin closes.
        let (closed, mut force_key, pending_rate, pending_bounds) = {
            let mut s = control.state.lock().unwrap();
            while !s.closed && s.next_pending == 0 {
                s = control.cv.wait(s).unwrap();
            }
            let closed = s.closed;
            let fk = std::mem::take(&mut s.force_keyframe);
            let pr = s.rate.take();
            let pb = s.bounds.take();
            (closed, fk, pr, pb)
        };
        if closed {
            break;
        }

        // 2. Apply hot bitrate change without restarting encoder.
        if let Some(bps) = pending_rate {
            normal_bitrate = bps.clamp(encode::MIN_BITRATE, encode::MAX_BITRATE);
            if let Some(ref mut enc) = h264 {
                let _ = enc.set_bitrate(normal_bitrate);
                refined_bitrate_active = false;
            }
        }

        // 3. Apply bounds / region change.
        if let Some((new_mw, new_mh, new_reg)) = pending_bounds {
            max_w = new_mw;
            max_h = new_mh;
            let (rect, norm_reg) = match new_reg {
                Some(r) => {
                    let (rect, norm) = region::crop(r, src_w, src_h);
                    (rect, Some(norm))
                }
                None => ((0, 0, src_w, src_h), None),
            };
            crop_rect = rect;
            if norm_reg != sent_region {
                sent_region = norm_reg;
                region_dirty = true;
                force_key = true;
            }
            let (nw, nh) = diff::fitted_size(crop_rect.2, crop_rect.3, max_w, max_h);
            if nw != enc_w || nh != enc_h {
                enc_w = nw;
                enc_h = nh;
                config_dirty = true;
                force_key = true;
                prev_scaled.clear();
                if codec == "h264" {
                    if let Ok(e) = H264Encoder::new(enc_w, enc_h, normal_bitrate, enc_fps) {
                        h264 = Some(e);
                        refined_bitrate_active = false;
                    }
                }
            }
        }

        // 4. For X11: wait until damage, forced keyframe, config/region change, or 150ms still-refine due.
        let mut is_refine = false;
        if let Backend::X11(ref mut x11) = backend {
            loop {
                let now_ms = started.elapsed().as_secs_f64() * 1000.0;
                // Check for new control messages (close, keyframe, rate, bounds) without blocking.
                let (c_closed, c_has_ctrl, c_fk) = {
                    let mut s = control.state.lock().unwrap();
                    let has_ctrl = s.rate.is_some() || s.bounds.is_some();
                    let fk = if has_ctrl {
                        false
                    } else {
                        std::mem::take(&mut s.force_keyframe)
                    };
                    (s.closed, has_ctrl, fk)
                };
                if c_closed {
                    break;
                }
                if c_has_ctrl {
                    // Loop outer to apply rate/bounds immediately without losing force_keyframe.
                    break;
                }
                if c_fk {
                    force_key = true;
                }

                let (damaged, cursor_changed) = x11.poll_events();
                if codec == "h264" {
                    if let Some(ci) = x11.query_cursor(cursor_changed || first_frame, !first_frame) {
                        if let Some(payload) = ci.custom_payload {
                            out.send(OUT_CURSOR_IMAGE, &payload);
                        }
                        out.json(
                            OUT_CURSOR,
                            json!({ "x": ci.x, "y": ci.y, "shape": ci.shape }),
                        );
                    }
                }

                if first_frame || force_key || region_dirty || config_dirty {
                    break;
                }
                if damaged {
                    still_refiner.on_damage();
                    break;
                }
                if codec == "h264" && still_refiner.due(now_ms) {
                    is_refine = true;
                    break;
                }
                if !x11.has_damage() {
                    // Fallback when XDamage extension is absent: pace at ~30Hz and rely on 32x32 pixel diff.
                    thread::sleep(Duration::from_millis(33));
                    break;
                }

                // Sleep on X11 socket fd (0% CPU idle), capped at 25ms or still-refine deadline so
                // control messages (IN_KEYFRAME/IN_BOUNDS/EOF) are observed with low latency.
                let wait_ms = match still_refiner.wait_ms(now_ms) {
                    Some(w) => (w.ceil() as i32).clamp(1, 25),
                    None => 25,
                };
                let _ = x11.wait_fd(wait_ms);
            }
        }

        // Re-check if closed or control changed while waiting.
        {
            let mut s = control.state.lock().unwrap();
            if s.closed {
                break;
            }
            if s.rate.is_some() || s.bounds.is_some() {
                if force_key {
                    s.force_keyframe = true;
                }
                continue;
            }
        }

        // 5. Respect frame rate gate.
        let now_ms = started.elapsed().as_secs_f64() * 1000.0;
        if !first_frame && !force_key && !is_refine && !gate.open(now_ms) {
            let w = gate.wait_ms(now_ms).min(100.0);
            if w > 0.5 {
                thread::sleep(Duration::from_secs_f64(w / 1000.0));
            }
        }

        // 6. Capture screen BGRA (on Wayland, abortable if close/keyframe/rate/bounds arrive during copy_with_damage).
        let with_damage = !first_frame && !force_key && !region_dirty && !config_dirty;
        let overlay_cursor = codec == "jpeg";
        let should_abort = || {
            let s = control.state.lock().unwrap();
            s.closed || s.force_keyframe || s.rate.is_some() || s.bounds.is_some()
        };
        match backend.capture_bgra(&mut raw_bgra, with_damage, overlay_cursor, &should_abort) {
            Ok(true) => {}
            Ok(false) => {
                if force_key {
                    control.state.lock().unwrap().force_keyframe = true;
                }
                continue;
            }
            Err(_) => break,
        }

        // 7. Crop and scale to even output dimensions.
        diff::crop_scale_bgra(
            &raw_bgra,
            src_w,
            src_h,
            crop_rect,
            enc_w,
            enc_h,
            &mut scaled_bgra,
        );

        // 8. 32x32 dirty-tile pixel diff: skip encoding if pixels are identical and not forced.
        if !first_frame
            && !force_key
            && !is_refine
            && !config_dirty
            && !region_dirty
            && !diff::has_dirty_tile(&prev_scaled, &scaled_bgra, enc_w as usize, enc_h as usize)
        {
            continue;
        }

        // Bail out before emitting if stdin closed while capturing.
        if control.state.lock().unwrap().closed {
            break;
        }

        // 9. Emit message 7 (`region`) before config/frame if region changed.
        if region_dirty {
            out.json(OUT_REGION, region::said(sent_region));
            region_dirty = false;
        }

        let now_ms = started.elapsed().as_secs_f64() * 1000.0;
        let ts_us = started.elapsed().as_micros() as u64;

        // 10. Encode and emit; only consume `next_pending` once a non-empty frame is actually emitted.
        let emitted_frame;
        if let Some(ref mut enc) = h264 {
            // On-demand IDR only (no 10 s periodic IDR spikes).
            let want_key = first_frame || force_key;
            if is_refine {
                let refine_bps = ((normal_bitrate as u64) * 115 / 100).min(encode::MAX_BITRATE as u64) as u32;
                let _ = enc.set_bitrate(refine_bps);
                refined_bitrate_active = true;
            } else if refined_bitrate_active {
                let _ = enc.set_bitrate(normal_bitrate);
                refined_bitrate_active = false;
            }

            diff::bgra_to_i420(
                &scaled_bgra,
                enc_w as usize,
                enc_h as usize,
                &mut y_plane,
                &mut u_plane,
                &mut v_plane,
            );
            match enc.encode_i420(&y_plane, &u_plane, &v_plane, want_key) {
                Ok((pic, enc_cfg_changed)) => {
                    if config_dirty || enc_cfg_changed {
                        if let Some(avcc) = enc.avcc() {
                            out.send(OUT_CONFIG, &protocol::encode_config(enc_w, enc_h, &avcc));
                            config_dirty = false;
                        }
                    }
                    if !pic.data.is_empty() {
                        out.send(OUT_FRAME, &protocol::encode_frame(pic.key, ts_us, &pic.data));
                        emitted_frame = true;
                        let after_ms = started.elapsed().as_secs_f64() * 1000.0;
                        if is_refine {
                            still_refiner.on_refined();
                        } else if !pic.key {
                            still_refiner.on_encoded(after_ms, normal_bitrate < 4_000_000);
                        } else {
                            still_refiner.on_refined();
                        }
                    } else {
                        // Do not consume `next_pending`; retry on next iteration with a forced IDR.
                        control.state.lock().unwrap().force_keyframe = true;
                        continue;
                    }
                }
                Err(_) => break,
            }
        } else {
            // JPEG stream: keep cursor-free `scaled_bgra` intact for `prev_scaled`, and blend cursor
            // into a separate scratch buffer `jpeg_bgra` before encoding.
            jpeg_bgra.resize(scaled_bgra.len(), 0);
            jpeg_bgra.copy_from_slice(&scaled_bgra);
            if let Backend::X11(ref mut x11) = backend {
                if let Some(ci) = x11.query_cursor(false, false) {
                    if !ci.rgba.is_empty() && ci.width > 0 && ci.height > 0 {
                        let cx = ((ci.x * src_w as f64) - crop_rect.0 as f64)
                            * (enc_w as f64 / crop_rect.2.max(1) as f64)
                            - ci.hot_x as f64;
                        let cy = ((ci.y * src_h as f64) - crop_rect.1 as f64)
                            * (enc_h as f64 / crop_rect.3.max(1) as f64)
                            - ci.hot_y as f64;
                        diff::blend_cursor_bgra(
                            &mut jpeg_bgra,
                            enc_w,
                            enc_h,
                            &ci.rgba,
                            ci.width,
                            ci.height,
                            cx.round() as i32,
                            cy.round() as i32,
                        );
                    }
                }
            }
            if config_dirty {
                out.send(OUT_CONFIG, &protocol::encode_config(enc_w, enc_h, &[]));
                config_dirty = false;
            }
            match encode::encode_jpeg_bgra(&jpeg_bgra, enc_w, enc_h, 80) {
                Ok(jpeg) => {
                    out.send(OUT_FRAME, &protocol::encode_frame(true, ts_us, &jpeg));
                    emitted_frame = true;
                }
                Err(_) => break,
            }
        }

        if emitted_frame {
            let mut s = control.state.lock().unwrap();
            if s.next_pending > 0 {
                s.next_pending -= 1;
            }
        }

        // Save cursor-free `scaled_bgra` so JPEG cursor compositing never pollutes dirty-tile diffing.
        prev_scaled.resize(scaled_bgra.len(), 0);
        prev_scaled.copy_from_slice(&scaled_bgra);
        gate.went(now_ms);
        first_frame = false;
    }

    input_queue.cancel();
    let _ = input_thread.join();
    let _ = reader_thread.join();
}
