//! Iroh QUIC stream lifecycle (`istream.*`), framed Unix-socket piping (`istream.pipe`, `istream.hand`), and routed
//! stream handover (`conn.hand`).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use iroh::endpoint::{Connection, RecvStream, SendStream};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::net::{SocketRead, SocketWrite, open_unix, tell_unix};
use crate::screen_dgram::{AckRx, KEYFRAME_FRAME, MediaIn, MediaOut, MediaRx};
use crate::screen_tap::ScreenTap;
use crate::{Answer, Done, Handle, Inner, err, id_of, str_of, tally};

/// Lock-free target for sending unreliable `KIND_ACK` datagrams directly from `sf_shell_screen_ack_wait`.
pub(crate) struct AckTarget {
    pub(crate) conn: Connection,
    pub(crate) token: u32,
    pub(crate) peer_capable: Arc<AtomicBool>,
}

/// The two halves of an iroh stream, and the reads waiting on it: a reset wakes them first (as the addon's).
pub(crate) struct Halves {
    /// The connection it is on: it goes when that one closes.
    pub(crate) conn: u64,
    pub(crate) send: tokio::sync::Mutex<Option<SendStream>>,
    pub(crate) recv: tokio::sync::Mutex<Option<RecvStream>>,
    pub(crate) reset: tokio::sync::watch::Sender<bool>,
    /// Read to its end; finished (or no sending half). Both: the handle goes.
    pub(crate) ended: std::sync::atomic::AtomicBool,
    pub(crate) finished: std::sync::atomic::AtomicBool,
    /// A remote screen's view, tapped (`istream.tap`): its frames read here, the picture's and the sound's said to the
    /// app as they come, the rest left for the core to read.
    pub(crate) tap: Mutex<Option<ScreenTap>>,
    /// A remote screen's view this end sends: its video and audio frames go as datagrams (`istream.mediaDatagrams`).
    pub(crate) media_out: tokio::sync::Mutex<Option<MediaOut>>,
    /// A remote screen's view this end receives: its frames that come as datagrams, put back among the stream's
    /// (`istream.receiveMediaDatagrams`).
    pub(crate) media_in: tokio::sync::Mutex<Option<MediaRx>>,
    /// Client-side datagram ACK fast-path target, set by `istream.receiveMediaDatagrams`.
    pub(crate) ack_dgram: Mutex<Option<AckTarget>>,
    /// Station-side datagram ACK receiver, set by `istream.mediaDatagrams` and injected at frame boundaries on read/pipe.
    pub(crate) ack_in: tokio::sync::Mutex<Option<AckRx>>,
    pub(crate) ack_ready: tokio::sync::watch::Sender<bool>,
}

impl Halves {
    /// `bytes` written on its sending half: as they are, or through its view's datagrams where it has them.
    pub(crate) async fn write_out(&self, send: &mut SendStream, bytes: &[u8]) -> Result<(), String> {
        match self.media_out.lock().await.as_mut() {
            Some(media) => media.write(send, bytes).await,
            None => send.write_all(bytes).await.map_err(err),
        }
    }
}

/// A remote screen's input frame (client/core-ts screen-frames.ts `INPUT`).
const FRAME_INPUT: u8 = 16;
/// The longest of a pointer's moves (screens.ts `checkInput`, the station's `parseInput`).
const MOVE_MOST: f64 = 10_000.0;

/// What the app sends a tapped view straight to its station (`sf_shell_screen_input`), past the core: a game's pointer,
/// keys, wheel and controllers, which wait on nothing the core's thread is busy with. Sent in the order they came, by
/// one task at a time, each written whole before the next; a pointer's move still waiting taken over by the next of
/// the same buttons (a relative one's distance added to it), so a slow stream builds no backlog of moves ahead of a
/// press, and a press, a key or a release never passes another or is dropped.
pub(crate) struct InputLine {
    halves: std::sync::Weak<Halves>,
    queue: Mutex<InputQueue>,
}

#[derive(Default)]
struct InputQueue {
    waiting: std::collections::VecDeque<Value>,
    /// A task writes what waits.
    draining: bool,
}

/// `v` checked and put as the core puts it (screens.ts `checkInput`), where it is one sent straight: a pointer's,
/// the wheel's, a key's or a controller's. None: the core's (any other, or one it refuses with its words).
pub(crate) fn checked_input(v: &Value) -> Option<Value> {
    let o = v.as_object()?;
    let num = |k: &str| o.get(k).and_then(Value::as_f64).filter(|n| n.is_finite());
    let unit = |k: &str| num(k).map(|n| n.clamp(0.0, 1.0));
    match o.get("t")?.as_str()? {
        "pointer" => {
            let kind = o.get("kind")?.as_str().filter(|k| matches!(*k, "down" | "up" | "move"))?;
            let (x, y) = (unit("x")?, unit("y")?);
            let buttons = num("buttons").filter(|b| *b >= 0.0).map_or(0, |b| (b.floor() as i64) & 31);
            let relative = o.get("relative") == Some(&Value::Bool(true));
            let mut e = json!({ "t": "pointer", "kind": kind, "x": x, "y": y, "buttons": buttons });
            if kind == "move" {
                match (num("dx"), num("dy")) {
                    (Some(dx), Some(dy)) => {
                        e["dx"] = json!(dx.clamp(-MOVE_MOST, MOVE_MOST));
                        e["dy"] = json!(dy.clamp(-MOVE_MOST, MOVE_MOST));
                    }
                    // (no distance: no `relative` either, as the core has it)
                    _ => return Some(e),
                }
            }
            if relative {
                e["relative"] = json!(true);
            }
            Some(e)
        }
        "wheel" => Some(json!({ "t": "wheel", "x": unit("x")?, "y": unit("y")?, "dx": num("dx")?, "dy": num("dy")? })),
        "key" => {
            const KEY_MAX: usize = 64;
            let kind = o.get("kind")?.as_str().filter(|k| matches!(*k, "down" | "up"))?;
            let key = o.get("key")?.as_str().filter(|k| !k.is_empty() && k.encode_utf16().count() <= KEY_MAX)?;
            let code = o.get("code").and_then(Value::as_str).filter(|c| c.encode_utf16().count() <= KEY_MAX).unwrap_or("");
            let mods = num("mods").filter(|m| *m >= 0.0).map_or(0, |m| (m.floor() as i64) & 15);
            Some(json!({ "t": "key", "kind": kind, "key": key, "code": code, "mods": mods }))
        }
        "gamepad" => {
            let index = num("index").filter(|i| i.fract() == 0.0 && (0.0..=3.0).contains(i))? as i64;
            if o.get("connected") == Some(&Value::Bool(false)) {
                return Some(json!({ "t": "gamepad", "index": index, "connected": false, "buttons": 0, "lx": 0, "ly": 0, "rx": 0, "ry": 0, "lt": 0, "rt": 0 }));
            }
            let n = |k: &str, lo: f64| num(k).map_or(0.0, |v| v.clamp(lo, 1.0));
            let buttons = num("buttons").filter(|b| *b >= 0.0).map_or(0, |b| (b.floor() as i64) & 0x1ffff);
            Some(json!({ "t": "gamepad", "index": index, "connected": true, "buttons": buttons, "lx": n("lx", -1.0), "ly": n("ly", -1.0), "rx": n("rx", -1.0), "ry": n("ry", -1.0), "lt": n("lt", 0.0), "rt": n("rt", 0.0) }))
        }
        _ => None,
    }
}

/// A number as JavaScript's JSON.stringify writes it (a whole one without `.0`).
fn js_number(n: f64) -> String {
    if n == n.trunc() && n.abs() < 1e21 {
        format!("{}", n as i64)
    } else {
        serde_json::Number::from_f64(n).map_or_else(|| "null".into(), |n| n.to_string())
    }
}

/// `input` (checked) as the core's JSON.stringify writes it: its fields in the order `checkInput` makes them.
fn input_json(input: &Value) -> String {
    let order: &[&str] = match input["t"].as_str().unwrap_or("") {
        "pointer" => &["t", "kind", "x", "y", "buttons", "dx", "dy", "relative"],
        "wheel" => &["t", "x", "y", "dx", "dy"],
        "key" => &["t", "kind", "key", "code", "mods"],
        _ => &["t", "index", "connected", "buttons", "lx", "ly", "rx", "ry", "lt", "rt"],
    };
    let mut out = String::from("{");
    for k in order {
        let Some(v) = input.get(*k) else { continue };
        if out.len() > 1 {
            out.push(',');
        }
        out.push_str(&format!("\"{k}\":"));
        match v {
            Value::Number(n) => out.push_str(&js_number(n.as_f64().unwrap_or(0.0))),
            v => out.push_str(&v.to_string()),
        }
    }
    out.push('}');
    out
}

/// `input` (checked) as a frame on the view's stream, byte for byte the core's (screen-frames.ts `inputFrame`).
pub(crate) fn input_frame(input: &Value) -> Vec<u8> {
    let json = input_json(input).into_bytes();
    let mut f = Vec::with_capacity(5 + json.len());
    f.push(FRAME_INPUT);
    f.extend((json.len() as u32).to_be_bytes());
    f.extend(json);
    f
}

/// `next` (checked) taken into `last`, a pointer's move waiting, where it is a move of the same buttons, both relative
/// or neither: the newest place, and a relative one's distance added (while it stays within `MOVE_MOST`).
fn merged(last: &mut Value, next: &Value) -> bool {
    let is_move = |v: &Value| v["t"] == "pointer" && v["kind"] == "move";
    if !is_move(last) || !is_move(next) || last["buttons"] != next["buttons"] || last.get("relative") != next.get("relative") || last.get("dx").is_some() != next.get("dx").is_some() {
        return false;
    }
    if next.get("relative").is_some() {
        let (dx, dy) = (last["dx"].as_f64().unwrap_or(0.0) + next["dx"].as_f64().unwrap_or(0.0), last["dy"].as_f64().unwrap_or(0.0) + next["dy"].as_f64().unwrap_or(0.0));
        if dx.abs() > MOVE_MOST || dy.abs() > MOVE_MOST {
            return false;
        }
        *last = next.clone();
        last["dx"] = json!(dx);
        last["dy"] = json!(dy);
    } else {
        *last = next.clone();
    }
    true
}

impl InputLine {
    pub(crate) fn new(halves: &Arc<Halves>) -> InputLine {
        InputLine { halves: Arc::downgrade(halves), queue: Mutex::default() }
    }

    pub(crate) fn halves_alive(&self) -> bool {
        self.halves.strong_count() > 0
    }

    pub(crate) fn is_of(&self, halves: &Arc<Halves>) -> bool {
        std::ptr::eq(self.halves.as_ptr(), Arc::as_ptr(halves))
    }

    /// `input` (checked) to be sent after what waits; a task started to send it where none sends.
    pub(crate) fn send(self: &Arc<Self>, input: Value, runtime: &tokio::runtime::Handle) {
        {
            let mut q = self.queue.lock().unwrap();
            if q.waiting.back_mut().is_some_and(|last| merged(last, &input)) {
                tally("tap.inputs.merged");
            } else {
                q.waiting.push_back(input);
            }
            if q.draining {
                return;
            }
            q.draining = true;
        }
        let line = self.clone();
        runtime.spawn(async move { line.drain().await });
    }

    /// What waits written, one at a time, till none does (or the stream is gone: what waits dropped).
    async fn drain(&self) {
        loop {
            let next = {
                let mut q = self.queue.lock().unwrap();
                match q.waiting.pop_front() {
                    Some(v) => v,
                    None => {
                        q.draining = false;
                        return;
                    }
                }
            };
            let frame = input_frame(&next);
            let wrote = match self.halves.upgrade() {
                Some(halves) => match halves.send.lock().await.as_mut() {
                    Some(send) => send.write_all(&frame).await.is_ok(),
                    None => false,
                },
                None => false,
            };
            if !wrote {
                let mut q = self.queue.lock().unwrap();
                q.waiting.clear();
                q.draining = false;
                return;
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn waiting(&self) -> Vec<Value> {
        self.queue.lock().unwrap().waiting.iter().cloned().collect()
    }
}

/// A stream carried whole into a socket (`istream.pipe`): each piece of it as a frame, its length (4 bytes, big-endian)
/// then its bytes; its end, or what failed it (the frame's tag, then the words' length and the words), as one of these.
pub(crate) const PIPE_END: u32 = 0xFFFF_FFFE;
pub(crate) const PIPE_FAILED: u32 = 0xFFFF_FFFD;
/// A frame no longer than this (the longest a read gives, and what the other side sends).
const PIPE_MOST: u32 = 1 << 20;

/// What a stream's other end sent first, up to its first line's end (16 KiB at most; less where it ended or failed):
/// all of what was read, to be carried on before the rest (a frame of `pipe`'s).
async fn read_head_line(halves: &Halves) -> Vec<u8> {
    let mut read = Vec::new();
    let mut buf = vec![0u8; 16 * 1024];
    let mut recv = halves.recv.lock().await;
    let Some(recv) = recv.as_mut() else { return read };
    while !read.contains(&b'\n') && read.len() < 16 * 1024 {
        match recv.read(&mut buf).await {
            Ok(Some(n)) => read.extend_from_slice(&buf[..n]),
            _ => break,
        }
    }
    read
}

/// A request's route as `conn.hand`'s `routes` say them: its head line's method (GET where none) and its path without
/// its query. None where the line is not one (wire.ts: a JSON head line).
fn route_of(read: &[u8]) -> Option<String> {
    let end = read.iter().position(|&b| b == b'\n')?;
    let head: Value = serde_json::from_slice(&read[..end]).ok()?;
    let method = head.get("method").and_then(Value::as_str).unwrap_or("GET").to_uppercase();
    let path = head.get("path")?.as_str()?;
    Some(format!("{method} {}", path.split('?').next().unwrap_or(path)))
}

/// Whether route `r` (`"GET /a/b"`) is one `pattern` names: the same method and as many segments, each the same or `*`
/// (any one, not empty).
fn route_matches(pattern: &str, r: &str) -> bool {
    let (mut p, mut r) = (pattern.split('/'), r.split('/'));
    loop {
        match (p.next(), r.next()) {
            (None, None) => return true,
            (Some("*"), Some(s)) if !s.is_empty() => {}
            (Some(a), Some(b)) if a == b => {}
            _ => return false,
        }
    }
}

/// Skip frame header (`kind == 3`) telling `Incoming` that stream `index` on connection `on` will not arrive on `path`.
fn skip_head(on: u64, id: u64, index: u64) -> [u8; 25] {
    let mut skip = [0u8; 25];
    skip[..8].copy_from_slice(&on.to_be_bytes());
    skip[8..16].copy_from_slice(&id.to_be_bytes());
    skip[16] = 3;
    skip[17..25].copy_from_slice(&index.to_be_bytes());
    skip
}

/// When an inbound QUIC stream could not be handed to `path`, keep `Incoming` from head-of-line deadlocking:
/// - Stream 0 is the credential stream and cannot be skipped, so close the connection immediately.
/// - For stream `index > 0`, send a `kind == 3` skip frame; if that also fails, close the connection so subsequent
///   requests fail fast instead of hanging until their 60 s timeout.
async fn skip_or_close(conn: &iroh::endpoint::Connection, path: &str, on: u64, id: u64, index: u64) {
    if index == 0 {
        conn.close(0u32.into(), b"stream not given");
        return;
    }
    let skip = skip_head(on, id, index);
    if let Err(e) = tell_unix(path, &skip).await {
        crate::log::info(&format!("mesh: a stream's index not told: {e}"));
        conn.close(0u32.into(), b"stream index lost");
    }
}

impl Inner {
    fn istream_done(&self, id: u64, halves: &Halves) {
        if halves.ended.load(Ordering::Relaxed) && halves.finished.load(Ordering::Relaxed) {
            self.drop_handle(id);
        }
    }

    /// A stream given to the Unix socket at `path` (`istream.hand`): connected, `head` written, carried. Reset where
    /// the socket does not take it.
    async fn hand(self: &Arc<Self>, id: u64, halves: Arc<Halves>, path: &str, head: &[u8]) -> Result<(), String> {
        match open_unix(path, head).await {
            Ok((read, write)) => {
                self.pipe(id, halves, read, write).await;
                Ok(())
            }
            Err(e) => {
                self.reset_stream(id).await;
                Err(e)
            }
        }
    }

    /// A stream ended at once both ways, and let go (`istream.reset`'s).
    async fn reset_stream(&self, id: u64) {
        if let Some(Handle::IStream(halves)) = self.drop_handle(id) {
            let _ = halves.reset.send(true);
            if let Some(send) = halves.send.lock().await.as_mut() {
                let _ = send.reset(0u32.into());
            }
            if let Some(recv) = halves.recv.lock().await.as_mut() {
                let _ = recv.stop(0u32.into());
            }
        }
    }

    /// A stream carried whole into a socket, both ways (`istream.pipe`, which says how), till both ways are done.
    async fn pipe(&self, id: u64, halves: Arc<Halves>, read: SocketRead, write: SocketWrite) {
        let down = async {
            let mut write = write.lock().await;
            let mut reset = halves.reset.subscribe();
            let mut ack_ready = halves.ack_ready.subscribe();
            let mut buf = vec![0u8; 4 + 256 * 1024];
            let mut out = Vec::new();
            loop {
                if *reset.borrow() {
                    break;
                }
                if *ack_ready.borrow() {
                    let mut ack_guard = halves.ack_in.lock().await;
                    if let Some(acks) = ack_guard.as_mut() {
                        if acks.at_boundary() {
                            acks.drain_into(&mut out);
                        }
                        if !out.is_empty() {
                            let len = (out.len() as u32).to_be_bytes();
                            if write.write_all(&len).await.is_err() || write.write_all(&out).await.is_err() {
                                break;
                            }
                            out.clear();
                            continue;
                        }
                        let mut recv = halves.recv.lock().await;
                        let Some(recv) = recv.as_mut() else { break };
                        tokio::select! {
                            read = recv.read(&mut buf[4..]) => match read {
                                Ok(Some(n)) => {
                                    let chunk = &buf[4..4 + n];
                                    match acks.stream(chunk) {
                                        Some(b) => {
                                            out.extend_from_slice(&chunk[..b]);
                                            acks.drain_into(&mut out);
                                            out.extend_from_slice(&chunk[b..]);
                                        }
                                        None => out.extend_from_slice(chunk),
                                    }
                                }
                                Ok(None) => {
                                    halves.ended.store(true, Ordering::Relaxed);
                                    let _ = write.write_all(&PIPE_END.to_be_bytes()).await;
                                    break;
                                }
                                Err(e) => {
                                    let words = e.to_string();
                                    let mut failed = PIPE_FAILED.to_be_bytes().to_vec();
                                    failed.extend((words.len() as u32).to_be_bytes());
                                    failed.extend(words.as_bytes());
                                    let _ = write.write_all(&failed).await;
                                    break;
                                }
                            },
                            d = acks.next() => acks.take_waiting(d),
                            _ = reset.changed() => break,
                        }
                        continue;
                    }
                }
                let read = {
                    let mut recv = halves.recv.lock().await;
                    // (one way: nothing comes)
                    let Some(recv) = recv.as_mut() else { break };
                    tokio::select! {
                        read = recv.read(&mut buf[4..]) => Some(read),
                        _ = ack_ready.changed() => None,
                        _ = reset.changed() => break,
                    }
                };
                let Some(read) = read else { continue };
                let frame: &[u8] = match read {
                    Ok(Some(n)) => {
                        buf[..4].copy_from_slice(&(n as u32).to_be_bytes());
                        &buf[..4 + n]
                    }
                    Ok(None) => {
                        halves.ended.store(true, Ordering::Relaxed);
                        let _ = write.write_all(&PIPE_END.to_be_bytes()).await;
                        break;
                    }
                    Err(e) => {
                        let words = e.to_string();
                        let mut failed = PIPE_FAILED.to_be_bytes().to_vec();
                        failed.extend((words.len() as u32).to_be_bytes());
                        failed.extend(words.as_bytes());
                        let _ = write.write_all(&failed).await;
                        break;
                    }
                };
                if write.write_all(frame).await.is_err() {
                    break;
                }
            }
            let _ = write.shutdown().await;
        };
        let up = async {
            let mut read = read.lock().await;
            let mut reset = halves.reset.subscribe();
            let mut head = [0u8; 4];
            let mut buf = Vec::new();
            let mut written_end = false;
            let finished = loop {
                if *reset.borrow() {
                    break false;
                }
                let ok = tokio::select! {
                    r = read.read_exact(&mut head) => r.is_ok(),
                    _ = reset.changed() => break false,
                };
                if !ok {
                    break false;
                }
                let n = u32::from_be_bytes(head);
                if n == PIPE_END {
                    break true;
                }
                if n > PIPE_MOST {
                    break false;
                }
                buf.resize(n as usize, 0);
                let ok = tokio::select! {
                    r = read.read_exact(&mut buf) => r.is_ok(),
                    _ = reset.changed() => break false,
                };
                if !ok {
                    break false;
                }
                let mut send = halves.send.lock().await;
                let Some(send) = send.as_mut() else { break false };
                let sent = tokio::select! {
                    r = halves.write_out(send, &buf) => r.is_ok(),
                    _ = reset.changed() => false,
                };
                if !sent {
                    // (reset by either end: the socket's frames go nowhere now)
                    written_end = true;
                    break false;
                }
            };
            if !written_end && !*reset.borrow() {
                let mut send = halves.send.lock().await;
                if let Some(send) = send.as_mut() {
                    if finished {
                        let _ = send.finish();
                    } else {
                        let _ = send.reset(0u32.into());
                    }
                }
            }
            halves.finished.store(true, Ordering::Relaxed);
        };
        tokio::join!(down, up);
        // Let go once both ways are done, unless its sending half is still to be asked when it is acknowledged.
        if halves.recv.lock().await.is_some() {
            self.istream_done(id, &halves);
        }
    }

    /// `istream.read` of a stream whose view's frames come as datagrams too: what the stream gives, with the frames made
    /// whole put in between two of its frames (or, tapped, said or kept by its tap as the stream's are), the station
    /// asked for a key frame where one could not be had.
    async fn read_with_datagrams(&self, id: u64, halves: &Arc<Halves>, media: &mut MediaRx, reset: &mut tokio::sync::watch::Receiver<bool>) -> Done {
        let mut buf = vec![0u8; 64 * 1024];
        let mut out = Vec::new();
        loop {
            {
                let mut tap = halves.tap.lock().unwrap();
                if let Some(tap) = tap.as_mut() {
                    if !out.is_empty() {
                        // (what was read before it was tapped)
                        tap.take(&std::mem::take(&mut out), self);
                    }
                    while let Some((kind, body)) = media.media.ready.pop_front() {
                        tap.whole(kind, &body, self);
                    }
                    if !tap.out.is_empty() {
                        return Ok(Answer::bytes(json!({}), std::mem::take(&mut tap.out)));
                    }
                } else {
                    if media.media.at_boundary() {
                        media.media.drain_into(&mut out);
                    }
                    if !out.is_empty() {
                        return Ok(Answer::bytes(json!({}), out));
                    }
                }
            }
            if media.media.take_keyframe(tokio::time::Instant::now()) {
                let halves = halves.clone();
                tokio::spawn(async move {
                    if let Some(send) = halves.send.lock().await.as_mut() {
                        let _ = send.write_all(&KEYFRAME_FRAME).await;
                    }
                });
                tally("dgram.keyframe");
            }
            let mut recv = halves.recv.lock().await;
            let Some(recv) = recv.as_mut() else { return Ok(Answer::json(json!({ "end": true }))) };
            let deadline = media.media.deadline();
            tokio::select! {
                read = recv.read(&mut buf) => match read.map_err(err)? {
                    Some(n) => {
                        let chunk = &buf[..n];
                        let boundary = media.media.stream(chunk, tokio::time::Instant::now());
                        let mut tap = halves.tap.lock().unwrap();
                        match (tap.as_mut(), boundary) {
                            (Some(tap), _) => tap.take(chunk, self),
                            (None, Some(b)) => {
                                out.extend_from_slice(&chunk[..b]);
                                media.media.drain_into(&mut out);
                                out.extend_from_slice(&chunk[b..]);
                            }
                            (None, None) => out.extend_from_slice(chunk),
                        }
                    }
                    None => {
                        // what is left (a frame cut short) the core's, which says so
                        let left = {
                            let mut tap = halves.tap.lock().unwrap();
                            match tap.as_mut() {
                                Some(tap) => {
                                    let mut left = std::mem::take(&mut tap.out);
                                    left.append(&mut tap.pending);
                                    left
                                }
                                None => std::mem::take(&mut out),
                            }
                        };
                        if !left.is_empty() {
                            return Ok(Answer::bytes(json!({}), left));
                        }
                        halves.ended.store(true, Ordering::Relaxed);
                        self.istream_done(id, halves);
                        return Ok(Answer::json(json!({ "end": true })));
                    }
                },
                d = media.next() => media.take_waiting(d, tokio::time::Instant::now()),
                _ = crate::screen_dgram::until(deadline) => media.media.tick(tokio::time::Instant::now()),
                _ = reset.changed() => {
                    if !out.is_empty() {
                        return Ok(Answer::bytes(json!({}), out));
                    }
                    return Ok(Answer::json(json!({ "end": true })));
                }
            }
        }
    }

    pub(crate) async fn run_istream(self: &Arc<Self>, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "istream.tap" => {
                // A remote screen's view (`call` the app's): its frames read here from now on, beginning with `bytes`
                // (what the core read past the stream's reply); false where nothing says to the app from here.
                let Handle::IStream(halves) = self.handle(id_of(a)?)? else { return Err("not a stream".into()) };
                let call = a.get("call").and_then(Value::as_u64).ok_or("no call")?;
                if self.say.lock().unwrap().is_none() {
                    return Ok(Answer::json(json!({ "tapped": false })));
                }
                // `cursor`: the page takes the pointer alone (ScreenTap `cursor_updates`), said to it from here
                let cursor = a.get("cursor").and_then(Value::as_bool) == Some(true);
                let mut tap = ScreenTap::new(call, cursor);
                tap.take(&bytes.unwrap_or_default(), &**self);
                *halves.tap.lock().unwrap() = Some(tap);
                tally("tap.views");
                Ok(Answer::json(json!({ "tapped": true, "cursor": cursor })))
            }
            // A remote screen's view this end sends (a station's): its video and audio frames sent from now on as
            // datagrams on its connection under `token` (screen_dgram.rs). False where the connection's datagrams will not
            // do (none, too small): its frames go on the stream as before.
            "istream.mediaDatagrams" => {
                let Handle::IStream(halves) = self.handle(id_of(a)?)? else { return Err("not a stream".into()) };
                let token = a.get("token").and_then(Value::as_u64).filter(|t| *t > 0 && *t <= u32::MAX as u64).ok_or("token: a u32, not 0")? as u32;
                let Handle::Conn(conn) = self.handle(halves.conn)? else { return Ok(Answer::json(json!(false))) };
                let Some(mut media) = MediaOut::new(conn, token) else { return Ok(Answer::json(json!(false))) };
                if let Some(acks) = media.take_ack_rx() {
                    *halves.ack_in.lock().await = Some(acks);
                    let _ = halves.ack_ready.send(true);
                }
                *halves.media_out.lock().await = Some(media);
                tally("dgram.views.sent");
                Ok(Answer::json(json!(true)))
            }
            // A remote screen's view this end asks for (a device's), before its head goes: what comes as datagrams under
            // `token` on its connection taken from now on, made whole and put among what `istream.read` gives (or what
            // its tap says) as if it came on the stream. False where another view on the connection has that token.
            "istream.receiveMediaDatagrams" => {
                let Handle::IStream(halves) = self.handle(id_of(a)?)? else { return Err("not a stream".into()) };
                let token = a.get("token").and_then(Value::as_u64).filter(|t| *t > 0 && *t <= u32::MAX as u64).ok_or("token: a u32, not 0")? as u32;
                let Handle::Conn(conn) = self.handle(halves.conn)? else { return Ok(Answer::json(json!(false))) };
                let slot = {
                    let mut demuxes = self.demuxes.lock().unwrap();
                    // (those of connections no view takes datagrams of any more let go)
                    demuxes.retain(|_, slot| slot.lock().unwrap().strong_count() > 0);
                    demuxes.entry(halves.conn).or_default().clone()
                };
                let Some((route, rx)) = crate::screen_dgram::route(&slot, &conn, token) else { return Ok(Answer::json(json!(false))) };
                let peer_capable = Arc::new(AtomicBool::new(false));
                let mut media = MediaIn::new(token, true);
                media.set_peer_ack_cap(peer_capable.clone());
                *halves.ack_dgram.lock().unwrap() = Some(AckTarget { conn, token, peer_capable });
                *halves.media_in.lock().await = Some(MediaRx { media, rx, rx_done: false, _route: route });
                tally("dgram.views.received");
                Ok(Answer::json(json!(true)))
            }
            "istream.read" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                let mut reset = halves.reset.subscribe();
                if *reset.borrow() {
                    return Ok(Answer::json(json!({ "end": true })));
                }
                // its frames coming as datagrams too
                {
                    let mut media = halves.media_in.lock().await;
                    if let Some(media) = media.as_mut() {
                        return self.read_with_datagrams(id, &halves, media, &mut reset).await;
                    }
                }
                // tapped: read on here, saying what is the app's, until something is the core's (or the end)
                if halves.tap.lock().unwrap().is_some() {
                    let mut buf = vec![0u8; 64 * 1024];
                    loop {
                        {
                            let mut tap = halves.tap.lock().unwrap();
                            let tap = tap.as_mut().unwrap();
                            if !tap.out.is_empty() {
                                return Ok(Answer::bytes(json!({}), std::mem::take(&mut tap.out)));
                            }
                        }
                        let read = {
                            let mut recv = halves.recv.lock().await;
                            let Some(recv) = recv.as_mut() else { return Ok(Answer::json(json!({ "end": true }))) };
                            tokio::select! {
                                read = recv.read(&mut buf) => read.map_err(err)?,
                                _ = reset.changed() => None,
                            }
                        };
                        match read {
                            Some(n) => {
                                let mut tap = halves.tap.lock().unwrap();
                                tap.as_mut().unwrap().take(&buf[..n], &**self);
                            }
                            None => {
                                // what is left (a frame cut short) the core's, which says so
                                let left = {
                                    let mut tap = halves.tap.lock().unwrap();
                                    let tap = tap.as_mut().unwrap();
                                    let mut left = std::mem::take(&mut tap.out);
                                    left.append(&mut tap.pending);
                                    left
                                };
                                if !left.is_empty() {
                                    return Ok(Answer::bytes(json!({}), left));
                                }
                                halves.ended.store(true, Ordering::Relaxed);
                                self.istream_done(id, &halves);
                                return Ok(Answer::json(json!({ "end": true })));
                            }
                        }
                    }
                }
                // station-side stream with mediaDatagrams: inject datagram ACKs at frame boundaries
                {
                    let mut acks = halves.ack_in.lock().await;
                    if let Some(acks) = acks.as_mut() {
                        let mut buf = vec![0u8; 64 * 1024];
                        let mut out = Vec::new();
                        loop {
                            if acks.at_boundary() {
                                acks.drain_into(&mut out);
                            }
                            if !out.is_empty() {
                                return Ok(Answer::bytes(json!({}), out));
                            }
                            let mut recv = halves.recv.lock().await;
                            let Some(recv) = recv.as_mut() else { return Ok(Answer::json(json!({ "end": true }))) };
                            tokio::select! {
                                read = recv.read(&mut buf) => match read.map_err(err)? {
                                    Some(n) => {
                                        let chunk = &buf[..n];
                                        match acks.stream(chunk) {
                                            Some(b) => {
                                                out.extend_from_slice(&chunk[..b]);
                                                acks.drain_into(&mut out);
                                                out.extend_from_slice(&chunk[b..]);
                                            }
                                            None => out.extend_from_slice(chunk),
                                        }
                                    }
                                    None => {
                                        if !out.is_empty() {
                                            return Ok(Answer::bytes(json!({}), out));
                                        }
                                        halves.ended.store(true, Ordering::Relaxed);
                                        self.istream_done(id, &halves);
                                        return Ok(Answer::json(json!({ "end": true })));
                                    }
                                },
                                d = acks.next() => acks.take_waiting(d),
                                _ = reset.changed() => {
                                    if !out.is_empty() {
                                        return Ok(Answer::bytes(json!({}), out));
                                    }
                                    return Ok(Answer::json(json!({ "end": true })));
                                }
                            }
                        }
                    }
                }
                let mut buf = vec![0u8; 64 * 1024];
                let read = {
                    let mut recv = halves.recv.lock().await;
                    let Some(recv) = recv.as_mut() else { return Ok(Answer::json(json!({ "end": true }))) };
                    tokio::select! {
                        read = recv.read(&mut buf) => read.map_err(err)?,
                        _ = reset.changed() => None,
                    }
                };
                match read {
                    Some(n) => {
                        buf.truncate(n);
                        Ok(Answer::bytes(json!({}), buf))
                    }
                    None => {
                        halves.ended.store(true, Ordering::Relaxed);
                        self.istream_done(id, &halves);
                        Ok(Answer::json(json!({ "end": true })))
                    }
                }
            }
            "istream.write" => {
                let Handle::IStream(halves) = self.handle(id_of(a)?)? else { return Err("not a stream".into()) };
                let mut send = halves.send.lock().await;
                halves.write_out(send.as_mut().ok_or("no sending half")?, &bytes.unwrap_or_default()).await?;
                Ok(Answer::json(json!({})))
            }
            "istream.finish" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                if let Some(send) = halves.send.lock().await.as_mut() {
                    send.finish().map_err(err)?;
                }
                halves.finished.store(true, Ordering::Relaxed);
                // A stream one way (a measurement) is let go once `stopped` answers; one both ways once read to its end.
                // (Let go here, a measurement's `stopped` found no stream and every relay measured on Android came to
                // nothing, 2026-10-05.)
                if halves.recv.lock().await.is_some() {
                    self.istream_done(id, &halves);
                }
                Ok(Answer::json(json!({})))
            }
            "istream.stopped" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                // Taken under the lock and awaited without it, so writes go on meanwhile.
                let stopped = match halves.send.lock().await.as_mut() {
                    Some(send) => send.stopped(),
                    None => return Ok(Answer::json(json!({ "code": null }))),
                };
                let code = stopped.await;
                if halves.recv.lock().await.is_none() && halves.finished.load(Ordering::Relaxed) {
                    self.drop_handle(id);
                }
                let code = code.map_err(err)?;
                Ok(Answer::json(json!({ "code": code.map(|c| c.into_inner()) })))
            }
            "istream.reset" => {
                let id = id_of(a)?;
                let code = a.get("code").and_then(Value::as_u64).unwrap_or(0) as u32;
                if let Some(Handle::IStream(halves)) = self.drop_handle(id) {
                    let _ = halves.reset.send(true);
                    if let Some(send) = halves.send.lock().await.as_mut() {
                        let _ = send.reset(code.into());
                    }
                    if let Some(recv) = halves.recv.lock().await.as_mut() {
                        let _ = recv.stop(code.into());
                    }
                }
                Ok(Answer::json(json!({})))
            }
            // A stream carried whole into a socket (`to`, taken), both ways, here: what comes on it written to the socket
            // in frames (PIPE_END its end, PIPE_FAILED what failed it), and the frames the socket sends written on it, its
            // PIPE_END finishing it; the socket ending without one resets it. What the station's Node reads and writes of
            // a stream the front keeps for it (station/mb's front), none of it through the front's program. Answered once
            // both ways are done; `istream.stopped` and `istream.reset` are asked of the stream meanwhile as before.
            "istream.pipe" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                let to = a.get("to").and_then(Value::as_u64).ok_or("missing to")?;
                let Some(Handle::Tcp { read, write }) = self.drop_handle(to) else { return Err("not a socket".into()) };
                self.pipe(id, halves, read, write).await;
                Ok(Answer::json(json!({})))
            }
            // A stream given to the Unix socket at `path`: a connection to it, `bytes` written first (what tells the
            // other side which stream it is), then the stream carried into it as `istream.pipe` carries it.
            "istream.hand" => {
                let id = id_of(a)?;
                let Handle::IStream(halves) = self.handle(id)? else { return Err("not a stream".into()) };
                self.hand(id, halves, str_of(a, "path")?, &bytes.unwrap_or_default()).await?;
                Ok(Answer::json(json!({})))
            }
            // Each stream the other end of a connection opens, given as it comes to the Unix socket at `path` as
            // `istream.hand` gives one, its head the connection's id and the stream's (8 bytes each, big-endian), a 2
            // and the stream's index on the connection (QUIC's, 8 bytes): each is handed by a task of its own, so their
            // sockets come to the other side in any order, which puts them back in the order they were opened by it
            // (a device's credential stream is its first; 2026-11-13, its requests came first and were refused as
            // one). A 0 there and no index: a front from before. Kept as a stream here meanwhile
            // (`istream.stopped`, `istream.reset`). Answered once the connection is gone.
            // What station/mb's front gives its Node, with no step of the program's for each stream.
            //
            // With `front` (Unix sockets' paths, each taking the next in turn) and `routes` ("GET /admin/api/chats", …): a stream past the first
            // whose head line (its first, read here) asks one of those, by its method and its path without the query,
            // goes there instead, with what was read of it, and `path` is told its index went elsewhere (its head the
            // ids, a 3 and the index): what the front answers itself. A route's segment `*` is any one segment. One
            // of them that takes no connection (its program ended, the next not listening yet) is passed over for the
            // next in turn; none taking it, the stream goes to `path` as any other does, with what was read of it, and
            // Node answers it (`path` told nothing went elsewhere): a request is not reset for a program between two runs.
            "conn.hand" => {
                let on = id_of(a)?;
                let path = str_of(a, "path")?.to_string();
                let fronts: Arc<Vec<String>> = Arc::new(a.get("front").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect());
                let mut turn = 0usize;
                let routes: Arc<Vec<String>> = Arc::new(
                    a.get("routes").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(str::to_string).collect(),
                );
                let Handle::Conn(conn) = self.handle(on)? else { return Ok(Answer::json(json!({}))) };
                while let Ok((mut send, mut recv)) = conn.accept_bi().await {
                    if !matches!(self.handle(on), Ok(Handle::Conn(_))) {
                        let _ = send.reset(0u32.into());
                        let _ = recv.stop(0u32.into());
                        break;
                    }
                    let index = recv.id().index();
                    let halves = Arc::new(Halves {
                        conn: on,
                        ended: false.into(),
                        finished: false.into(),
                        send: tokio::sync::Mutex::new(Some(send)),
                        recv: tokio::sync::Mutex::new(Some(recv)),
                        reset: tokio::sync::watch::channel(false).0,
                        tap: Mutex::default(),
                        media_out: Default::default(),
                        media_in: Default::default(),
                        ack_dgram: Mutex::default(),
                        ack_in: Default::default(),
                        ack_ready: tokio::sync::watch::channel(false).0,
                    });
                    let id = self.keep(Handle::IStream(halves.clone()));
                    let mut head = on.to_be_bytes().to_vec();
                    head.extend(id.to_be_bytes());
                    head.push(2);
                    head.extend(index.to_be_bytes());
                    let start = turn;
                    turn = turn.wrapping_add(1);
                    let (inner, conn, path, routes, fronts) = (self.clone(), conn.clone(), path.clone(), routes.clone(), fronts.clone());
                    tokio::spawn(async move {
                        let mut head = head;
                        if index > 0 && !fronts.is_empty() && !routes.is_empty() {
                            let read = read_head_line(&halves).await;
                            let routed = route_of(&read).is_some_and(|r| routes.iter().any(|p| route_matches(p, &r)));
                            // (as the frame `pipe` would have carried it: its length first; the same to a program or Node)
                            if !read.is_empty() {
                                head.extend((read.len() as u32).to_be_bytes());
                                head.extend(read);
                            }
                            if routed {
                                for k in 0..fronts.len() {
                                    let front = &fronts[start.wrapping_add(k) % fronts.len()];
                                    match open_unix(front, &head).await {
                                        Ok((read, write)) => {
                                            // Node told the index went elsewhere only once it has: else it waits for it.
                                            let skip = skip_head(on, id, index);
                                            if let Err(e) = tell_unix(&path, &skip).await {
                                                crate::log::info(&format!("mesh: a stream's index not told: {e}"));
                                                conn.close(0u32.into(), b"stream index lost");
                                                inner.reset_stream(id).await;
                                                return;
                                            }
                                            inner.pipe(id, halves, read, write).await;
                                            return;
                                        }
                                        Err(e) => crate::log::info(&format!("mesh: a routed stream not taken at {front} ({e}); the next")),
                                    }
                                }
                                crate::log::info(&format!("mesh: no program took a routed stream; Node answers it"));
                            }
                        }
                        if let Err(e) = inner.hand(id, halves, &path, &head).await {
                            crate::log::info(&format!("mesh: a stream not given: {e}"));
                            skip_or_close(&conn, &path, on, id, index).await;
                        }
                    });
                }
                Ok(Answer::json(json!({})))
            }
            other => Err(format!("no operation {other}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::screen_tap::ScreenTap;
    use iroh::endpoint::presets::Minimal;
    use iroh::{Endpoint, RelayMode};

    /// The core's own (screens.ts `checkInput`, then screen-frames.ts `inputFrame`'s JSON.stringify), as node wrote them.
    const THE_CORES: &[(&str, &str)] = &[
            (r#"{"t":"pointer","kind":"move","x":0.5123456789,"y":1.5,"buttons":1.9,"dx":3,"dy":-2.25,"relative":true}"#, r#"{"t":"pointer","kind":"move","x":0.5123456789,"y":1,"buttons":1,"dx":3,"dy":-2.25,"relative":true}"#),
            (r#"{"t":"pointer","kind":"move","x":0.1,"y":0.2,"buttons":0,"dx":20000,"dy":-1e-7}"#, r#"{"t":"pointer","kind":"move","x":0.1,"y":0.2,"buttons":0,"dx":10000,"dy":-1e-7}"#),
            (r#"{"t":"pointer","kind":"move","x":0.1,"y":0.2,"buttons":33,"relative":true}"#, r#"{"t":"pointer","kind":"move","x":0.1,"y":0.2,"buttons":1}"#),
            (r#"{"t":"pointer","kind":"down","x":-1,"y":0.3333333333333333,"buttons":1,"relative":true,"extra":5}"#, r#"{"t":"pointer","kind":"down","x":0,"y":0.3333333333333333,"buttons":1,"relative":true}"#),
            (r#"{"t":"wheel","x":0.25,"y":0.75,"dx":0,"dy":-120.5}"#, r#"{"t":"wheel","x":0.25,"y":0.75,"dx":0,"dy":-120.5}"#),
            (r#"{"t":"key","kind":"down","key":"w","mods":17}"#, r#"{"t":"key","kind":"down","key":"w","code":"","mods":1}"#),
            (r#"{"t":"key","kind":"up","key":"Enter","code":"Enter \"\\\u0001","mods":2}"#, r#"{"t":"key","kind":"up","key":"Enter","code":"Enter \"\\\u0001","mods":2}"#),
            (r#"{"t":"gamepad","index":1,"buttons":131073,"lx":-2,"ly":0.5,"rx":0.123,"ry":1,"lt":0.75,"rt":-1}"#, r#"{"t":"gamepad","index":1,"connected":true,"buttons":1,"lx":-1,"ly":0.5,"rx":0.123,"ry":1,"lt":0.75,"rt":0}"#),
            (r#"{"t":"gamepad","index":3,"connected":false}"#, r#"{"t":"gamepad","index":3,"connected":false,"buttons":0,"lx":0,"ly":0,"rx":0,"ry":0,"lt":0,"rt":0}"#)
    ];

    #[test]
    fn an_input_sent_straight_is_the_frame_the_core_would_have_sent() {
        for (asked, core) in THE_CORES {
            let checked = checked_input(&serde_json::from_str(asked).unwrap()).unwrap();
            let f = input_frame(&checked);
            assert_eq!(f[0], 16);
            assert_eq!(u32::from_be_bytes(f[1..5].try_into().unwrap()) as usize, f.len() - 5);
            assert_eq!(std::str::from_utf8(&f[5..]).unwrap(), *core, "{asked}");
        }
        // the core's alone: any other kind, one it refuses with its words
        for other in [r#"{"t":"text","text":"a"}"#, r#"{"t":"window"}"#, r#"{"t":"fill","host":"a","password":"p"}"#, r#"{"t":"key","kind":"down","key":""}"#, r#"{"t":"pointer","kind":"drag","x":0,"y":0}"#, r#"{"t":"wheel","x":0,"y":0}"#, r#"{"t":"gamepad","index":4}"#, "[1]", "7"] {
            assert_eq!(checked_input(&serde_json::from_str(other).unwrap()), None, "{other}");
        }
    }

    #[test]
    fn a_move_waiting_is_taken_over_by_the_next_and_nothing_else_is() {
        let ev = |s: &str| checked_input(&serde_json::from_str(s).unwrap()).unwrap();
        let mut last = ev(r#"{"t":"pointer","kind":"move","x":0.1,"y":0.1,"buttons":0,"dx":1.5,"dy":-2,"relative":true}"#);
        assert!(merged(&mut last, &ev(r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":0,"dx":2.25,"dy":5,"relative":true}"#)));
        assert_eq!(last, ev(r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":0,"dx":3.75,"dy":3,"relative":true}"#), "the distances added, the newest place");
        // another button held, absolute and relative, a press, a key: never
        assert!(!merged(&mut last, &ev(r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":1,"dx":1,"dy":1,"relative":true}"#)));
        assert!(!merged(&mut last, &ev(r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":0}"#)));
        assert!(!merged(&mut last, &ev(r#"{"t":"pointer","kind":"down","x":0.2,"y":0.3,"buttons":1,"relative":true}"#)));
        assert!(!merged(&mut last, &ev(r#"{"t":"key","kind":"down","key":"w","code":"KeyW"}"#)));
        // never past the longest move: sent as two
        assert!(!merged(&mut last, &ev(r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":0,"dx":9999,"dy":0,"relative":true}"#)));
        let mut abs = ev(r#"{"t":"pointer","kind":"move","x":0.1,"y":0.1,"buttons":0}"#);
        assert!(merged(&mut abs, &ev(r#"{"t":"pointer","kind":"move","x":0.4,"y":0.6,"buttons":0}"#)));
        assert_eq!(abs, ev(r#"{"t":"pointer","kind":"move","x":0.4,"y":0.6,"buttons":0}"#));
        let mut key = ev(r#"{"t":"key","kind":"down","key":"w"}"#);
        assert!(!merged(&mut key, &ev(r#"{"t":"key","kind":"down","key":"w"}"#)), "a key repeated is sent each time");
    }

    extern "C" fn no_answers(_: *mut std::ffi::c_void, _: u64, _: *const u8, _: usize, _: *const u8, _: usize, _: *const u8, _: usize, _: u8) {}

    /// A tapped view on a real iroh connection on this machine, its station's end (what the frames come on).
    fn tapped(shell: &crate::Shell, call: u64) -> (Arc<Halves>, iroh::endpoint::RecvStream, Vec<Endpoint>) {
        shell.runtime.block_on(async {
            let alpn = b"stillfail/test".to_vec();
            let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
            let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
            let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
            let addr = crate::iroh_ops::endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
            let taking = b.clone();
            let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
            let client = a.connect(addr, &alpn).await.unwrap();
            let station = taken.await.unwrap();
            let (mut send, recv) = client.open_bi().await.unwrap();
            send.write_all(b"{}\n").await.unwrap();
            let (_, mut srecv) = station.accept_bi().await.unwrap();
            let mut line = [0u8; 3];
            srecv.read_exact(&mut line).await.unwrap();
            let (reset, _) = tokio::sync::watch::channel(false);
            let halves = Arc::new(Halves {
                conn: 0,
                send: tokio::sync::Mutex::new(Some(send)),
                recv: tokio::sync::Mutex::new(Some(recv)),
                reset,
                ended: Default::default(),
                finished: Default::default(),
                tap: Mutex::new(Some(ScreenTap::new(call, false))),
                media_out: Default::default(),
                media_in: Default::default(),
                ack_dgram: Mutex::default(),
                ack_in: Default::default(),
                ack_ready: tokio::sync::watch::channel(false).0,
            });
            shell.inner.handles.lock().unwrap().insert(900 + call, crate::Handle::IStream(halves.clone()));
            std::mem::forget(station);
            (halves, srecv, vec![a, b])
        })
    }

    /// The input frames read off the station's end, `n` of them.
    fn read_inputs(shell: &crate::Shell, recv: &mut iroh::endpoint::RecvStream, n: usize) -> Vec<String> {
        shell.runtime.block_on(async {
            let mut got = Vec::new();
            while got.len() < n {
                let mut head = [0u8; 5];
                recv.read_exact(&mut head).await.unwrap();
                assert_eq!(head[0], 16);
                let mut body = vec![0u8; u32::from_be_bytes(head[1..5].try_into().unwrap()) as usize];
                recv.read_exact(&mut body).await.unwrap();
                got.push(String::from_utf8(body).unwrap());
            }
            got
        })
    }

    #[test]
    fn inputs_sent_straight_go_in_order_moves_waiting_taken_over() {
        let dir = std::env::temp_dir().join(format!("stillfail-shell-input-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let shell = crate::Shell::start(dir, no_answers, std::ptr::null_mut()).unwrap();
        let (halves, mut recv, _endpoints) = tapped(&shell, 7);
        let send = |s: &str| crate::ffi::screen_input(&shell, 7, s.as_bytes());
        assert_eq!(send(r#"{"t":"text","text":"a"}"#), 0, "the core's");
        assert_eq!(crate::ffi::screen_input(&shell, 8, br#"{"t":"key","kind":"down","key":"w"}"#), 0, "no view of that call tapped");
        // the stream held (a write under way): what comes meanwhile waits, its moves taken over
        let held = shell.runtime.block_on(halves.send.lock());
        for s in [
            r#"{"t":"key","kind":"down","key":"w","code":"KeyW"}"#,
            r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":0,"dx":1,"dy":1,"relative":true}"#,
            r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":0,"dx":2,"dy":3,"relative":true}"#,
            r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":0,"dx":-1,"dy":0.5,"relative":true}"#,
            r#"{"t":"pointer","kind":"down","x":0.5,"y":0.5,"buttons":1,"relative":true}"#,
            r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":1,"dx":4,"dy":0,"relative":true}"#,
            r#"{"t":"pointer","kind":"up","x":0.5,"y":0.5,"buttons":0,"relative":true}"#,
            r#"{"t":"pointer","kind":"move","x":0.1,"y":0.1,"buttons":0}"#,
            r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":0}"#,
            r#"{"t":"key","kind":"up","key":"w","code":"KeyW"}"#,
            r#"{"t":"gamepad","index":0,"buttons":1,"lx":0.5}"#,
        ] {
            assert_eq!(send(s), 1);
        }
        drop(held);
        let want = [
            r#"{"t":"key","kind":"down","key":"w","code":"KeyW","mods":0}"#,
            r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":0,"dx":2,"dy":4.5,"relative":true}"#,
            r#"{"t":"pointer","kind":"down","x":0.5,"y":0.5,"buttons":1,"relative":true}"#,
            r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":1,"dx":4,"dy":0,"relative":true}"#,
            r#"{"t":"pointer","kind":"up","x":0.5,"y":0.5,"buttons":0,"relative":true}"#,
            r#"{"t":"pointer","kind":"move","x":0.2,"y":0.3,"buttons":0}"#,
            r#"{"t":"key","kind":"up","key":"w","code":"KeyW","mods":0}"#,
            r#"{"t":"gamepad","index":0,"connected":true,"buttons":1,"lx":0.5,"ly":0,"rx":0,"ry":0,"lt":0,"rt":0}"#,
        ];
        assert_eq!(read_inputs(&shell, &mut recv, want.len()), want);
        // a great many at once, from two threads in turn, as fast as they come: each thread's in its order, no move's
        // distance lost
        let line = shell.inner.inputs.lock().unwrap().get(&7).unwrap().clone();
        std::thread::scope(|s| {
            for who in ["a", "b"] {
                let send = &send;
                s.spawn(move || {
                    for i in 0..1000 {
                        assert_eq!(send(&format!(r#"{{"t":"key","kind":"{}","key":"{who}{i}"}}"#, if i % 2 == 0 { "down" } else { "up" })), 1);
                        assert_eq!(send(r#"{"t":"pointer","kind":"move","x":0.5,"y":0.5,"buttons":0,"dx":1,"dy":-1,"relative":true}"#), 1);
                    }
                });
            }
        });
        let mut keys = Vec::new();
        let (mut dx, mut dy) = (0.0, 0.0);
        let mut read = 0;
        while keys.len() < 2000 || dx < 2000.0 {
            let got = read_inputs(&shell, &mut recv, 1).pop().unwrap();
            read += 1;
            let v: Value = serde_json::from_str(&got).unwrap();
            if v["t"] == "key" {
                keys.push(v["key"].as_str().unwrap().to_string());
            } else {
                dx += v["dx"].as_f64().unwrap();
                dy += v["dy"].as_f64().unwrap();
            }
        }
        assert_eq!((dx, dy), (2000.0, -2000.0), "every move's distance came");
        for who in ["a", "b"] {
            let theirs: Vec<&String> = keys.iter().filter(|k| k.starts_with(who)).collect();
            assert_eq!(theirs, (0..1000).map(|i| format!("{who}{i}")).collect::<Vec<_>>().iter().collect::<Vec<_>>());
        }
        assert!(line.waiting().is_empty());
        eprintln!("4000 inputs sent straight from two threads: {read} frames on the stream ({} moves taken over)", 4000 - read);
        drop(shell);
    }

    #[test]
    fn screen_ack_wait_uses_datagram_fast_path_and_injects_at_frame_boundaries() {
        use crate::screen_dgram::{FRAME_ACK, MediaIn, MediaOut, MediaRx, route};

        let dir = std::env::temp_dir().join(format!("stillfail-shell-ack-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let shell = crate::Shell::start(dir, no_answers, std::ptr::null_mut()).unwrap();
        shell.runtime.block_on(async {
            let alpn = b"stillfail/test".to_vec();
            let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
            let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
            let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
            let addr = crate::iroh_ops::endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
            let taking = b.clone();
            let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
            let client = a.connect(addr, &alpn).await.unwrap();
            let station = taken.await.unwrap();
            let (mut csend, crecv) = client.open_bi().await.unwrap();
            csend.write_all(b"{}\n").await.unwrap();
            let (mut ssend, mut srecv) = station.accept_bi().await.unwrap();
            let mut line = [0u8; 3];
            srecv.read_exact(&mut line).await.unwrap();

            // Station enables mediaDatagrams (creates AckRx) and sends one video frame advertising FLAG_ACK.
            let token = 42u32;
            let mut media_out = MediaOut::new(station.clone(), token).unwrap();
            let mut ack_rx = media_out.take_ack_rx().unwrap();

            // Client enables receiveMediaDatagrams + tap.
            let slot = Mutex::default();
            let (rt, rx) = route(&slot, &client, token).unwrap();
            let peer_capable = Arc::new(AtomicBool::new(false));
            let mut media_in = MediaIn::new(token, true);
            media_in.set_peer_ack_cap(peer_capable.clone());
            let mut media_rx = MediaRx { media: media_in, rx, rx_done: false, _route: rt };

            let halves = Arc::new(Halves {
                conn: 0,
                send: tokio::sync::Mutex::new(Some(csend)),
                recv: tokio::sync::Mutex::new(Some(crecv)),
                reset: tokio::sync::watch::channel(false).0,
                ended: Default::default(),
                finished: Default::default(),
                tap: Mutex::new(Some(ScreenTap::new(99, false))),
                media_out: Default::default(),
                media_in: Default::default(),
                ack_dgram: Mutex::new(Some(AckTarget { conn: client.clone(), token, peer_capable: peer_capable.clone() })),
                ack_in: Default::default(),
                ack_ready: tokio::sync::watch::channel(false).0,
            });
            shell.inner.handles.lock().unwrap().insert(999, crate::Handle::IStream(halves.clone()));

            // 1. Before any datagram from station arrives, peer_capable is false -> falls back to reliable stream.
            assert!(!peer_capable.load(Ordering::Relaxed));
            assert_eq!(crate::ffi::screen_ack(&shell, 99, 123_456.0, 7_890), 1);
            let mut head = [0u8; 5];
            srecv.read_exact(&mut head).await.unwrap();
            assert_eq!(head[0], FRAME_ACK);
            assert_eq!(u32::from_be_bytes(head[1..5].try_into().unwrap()), 12);
            let mut body = [0u8; 12];
            srecv.read_exact(&mut body).await.unwrap();
            assert_eq!(u64::from_be_bytes(body[0..8].try_into().unwrap()), 123_456);
            assert_eq!(u32::from_be_bytes(body[8..12].try_into().unwrap()), 7_890);

            // 2. Station sends reply line + config + 1 video frame as datagram -> client sees FLAG_ACK.
            media_out.write(&mut ssend, b"{\"status\":200}\n").await.unwrap();
            let cfg = br#"{"codec":"h264","width":1280,"height":720}"#;
            let mut f = vec![1u8];
            f.extend((cfg.len() as u32).to_be_bytes());
            f.extend(cfg);
            let mut vbody = vec![1u8];
            vbody.extend(555_000u64.to_be_bytes());
            vbody.extend(vec![0xAB; 2000]);
            f.push(2);
            f.extend((vbody.len() as u32).to_be_bytes());
            f.extend(vbody);
            media_out.write(&mut ssend, &f).await.unwrap();

            let d = tokio::time::timeout(std::time::Duration::from_secs(5), media_rx.next()).await.unwrap();
            media_rx.take_waiting(d, tokio::time::Instant::now());
            assert!(peer_capable.load(Ordering::Relaxed), "client learned station supports datagram ACKs");

            // 3. Hold halves.send lock (simulating HoL-blocked reliable stream!): datagram ACK still delivers at once!
            let _held = halves.send.lock().await;
            assert_eq!(crate::ffi::screen_ack(&shell, 99, 555_000.0, 14_250), 1);
            let got = tokio::time::timeout(std::time::Duration::from_secs(5), ack_rx.next()).await.unwrap();
            assert_eq!(got, Some((555_000, 14_250)));

            // 4. Verify AckRx injects 17-byte KIND.ack at stream frame boundary, never inside a partial stream frame.
            ack_rx.take_waiting(got);
            let mut out = Vec::new();
            let input_frame = input_frame(&checked_input(&json!({"t":"key","kind":"down","key":"a","code":"KeyA","mods":0})).unwrap());
            // Split the stream frame in half: first half starts at boundary so ACK injects before it, not mid-frame.
            let split = 7;
            let b1 = ack_rx.stream(&input_frame[..split]).unwrap();
            assert_eq!(b1, 0);
            out.extend_from_slice(&input_frame[..b1]);
            ack_rx.drain_into(&mut out);
            out.extend_from_slice(&input_frame[b1..split]);
            assert!(!ack_rx.at_boundary());
            // Another ACK arrives mid-frame: must wait until second half finishes!
            ack_rx.take_waiting(Some((666_000, 3_500)));
            let b2 = ack_rx.stream(&input_frame[split..]).unwrap();
            assert_eq!(b2, input_frame.len() - split);
            out.extend_from_slice(&input_frame[split..split + b2]);
            ack_rx.drain_into(&mut out);
            assert!(ack_rx.at_boundary());

            // Parse all 3 frames in `out`: [ACK 555_000/14_250, INPUT, ACK 666_000/3_500]
            let mut pos = 0;
            let mut parsed = Vec::new();
            while pos < out.len() {
                let kind = out[pos];
                let len = u32::from_be_bytes(out[pos + 1..pos + 5].try_into().unwrap()) as usize;
                parsed.push((kind, out[pos + 5..pos + 5 + len].to_vec()));
                pos += 5 + len;
            }
            assert_eq!(parsed.len(), 3);
            assert_eq!(parsed[0].0, FRAME_ACK);
            assert_eq!(u64::from_be_bytes(parsed[0].1[0..8].try_into().unwrap()), 555_000);
            assert_eq!(u32::from_be_bytes(parsed[0].1[8..12].try_into().unwrap()), 14_250);
            assert_eq!(parsed[1].0, FRAME_INPUT);
            assert_eq!(parsed[2].0, FRAME_ACK);
            assert_eq!(u64::from_be_bytes(parsed[2].1[0..8].try_into().unwrap()), 666_000);
            assert_eq!(u32::from_be_bytes(parsed[2].1[8..12].try_into().unwrap()), 3_500);
            drop(_held);
            a.close().await;
            b.close().await;
        });
        drop(shell);
    }

    /// A remote screen's 2K view at 60 and at 120 frames a second over a real iroh connection on this machine, its
    /// frames as datagrams (screen_dgram.rs), with none, 1%, 3% and 5% of them lost at random, and 3% lost two in a row:
    /// as it was (one parity shard on a clean link, the connection's counters alone, asleep every 8 shards) and now
    /// (a tenth at least, the receiving end's reports, no sleeping), no loss told to either. Run alone:
    /// `cargo test --release -p stillfail-shell two_k_frames -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn two_k_frames_as_datagrams_through_loss_before_and_now() {
        use crate::screen_dgram::{KEYFRAME_FRAME, MediaIn, MediaOut, MediaRx, route};
        use std::collections::HashMap;
        use tokio::time::{Duration, Instant};

        let dir = std::env::temp_dir().join(format!("stillfail-shell-bench-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let shell = crate::Shell::start(dir, no_answers, std::ptr::null_mut()).unwrap();
        shell.runtime.block_on(async move {
            let alpn = b"stillfail/test".to_vec();
            let bind = |alpns: Vec<Vec<u8>>| Endpoint::builder(Minimal).relay_mode(RelayMode::Disabled).alpns(alpns).bind();
            let (a, b) = (bind(vec![]).await.unwrap(), bind(vec![alpn.clone()]).await.unwrap());
            let port = b.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
            let addr = crate::iroh_ops::endpoint_addr(&json!({ "id": hex::encode(b.id().as_bytes()), "ips": [format!("127.0.0.1:{port}")] })).unwrap();
            let taking = b.clone();
            let taken = tokio::spawn(async move { taking.accept().await.unwrap().await.unwrap() });
            let client = a.connect(addr, &alpn).await.unwrap();
            let station = taken.await.unwrap();
            let slot = Mutex::default();
            const SECONDS: u64 = 5;
            let mut token = 0u32;
            let mut rows = Vec::new();
            for (fps, p_len) in [(60u64, 35_000usize), (120, 20_000)] {
                for (loss, burst) in [(0.0, 1usize), (0.01, 1), (0.03, 1), (0.05, 1), (0.03, 2)] {
                    for before in [true, false] {
                        token += 1;
                        let frames = fps * SECONDS;
                        let (mut csend, mut crecv) = client.open_bi().await.unwrap();
                        let (route, rx) = route(&slot, &client, token).unwrap();
                        let mut rx = MediaRx { media: MediaIn::new(token, true), rx, rx_done: false, _route: route };
                        csend.write_all(b"{\"screen\":{}}\n").await.unwrap();
                        let (mut ssend, mut srecv) = station.accept_bi().await.unwrap();
                        let sent: Arc<Mutex<HashMap<u64, Instant>>> = Arc::default();
                        let want_key = Arc::new(std::sync::atomic::AtomicBool::new(false));
                        let sending = {
                            let (station, sent, want_key) = (station.clone(), sent.clone(), want_key.clone());
                            tokio::spawn(async move {
                                let mut line = [0u8; 14];
                                srecv.read_exact(&mut line).await.unwrap();
                                let asked = want_key.clone();
                                tokio::spawn(async move {
                                    let mut f = [0u8; 5];
                                    while srecv.read_exact(&mut f).await.is_ok() {
                                        if f == KEYFRAME_FRAME {
                                            asked.store(true, Ordering::Relaxed);
                                        }
                                    }
                                });
                                let mut media = MediaOut::new(station, token).unwrap();
                                media.lose = Some((loss, 0x9e37_79b9_7f4a_7c15 ^ token as u64));
                                media.burst = burst;
                                media.before = before;
                                media.write(&mut ssend, b"{\"status\":200}\n").await.unwrap();
                                let config = br#"{"codec":"h264","width":2560,"height":1440}"#;
                                let mut f = vec![1u8];
                                f.extend((config.len() as u32).to_be_bytes());
                                f.extend(config);
                                media.write(&mut ssend, &f).await.unwrap();
                                let start = Instant::now();
                                let (mut keys, mut parity_at_end) = (0u64, (0u64, 0u64));
                                for i in 0..frames {
                                    tokio::time::sleep_until(start + Duration::from_micros(1_000_000 * i / fps)).await;
                                    let key = i % (2 * fps) == 0 || want_key.swap(false, Ordering::Relaxed);
                                    keys += key as u64;
                                    let len = if key { 140_000 } else { p_len - p_len / 8 + (i as usize * 7919) % (p_len / 4) };
                                    let mut body = vec![key as u8];
                                    body.extend(i.to_be_bytes());
                                    body.extend((0..len).map(|j| (j as u64 * 31 + i) as u8));
                                    let mut f = vec![2u8];
                                    f.extend((body.len() as u32).to_be_bytes());
                                    f.extend(body);
                                    sent.lock().unwrap().insert(i, Instant::now());
                                    media.write(&mut ssend, &f).await.unwrap();
                                    if i == frames / 2 {
                                        parity_at_end = media.shards;
                                    }
                                }
                                ssend.finish().unwrap();
                                let late = (media.shards.0 - parity_at_end.0, media.shards.1 - parity_at_end.1);
                                (media.took, keys, media.shards, late)
                            })
                        };
                        let mut buf = vec![0u8; 64 * 1024];
                        let mut bytes: Vec<u8> = Vec::new();
                        let mut line = false;
                        let mut got: Vec<(u64, bool, Duration)> = Vec::new();
                        let (mut reports, mut said) = (0u64, Vec::new());
                        loop {
                            if rx.media.at_boundary() {
                                rx.media.drain_into(&mut bytes);
                            }
                            if rx.media.take_keyframe(Instant::now()) {
                                csend.write_all(&KEYFRAME_FRAME).await.unwrap();
                            }
                            if !line {
                                if let Some(at) = bytes.iter().position(|&b| b == b'\n') {
                                    bytes.drain(..=at);
                                    line = true;
                                }
                            }
                            while line && bytes.len() >= 5 {
                                let len = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
                                if bytes.len() < 5 + len {
                                    break;
                                }
                                if bytes[0] == 2 {
                                    let i = u64::from_be_bytes(bytes[6..14].try_into().unwrap());
                                    assert!(bytes[14..5 + len].iter().enumerate().all(|(j, &v)| v == (j as u64 * 31 + i) as u8), "frame {i} made whole as it was sent");
                                    let at = sent.lock().unwrap()[&i];
                                    got.push((i, bytes[5] & 1 == 1, at.elapsed()));
                                }
                                bytes.drain(..5 + len);
                            }
                            let deadline = rx.media.deadline();
                            let before_report = rx.media.loss;
                            tokio::select! {
                                read = crecv.read(&mut buf) => match read.unwrap() {
                                    Some(n) => {
                                        let chunk = &buf[..n];
                                        match rx.media.stream(chunk, tokio::time::Instant::now()) {
                                            Some(b) => {
                                                bytes.extend_from_slice(&chunk[..b]);
                                                rx.media.drain_into(&mut bytes);
                                                bytes.extend_from_slice(&chunk[b..]);
                                            }
                                            None => bytes.extend_from_slice(chunk),
                                        }
                                    }
                                    None => break,
                                },
                                d = rx.next() => rx.take_waiting(d, Instant::now()),
                                _ = crate::screen_dgram::until(deadline) => rx.media.tick(Instant::now()),
                            }
                            if rx.media.loss.shards < before_report.shards {
                                reports += 1;
                                said.push(before_report.missing as f64 / before_report.shards.max(1) as f64);
                            }
                        }
                        let (took, keys, shards, late) = sending.await.unwrap();
                        for w in got.windows(2) {
                            assert!(w[1].1 || w[1].0 == w[0].0 + 1, "frame {} given after {}", w[1].0, w[0].0);
                        }
                        let pct = |v: &mut Vec<f64>, p: f64| {
                            v.sort_by(f64::total_cmp);
                            if v.is_empty() { f64::NAN } else { v[((v.len() - 1) as f64 * p).round() as usize] }
                        };
                        let mut ms: Vec<f64> = got.iter().map(|g| g.2.as_secs_f64() * 1000.0).collect();
                        let mut send_ms: Vec<f64> = took.iter().map(|d| d.as_secs_f64() * 1000.0).collect();
                        let send_mean = send_ms.iter().sum::<f64>() / send_ms.len().max(1) as f64;
                        let c = rx.media.counts;
                        let heard = said.iter().copied().sum::<f64>() / said.len().max(1) as f64;
                        let row = format!(
                            "| {fps} | {} | {} | {}/{} ({:.1}%) | {} | {} | {:.2} | {:.2} | {:.2} | {:.2} | {:.1}% | {:.1}% | {} ({:.2}%) |",
                            if burst > 1 { format!("{:.0}% ×{burst}", loss * 100.0) } else { format!("{:.0}%", loss * 100.0) },
                            if before { "before" } else { "now" },
                            got.len(), frames, got.len() as f64 * 100.0 / frames as f64, c.given_up, keys,
                            pct(&mut ms, 0.5), pct(&mut ms, 0.99), send_mean, pct(&mut send_ms, 0.99),
                            shards.1 as f64 * 100.0 / shards.0.max(1) as f64, late.1 as f64 * 100.0 / late.0.max(1) as f64,
                            reports, heard * 100.0,
                        );
                        eprintln!("{row}");
                        rows.push(row);
                    }
                }
            }
            eprintln!("\n| fps | loss | | frames given | given up | key frames | P50 ms | P99 ms | send mean ms | send P99 ms | parity | parity (2nd half) | reports (loss said) |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|");
            for r in rows {
                eprintln!("{r}");
            }
        });
    }
}
