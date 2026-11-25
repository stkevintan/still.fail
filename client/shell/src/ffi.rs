//! C ABI exports for `stillfail-shell` (called from Hermes/C++ and MoonBit hosts).

use std::ffi::{CStr, c_char, c_void};
use std::path::PathBuf;

use crate::{Handle, Shell, stats_json, tally};

/// `complete(ctx, id, json, json_len, error, error_len, bytes, bytes_len, has_bytes)`: an operation's answer, its JSON
/// (when it succeeded) or its error, and its bytes if it has any. Called on any thread.
pub type Complete = extern "C" fn(*mut c_void, u64, *const u8, usize, *const u8, usize, *const u8, usize, u8);

pub(crate) struct Ctx(pub(crate) *mut c_void);
// SAFETY: the engine's context is made to be told from any thread (the C++ side queues what it is given).
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

/// `say(ctx, json, json_len, bytes, bytes_len)`: a message for the app, as the core says one (its JSON, and the bytes
/// beside it, or none: `bytes` null), straight from the shell (a remote screen's frames: `istream.tap`). Any thread.
pub type Say = extern "C" fn(*mut c_void, *const u8, usize, *const u8, usize);

/// `media(ctx, call, kind, key, seq, ts, bytes, bytes_len)`: a tapped remote screen's record offered to the app's host as
/// it is, before it is said (`Say`): a video frame (kind 2: `key`, `ts`, its access unit), a sound packet (6: `ts`, its
/// PCM), or a config (1) or the sound's (5), offered only to be seen (the host stops taking that view's records until
/// the app has taken it). `seq` numbers every record said of any tapped view, from 1. 1: the host took it (decoded,
/// played and acknowledged there), nothing said; 0: said to the app as before. Any of the shell's threads, a view's
/// records in order.
pub type Media = extern "C" fn(*mut c_void, u64, u8, u8, u64, u64, *const u8, usize) -> u8;

/// Starts a shell keeping its files in `data_dir`. Null when it cannot (the directory cannot be made).
///
/// # Safety
/// `data_dir` is a NUL-terminated string; `complete` may be called with `ctx` from any thread until `sf_shell_stop`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_start(data_dir: *const c_char, complete: Complete, ctx: *mut c_void) -> *mut Shell {
    // SAFETY: the caller gives a NUL-terminated string.
    let dir = unsafe { CStr::from_ptr(data_dir) }.to_string_lossy().into_owned();
    match Shell::start(PathBuf::from(dir), complete, ctx) {
        Ok(shell) => Box::into_raw(Box::new(shell)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Starts operation `id`.
///
/// # Safety
/// `shell` is from `sf_shell_start`; `op` NUL-terminated; `json`/`bytes` valid for their lengths (`bytes` read only
/// when `has_bytes`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_call(shell: *const Shell, id: u64, op: *const c_char, json: *const u8, json_len: usize, bytes: *const u8, bytes_len: usize, has_bytes: u8) {
    // SAFETY: as documented.
    let (shell, op, json) = unsafe { (&*shell, CStr::from_ptr(op).to_string_lossy().into_owned(), std::slice::from_raw_parts(json, json_len)) };
    let bytes = (has_bytes != 0).then(|| if bytes_len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(bytes, bytes_len) }.to_vec() });
    shell.call(id, op, json, bytes);
}

/// An operation answered at once: its JSON (`{value}` or `{error}`), to be let go with `sf_free`.
///
/// # Safety
/// As `sf_shell_call`; `out_len` is written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_call_sync(shell: *const Shell, op: *const c_char, json: *const u8, json_len: usize, out_len: *mut usize) -> *mut u8 {
    // SAFETY: as documented.
    let (shell, op, json) = unsafe { (&*shell, CStr::from_ptr(op).to_string_lossy().into_owned(), std::slice::from_raw_parts(json, json_len)) };
    let mut out = shell.call_sync(&op, json).into_boxed_slice();
    unsafe { *out_len = out.len() };
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);
    ptr
}

/// What the shells have been asked so far (`{calls: {op: [started, unanswered]}, handles: {kind: n}, sqls}`), as JSON
/// to be let go with `sf_free`.
///
/// # Safety
/// `out_len` is written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_stats(out_len: *mut usize) -> *mut u8 {
    let mut out = serde_json::to_vec(&stats_json()).unwrap_or_default().into_boxed_slice();
    unsafe { *out_len = out.len() };
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);
    ptr
}

/// # Safety
/// `ptr`/`len` from `sf_shell_call_sync` or `sf_shell_stats`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        // SAFETY: made by `sf_shell_call_sync` from a boxed slice of this length.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

/// Where a message for the app goes straight from the shell (a remote screen's frames, `istream.tap`): `say` with
/// `ctx`, from any of the shell's threads, until `sf_shell_stop`.
///
/// # Safety
/// `shell` from `sf_shell_start`; `say` may be called with `ctx` from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_set_say(shell: *const Shell, say: Say, ctx: *mut c_void) {
    // SAFETY: made by `sf_shell_start`.
    let shell = unsafe { &*shell };
    *shell.inner.say.lock().unwrap() = Some((say, Ctx(ctx)));
}

/// Where a tapped remote screen's records are offered before they are said to the app (`Media`): `media` with `ctx`,
/// from any of the shell's threads, until `sf_shell_stop`.
///
/// # Safety
/// `shell` from `sf_shell_start`; `media` may be called with `ctx` from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_set_media(shell: *const Shell, media: Media, ctx: *mut c_void) {
    // SAFETY: made by `sf_shell_start`.
    let shell = unsafe { &*shell };
    *shell.inner.media.lock().unwrap() = Some((media, Ctx(ctx)));
}

/// A remote screen's frame `ts` acknowledged by the app straight to the station, on the stream its view `call` is
/// tapped on (`istream.tap`), not through the core (an ack frame: screen-frames.ts ackFrame); 0 when no tapped stream
/// is that view's (the app asks the core then).
///
/// # Safety
/// `shell` from `sf_shell_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_screen_ack(shell: *const Shell, call: u64, ts: f64) -> u8 {
    // SAFETY: forwarded with the same `shell` contract.
    unsafe { sf_shell_screen_ack_wait(shell, call, ts, 0) }
}

/// Same as `sf_shell_screen_ack`, carrying the viewer's hold time `wait_us` (µs) before the frame was shown or dropped.
/// When the view receives media datagrams from a station that advertises datagram ACK support, sends an unreliable
/// `KIND_ACK` datagram synchronously with zero head-of-line blocking; otherwise falls back to the reliable stream.
///
/// # Safety
/// `shell` from `sf_shell_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_screen_ack_wait(shell: *const Shell, call: u64, ts: f64, wait_us: u32) -> u8 {
    if shell.is_null() {
        return 0;
    }
    // SAFETY: made by `sf_shell_start`.
    let shell = unsafe { &*shell };
    screen_ack(shell, call, ts, wait_us)
}

pub(crate) fn screen_ack(shell: &Shell, call: u64, ts: f64, wait_us: u32) -> u8 {
    let halves = shell.inner.handles.lock().unwrap().values().find_map(|h| match h {
        Handle::IStream(halves) if halves.tap.lock().unwrap().as_ref().is_some_and(|t| t.call == call) => Some(halves.clone()),
        _ => None,
    });
    let Some(halves) = halves else { return 0 };
    let ts_u64 = ts.max(0.0).floor() as u64;
    if let Some(target) = halves.ack_dgram.lock().unwrap().as_ref() {
        if target.peer_capable.load(std::sync::atomic::Ordering::Relaxed) {
            let dgram = crate::screen_dgram::ack_bytes(target.token, ts_u64, wait_us);
            if target.conn.send_datagram(bytes::Bytes::copy_from_slice(&dgram)).is_ok() {
                tally("tap.acks");
                tally("tap.acks.dgram");
                return 1;
            }
        }
    }
    let frame = if wait_us == 0 {
        let mut frame = Vec::with_capacity(13);
        frame.extend_from_slice(&[crate::screen_dgram::FRAME_ACK, 0, 0, 0, 8]);
        frame.extend_from_slice(&ts_u64.to_be_bytes());
        frame
    } else {
        crate::screen_dgram::ack_frame_bytes(ts_u64, wait_us).to_vec()
    };
    tally("tap.acks");
    shell.runtime.spawn(async move {
        if let Some(send) = halves.send.lock().await.as_mut() {
            let _ = send.write_all(&frame).await;
        }
    });
    1
}

/// The app's input to a remote screen (`json`, `len` bytes: what `screen.input` says in `input`) sent straight to its
/// station, on the stream its view `call` is tapped on (`istream.tap`), not through the core (an input frame:
/// screen-frames.ts inputFrame), in order after what was sent so before (istream.rs `InputLine`). Only a pointer's, the
/// wheel's, a key's or a controller's, checked as the core checks them; 0 for any other, one not sound, or where no
/// tapped stream is that view's (the app asks the core then).
///
/// # Safety
/// `shell` from `sf_shell_start`; `json` valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_screen_input(shell: *const Shell, call: u64, json: *const u8, len: usize) -> u8 {
    if shell.is_null() || json.is_null() || len == 0 || len > 65536 {
        return 0;
    }
    // SAFETY: as documented.
    let (shell, json) = unsafe { (&*shell, std::slice::from_raw_parts(json, len)) };
    screen_input(shell, call, json)
}

pub(crate) fn screen_input(shell: &Shell, call: u64, json: &[u8]) -> u8 {
    let Some(input) = serde_json::from_slice(json).ok().as_ref().and_then(crate::istream::checked_input) else { return 0 };
    let halves = shell.inner.handles.lock().unwrap().values().find_map(|h| match h {
        Handle::IStream(halves) if halves.tap.lock().unwrap().as_ref().is_some_and(|t| t.call == call) => Some(halves.clone()),
        _ => None,
    });
    let Some(halves) = halves else { return 0 };
    let line = {
        let mut lines = shell.inner.inputs.lock().unwrap();
        // (those of views gone let go)
        lines.retain(|_, l| l.halves_alive());
        match lines.get(&call).filter(|l| l.is_of(&halves)) {
            Some(l) => l.clone(),
            None => {
                let l = std::sync::Arc::new(crate::istream::InputLine::new(&halves));
                lines.insert(call, l.clone());
                l
            }
        }
    };
    tally("tap.inputs");
    line.send(input, shell.runtime.handle());
    1
}

/// Stops a shell: what is under way is dropped, its answers never come.
///
/// # Safety
/// `shell` from `sf_shell_start`, not used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sf_shell_stop(shell: *mut Shell) {
    if !shell.is_null() {
        // SAFETY: made by `sf_shell_start`.
        let shell = unsafe { Box::from_raw(shell) };
        shell.runtime.shutdown_background();
    }
}

/// The viewer's time zone at `at_ms` (minutes east of UTC), from the C library, which on Android follows the system's
/// zone setting and its DST rules (as the Rust core had them).
#[cfg(not(windows))]
#[unsafe(no_mangle)]
pub extern "C" fn sf_utc_offset_min(at_ms: f64) -> i32 {
    let at = (at_ms / 1000.0).floor() as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the call; localtime_r is the thread-safe variant.
    if unsafe { libc::localtime_r(&at, &mut tm) }.is_null() {
        return 0;
    }
    (tm.tm_gmtoff / 60) as i32
}

/// The same on Windows (the mbui app's core), whose C library has neither localtime_r nor tm_gmtoff: the local time the
/// CRT makes of `at_ms` (the system's zone and its DST rules, or $TZ when set), read back as if it were UTC, less
/// `at_ms`. 0 where the CRT has no local time (before 1970).
#[cfg(windows)]
#[unsafe(no_mangle)]
pub extern "C" fn sf_utc_offset_min(at_ms: f64) -> i32 {
    unsafe extern "C" {
        fn _localtime64_s(tm: *mut libc::tm, time: *const i64) -> i32;
        fn _mkgmtime64(tm: *mut libc::tm) -> i64;
    }
    let at = (at_ms / 1000.0).floor() as i64;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the calls.
    if unsafe { _localtime64_s(&mut tm, &at) } != 0 {
        return 0;
    }
    let local_as_utc = unsafe { _mkgmtime64(&mut tm) };
    if local_as_utc == -1 {
        return 0;
    }
    ((local_as_utc - at) / 60) as i32
}
