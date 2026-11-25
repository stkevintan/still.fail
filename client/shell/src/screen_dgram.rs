//! A remote screen's picture and sound as QUIC datagrams beside its stream (client/core-ts screen-frames.ts, Wire):
//! each video and audio frame the station writes on a view's stream goes instead as datagrams on the stream's
//! connection, cut into shards with Reed-Solomon parity (GF(2^8), a systematic Cauchy code), so a shard lost on the way
//! is made again from the others at once instead of waiting a round trip for QUIC to send it again, and a frame that
//! cannot be made whole is passed over rather than holding every frame after it. The rest (configs, states, the
//! clipboard, what the client sends) stays on the stream, in order.
//!
//! Shared by the native shell (`istream.*`: the apps receive, a MoonBit station or front sends) and the station's
//! addon (station/native/mesh: a station in TypeScript sends, a Node client receives), which takes this file by path.
//!
//! Both ends agree on it in the view's head (client/core-ts station/mesh-wire.ts `screen`): the client offers a token it
//! already routes its connection's datagrams to (`datagrams`), and the station that sends its frames so says
//! `x-screen-dgram` with it in its reply. A client or a station from before, a way with no datagrams (the browser's
//! iroh) or with too small ones, goes on the stream as before.
//!
//! A datagram: `HEADER_LEN` bytes, then one shard.
//! - 0: `MAGIC` (other datagrams on the connection, `conn.answers`' one byte, are passed over)
//! - 1: the frame's kind (bits 0..2: 2 video, 6 audio), bit 3 a key frame, bit 4 the previous audio packet carried too
//! - 2..6: the view's token (u32, big-endian, not 0)
//! - 6: how many configs of its kind the stream had carried when it was sent (`FRAME_CONFIG`, `FRAME_AUDIO_CONFIG`)
//! - 7..11: the frame's number among its kind's, from 1
//! - 11, 12: which block of the frame, of how many (a frame of more than `MAX_K` shards is cut into blocks)
//! - 13, 14: the block's data shards (k, 1..=MAX_K) and parity shards (m, 0..=MAX_M)
//! - 15: which shard: below k the block's bytes (their length first, u16 big-endian), from k on its parity
//!
//! The receiving end says back, about every `REPORT_EVERY`, the share of the frames' shards that did not come (a
//! datagram of `REPORT_LEN` bytes: `MAGIC`, `KIND_REPORT`, the view's token, the loss in millionths and the shards it
//! counts, each u32 big-endian, then two 0 bytes), which the sending end makes its parity for: QUIC does not count a
//! datagram lost as it does a packet of a stream, so the connection's own counters barely see the frames' loss. An end
//! from before passes the report over (no head of a frame is that short), and one that says none is sent for by the
//! connection's counters alone.
//!
//! The receiving end gives a frame on only in an order the decoder can take: a frame of the configs the stream has
//! carried (one of a config still coming waits for it), a key frame as soon as it is whole (whatever came before it no
//! longer matters), a frame after it only once the one before it was given. One that cannot be had (more shards lost
//! than its parity makes again) is never given: the frames after it waiting on it are dropped with it and the station
//! asked for a key frame (`KEYFRAME`, on the stream) instead of a picture made of a frame's missing references.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, Weak};
use std::time::Duration;

use bytes::Bytes;
use iroh::endpoint::{Connection, SendDatagramError, SendStream};
use tokio::sync::mpsc;
use tokio::time::Instant;

pub(crate) const MAGIC: u8 = 0x53;
pub(crate) const HEADER_LEN: usize = 16;
/// The most data and parity shards of a block.
pub(crate) const MAX_K: usize = 48;
pub(crate) const MAX_M: usize = 24;
/// The most bytes of a frame a shard carries: under every path's MTU with room to spare (a relay's way).
const SHARD_MOST: usize = 1120;
/// A connection whose datagrams are smaller than this sends its frames on the stream.
pub(crate) const DATAGRAM_LEAST: usize = 1024;

const FRAME_CONFIG: u8 = 1;
const FRAME_VIDEO: u8 = 2;
const FRAME_AUDIO_CONFIG: u8 = 5;
const FRAME_AUDIO: u8 = 6;
/// Client -> station frame kind for acknowledging a decoded/displayed video frame (screen-frames.ts ACK).
pub(crate) const FRAME_ACK: u8 = 17;
/// What the client asks of the station when a frame could not be had (client/core-ts screen-frames.ts KEYFRAME).
pub(crate) const KEYFRAME_FRAME: [u8; 5] = [18, 0, 0, 0, 0];
/// A frame longer than this is no frame (screen-frames.ts MAX_FRAME): the stream is out of step, nothing is taken off it.
const FRAME_MAX: usize = 64 * 1024 * 1024;

const FLAG_KEY: u8 = 0x08;
const FLAG_RED: u8 = 0x10;
/// Bit 5 of `Head` flags: sender understands `KIND_ACK` datagrams (older `Head::of` ignores bits 5..7).
const FLAG_ACK: u8 = 0x20;

/// Frames of a kind kept while not yet given (the newest; the oldest goes first).
const WINDOW: usize = 16;
/// Adaptive wait bounds for an in-flight frame when a later frame arrives whole: starts at `GAP_WAIT_MIN` on a clean
/// link and expands up to `GAP_WAIT_MAX` under metro-network reordering/jitter.
const GAP_WAIT_MIN: Duration = Duration::from_millis(12);
const GAP_WAIT_MAX: Duration = Duration::from_millis(45);
/// How long an incomplete frame with no new shards arriving is waited for when nothing after it came.
const STALE: Duration = Duration::from_millis(80);
/// Hard upper bound on total time an incomplete frame may be waited for even if shards trickle in.
const STALE_MAX: Duration = Duration::from_millis(120);
/// A config came but no frame of it arrived at all. With no shards there is no other way to detect its loss.
const FIRST_FRAME_WAIT: Duration = Duration::from_secs(2);
/// Key frames asked for no more often than this (prevents keyframe storms under transient jitter).
const KEYFRAME_EVERY: Duration = Duration::from_millis(300);
/// A key frame asked for and not come whole this long after (lost itself, and the screen still: no frame after it to
/// ask again on) is asked for again.
const KEYFRAME_RETRY: Duration = Duration::from_millis(500);
/// Smooth micro-pacing for medium/large frames: small frames (`<= PACE_SMALL` shards) go immediately with zero delay;
/// larger frames spread in micro-batches of `PACE_BATCH` shards across a linear time budget (`PACE_US_PER_SHARD` per
/// shard, capped at `PACE_MOST` for P-frames and `PACE_MOST_KEY` for keyframes) using deadline pacing so actual
/// `send_datagram_wait` latency is deducted automatically.
const PACE_SMALL: usize = 8;
const PACE_BATCH: usize = 6;
const PACE_US_PER_SHARD: u64 = 75;
const PACE_MOST: Duration = Duration::from_millis(6);
const PACE_MOST_KEY: Duration = Duration::from_millis(10);
const PACE_EVERY: usize = 32;
#[cfg(test)]
const PACE_BEFORE_MOST: Duration = Duration::from_millis(4);
/// How often the link's loss is read again for the parity a frame gets.
const LOSS_EVERY: Duration = Duration::from_millis(200);
/// Unreliable client -> station ACK datagram: `[MAGIC, KIND_ACK, token(4 BE), ts_us(8 BE), wait_us(4 BE)]`.
const KIND_ACK: u8 = 5;
pub(crate) const ACK_LEN: usize = 18;
/// The receiving end's report of the loss its frames' shards had (the module's head).
const KIND_REPORT: u8 = 7;
pub(crate) const REPORT_LEN: usize = 16;
/// How often the receiving end says the loss, while frames come (sooner with fewer than `REPORT_LEAST` shards counted
/// only once `REPORT_LONGEST` has gone).
const REPORT_EVERY: Duration = Duration::from_millis(250);
const REPORT_LEAST: u64 = 32;
const REPORT_LONGEST: Duration = Duration::from_secs(1);
/// A report heard is taken this long (the receiving end stopped saying: frames stopped, or it went).
const REPORT_FRESH: Duration = Duration::from_secs(2);
/// A block not whole when its frame is let go, first seen this long before: its shards still to come are lost too (a
/// frame's go out within `PACE_MOST`); one younger counts only what is missing below the last that came.
const SETTLED: Duration = Duration::from_millis(10);

// ---- GF(2^8), the polynomial 0x11d ----

const fn gf_tables() -> ([u8; 512], [u8; 256]) {
    let mut exp = [0u8; 512];
    let mut log = [0u8; 256];
    let mut x: u16 = 1;
    let mut i = 0;
    while i < 255 {
        exp[i] = x as u8;
        log[x as usize] = i as u8;
        x <<= 1;
        if x & 0x100 != 0 {
            x ^= 0x11d;
        }
        i += 1;
    }
    while i < 512 {
        exp[i] = exp[i - 255];
        i += 1;
    }
    (exp, log)
}

static GF: ([u8; 512], [u8; 256]) = gf_tables();

fn gf_mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        return 0;
    }
    GF.0[GF.1[a as usize] as usize + GF.1[b as usize] as usize]
}

/// `a`'s inverse (`a` not 0).
fn gf_inv(a: u8) -> u8 {
    GF.0[255 - GF.1[a as usize] as usize]
}

/// Every product, a row a factor: a shard multiplied by a lookup a byte.
fn mul_table() -> &'static [[u8; 256]; 256] {
    static TABLE: OnceLock<Box<[[u8; 256]; 256]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = Box::new([[0u8; 256]; 256]);
        for a in 0..256 {
            for b in 0..256 {
                t[a][b] = gf_mul(a as u8, b as u8);
            }
        }
        t
    })
}

/// `dst += c * src`, byte by byte.
fn mul_acc(dst: &mut [u8], src: &[u8], c: u8) {
    match c {
        0 => {}
        1 => dst.iter_mut().zip(src).for_each(|(d, s)| *d ^= s),
        _ => {
            let row = &mul_table()[c as usize];
            dst.iter_mut().zip(src).for_each(|(d, s)| *d ^= row[*s as usize]);
        }
    }
}

/// Parity row `i`'s factor of data shard `j`, of a block of `k`: a Cauchy matrix's, 1 / (x_i + y_j) with x_i = k + i
/// and y_j = j (all different), so every square part of it, and so of the identity over it, can be inverted: any k of
/// the k + m shards make the block again.
fn cauchy(i: usize, j: usize, k: usize) -> u8 {
    gf_inv(((k + i) as u8) ^ (j as u8))
}

/// The `m` parity shards of `data` (shards of one length).
pub(crate) fn rs_encode(data: &[Vec<u8>], m: usize) -> Vec<Vec<u8>> {
    let (k, len) = (data.len(), data.first().map_or(0, Vec::len));
    (0..m)
        .map(|i| {
            let mut p = vec![0u8; len];
            for (j, d) in data.iter().enumerate() {
                mul_acc(&mut p, d, cauchy(i, j, k));
            }
            p
        })
        .collect()
}

/// The `k` data shards of a block of `k + m`, from those that came (`shards[i]`, each `len` long): None while fewer
/// than `k` came.
pub(crate) fn rs_decode(k: usize, shards: &[Option<Vec<u8>>], len: usize) -> Option<Vec<Vec<u8>>> {
    if shards.iter().take(k).all(Option::is_some) {
        return Some(shards[..k].iter().map(|s| s.clone().unwrap()).collect());
    }
    // k of them, data first
    let chosen: Vec<usize> = (0..shards.len()).filter(|&i| shards[i].is_some()).take(k).collect();
    if chosen.len() < k {
        return None;
    }
    // the rows of the chosen shards, inverted (Gauss-Jordan)
    let mut a: Vec<Vec<u8>> = chosen.iter().map(|&i| (0..k).map(|j| if i < k { (i == j) as u8 } else { cauchy(i - k, j, k) }).collect()).collect();
    let mut inv: Vec<Vec<u8>> = (0..k).map(|i| (0..k).map(|j| (i == j) as u8).collect()).collect();
    for col in 0..k {
        let pivot = (col..k).find(|&r| a[r][col] != 0)?;
        a.swap(col, pivot);
        inv.swap(col, pivot);
        let scale = gf_inv(a[col][col]);
        for j in 0..k {
            a[col][j] = gf_mul(a[col][j], scale);
            inv[col][j] = gf_mul(inv[col][j], scale);
        }
        for r in 0..k {
            let f = a[r][col];
            if r != col && f != 0 {
                for j in 0..k {
                    a[r][j] ^= gf_mul(f, a[col][j]);
                    inv[r][j] ^= gf_mul(f, inv[col][j]);
                }
            }
        }
    }
    let mut out = Vec::with_capacity(k);
    for j in 0..k {
        match &shards[j] {
            Some(s) => out.push(s.clone()),
            None => {
                let mut d = vec![0u8; len];
                for (c, &i) in chosen.iter().enumerate() {
                    mul_acc(&mut d, shards[i].as_ref().unwrap(), inv[j][c]);
                }
                out.push(d);
            }
        }
    }
    Some(out)
}

// ---- What is sent ----

/// A datagram's head.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Head {
    pub(crate) kind: u8,
    pub(crate) key: bool,
    pub(crate) red: bool,
    pub(crate) ack_cap: bool,
    pub(crate) token: u32,
    pub(crate) epoch: u8,
    pub(crate) seq: u32,
    pub(crate) block: u8,
    pub(crate) blocks: u8,
    pub(crate) k: u8,
    pub(crate) m: u8,
    pub(crate) shard: u8,
}

impl Head {
    fn put(&self, out: &mut Vec<u8>) {
        out.push(MAGIC);
        out.push((self.kind & 7) | if self.key { FLAG_KEY } else { 0 } | if self.red { FLAG_RED } else { 0 } | if self.ack_cap { FLAG_ACK } else { 0 });
        out.extend(self.token.to_be_bytes());
        out.push(self.epoch);
        out.extend(self.seq.to_be_bytes());
        out.extend([self.block, self.blocks, self.k, self.m, self.shard]);
    }

    /// One of this protocol's heads, sound (None: another datagram, or one that is not).
    pub(crate) fn of(d: &[u8]) -> Option<Head> {
        if d.len() <= HEADER_LEN || d[0] != MAGIC {
            return None;
        }
        let h = Head {
            kind: d[1] & 7,
            key: d[1] & FLAG_KEY != 0,
            red: d[1] & FLAG_RED != 0,
            ack_cap: d[1] & FLAG_ACK != 0,
            token: u32::from_be_bytes([d[2], d[3], d[4], d[5]]),
            epoch: d[6],
            seq: u32::from_be_bytes([d[7], d[8], d[9], d[10]]),
            block: d[11],
            blocks: d[12],
            k: d[13],
            m: d[14],
            shard: d[15],
        };
        let sound = (h.kind == FRAME_VIDEO || h.kind == FRAME_AUDIO)
            && h.token != 0
            && h.seq != 0
            && h.blocks >= 1
            && h.block < h.blocks
            && (1..=MAX_K as u8).contains(&h.k)
            && h.m <= MAX_M as u8
            && h.shard < h.k + h.m;
        sound.then_some(h)
    }
}

/// The parity a block of `k` data shards gets on a link that loses `loss` of its packets lately. However clean the
/// link, a tenth of `k` (one at least) and a key frame's 15% (two at least): Wi-Fi loses two to four packets in a row
/// now and then, and a frame of 40 shards with one parity shard lost so is given up with every frame after it until a
/// key frame, itself the likeliest to lose some. As the loss grows, up to 42% of `k`, steeper than the loss alone asks
/// (Wi-Fi loses in bursts of two and more), and from 2% lost four at least (six from 4% in a block of 12 or more: a
/// frame of 120 a second, small, lost three bursts of two). A block of one shard (a sound packet, a tiny frame) gets
/// one only where it is a key frame or anything is lost.
pub(crate) fn parity_for(k: usize, key: bool, loss: f64) -> usize {
    let least = if k <= 1 {
        usize::from(key || loss > 0.0)
    } else if key {
        ((k as f64 * 0.15).ceil() as usize).max(2)
    } else {
        k.div_ceil(10)
    };
    let m = if loss > 0.005 {
        let m = ((k as f64) * (loss * 3.0 + 0.14).clamp(0.16, 0.42)).ceil() as usize;
        let bursts = if loss >= 0.04 && k >= 12 {
            6
        } else if loss >= 0.02 && k >= 4 {
            4.min(k)
        } else {
            0
        };
        m.max(least).max(bursts).max(if key { 2 } else { 1 })
    } else {
        least
    };
    m.min(MAX_M)
}

/// The parity before the receiving end's reports (a test's, to compare with): one on a clean link.
#[cfg(test)]
pub(crate) fn parity_before(k: usize, key: bool, loss: f64) -> usize {
    let m = if loss > 0.005 {
        let m = ((k as f64) * (loss * 2.0 + 0.12).clamp(0.15, 0.35)).ceil() as usize;
        if key { m.max(2) } else { m.max(1) }
    } else if k == 1 {
        usize::from(key || loss > 0.0)
    } else {
        1
    };
    m.min(MAX_M)
}

/// The receiving end's report: the loss its frames' shards had (millionths) of `shards` counted.
pub(crate) fn report_bytes(token: u32, ppm: u32, shards: u32) -> [u8; REPORT_LEN] {
    let mut d = [0u8; REPORT_LEN];
    d[0] = MAGIC;
    d[1] = KIND_REPORT;
    d[2..6].copy_from_slice(&token.to_be_bytes());
    d[6..10].copy_from_slice(&ppm.to_be_bytes());
    d[10..14].copy_from_slice(&shards.to_be_bytes());
    d
}

/// A report's token and loss (millionths), None where `d` is no report.
pub(crate) fn report_of(d: &[u8]) -> Option<(u32, u32)> {
    if d.len() != REPORT_LEN || d[0] != MAGIC || d[1] != KIND_REPORT {
        return None;
    }
    let token = u32::from_be_bytes([d[2], d[3], d[4], d[5]]);
    let ppm = u32::from_be_bytes([d[6], d[7], d[8], d[9]]);
    (token != 0 && ppm <= 1_000_000).then_some((token, ppm))
}

/// An unreliable client -> station ACK datagram (`KIND_ACK`), carrying frame timestamp `ts` (µs) and viewer hold time
/// `wait_us` (µs). Older receivers pass it over (`Head::of` rejects `kind == 5`, `report_of` rejects length/kind).
#[allow(dead_code)] // Used by stillfail-shell (client side); station's stillfail-mesh only reads KIND_ACK.
pub(crate) fn ack_bytes(token: u32, ts: u64, wait_us: u32) -> [u8; ACK_LEN] {
    let mut d = [0u8; ACK_LEN];
    d[0] = MAGIC;
    d[1] = KIND_ACK;
    d[2..6].copy_from_slice(&token.to_be_bytes());
    d[6..14].copy_from_slice(&ts.to_be_bytes());
    d[14..18].copy_from_slice(&wait_us.to_be_bytes());
    d
}

/// Parses a `KIND_ACK` datagram into `(token, ts_us, wait_us)`.
pub(crate) fn ack_of(d: &[u8]) -> Option<(u32, u64, u32)> {
    if d.len() != ACK_LEN || d[0] != MAGIC || d[1] != KIND_ACK {
        return None;
    }
    let token = u32::from_be_bytes([d[2], d[3], d[4], d[5]]);
    if token == 0 {
        return None;
    }
    let ts = u64::from_be_bytes([d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13]]);
    let wait_us = u32::from_be_bytes([d[14], d[15], d[16], d[17]]);
    Some((token, ts, wait_us))
}

/// Standard stream wire format for `KIND.ack` carrying `(ts, wait_us)`: 17 bytes `[17, 0,0,0,12, ts(8 BE), wait_us(4 BE)]`.
pub(crate) fn ack_frame_bytes(ts: u64, wait_us: u32) -> [u8; 17] {
    let mut f = [0u8; 17];
    f[0] = FRAME_ACK;
    f[1..5].copy_from_slice(&12u32.to_be_bytes());
    f[5..13].copy_from_slice(&ts.to_be_bytes());
    f[13..17].copy_from_slice(&wait_us.to_be_bytes());
    f
}

/// The loss a view's receiving end said last, and when it was heard.
#[derive(Default)]
pub(crate) struct PeerLoss(StdMutex<Option<(f64, Instant)>>);

impl PeerLoss {
    fn heard(&self, ppm: u32, now: Instant) {
        *self.0.lock().unwrap() = Some((ppm as f64 / 1_000_000.0, now));
    }

    /// The loss said within `REPORT_FRESH` of `now` (0 where none).
    pub(crate) fn at(&self, now: Instant) -> f64 {
        match *self.0.lock().unwrap() {
            Some((loss, at)) if now.duration_since(at) < REPORT_FRESH => loss,
            _ => 0.0,
        }
    }
}

/// The reports of a view's receiving end heard on its connection, till this is dropped.
pub(crate) struct Heard {
    demux: Arc<Demux>,
    token: u32,
    pub(crate) loss: Arc<PeerLoss>,
}

impl Drop for Heard {
    fn drop(&mut self) {
        let mut reports = self.demux.reports.lock().unwrap();
        if reports.get(&self.token).is_some_and(|l| Arc::ptr_eq(l, &self.loss)) {
            reports.remove(&self.token);
        }
    }
}

/// The reports for `token` on `conn` from now on (its connection's reader started where none is). None outside a tokio
/// runtime.
pub(crate) fn hear(conn: &Connection, token: u32) -> Option<Heard> {
    tokio::runtime::Handle::try_current().ok()?;
    let demux = demux_of(None, conn);
    let loss = Arc::new(PeerLoss::default());
    demux.reports.lock().unwrap().insert(token, loss.clone());
    Some(Heard { demux, token, loss })
}

/// The share of the frames' shards a receiving end found missing, counted as frames are had or let go (`report`).
#[derive(Default, Debug, Clone, Copy, PartialEq)]
pub(crate) struct LossCount {
    pub(crate) missing: u64,
    pub(crate) shards: u64,
    since: Option<Instant>,
}

impl LossCount {
    /// A block had: the shards below the last that came, those that did not (those after it, its parity not needed,
    /// may well come yet: never counted).
    fn had(&mut self, got: usize, top: usize) {
        self.shards += top as u64;
        self.missing += top.saturating_sub(got) as u64;
    }

    /// A frame let go: its blocks not had, all their shards not come where it is `SETTLED`, else those below the last
    /// that came.
    fn let_go(&mut self, p: &Pending, now: Instant) {
        let settled = now.saturating_duration_since(p.first) >= SETTLED;
        for b in p.blocks.iter().flatten().filter(|b| b.data.is_none()) {
            let all = if settled { b.k + b.m } else { b.top };
            self.shards += all as u64;
            self.missing += all.saturating_sub(b.got) as u64;
        }
    }

    /// The loss to say now (millionths, and of how many shards), once `REPORT_EVERY` has gone since the last said with
    /// shards counted; counting again from there.
    fn report(&mut self, now: Instant) -> Option<(u32, u32)> {
        let since = *self.since.get_or_insert(now);
        if self.shards == 0 {
            self.since = Some(now);
            return None;
        }
        let gone = now.saturating_duration_since(since);
        if gone < REPORT_EVERY || (self.shards < REPORT_LEAST && gone < REPORT_LONGEST) {
            return None;
        }
        let said = ((self.missing.min(self.shards) * 1_000_000 / self.shards) as u32, self.shards.min(u32::MAX as u64) as u32);
        *self = LossCount { since: Some(now), ..LossCount::default() };
        Some(said)
    }
}

/// `pending` but those `keep` says not to, each let go counted.
fn retain_counted(pending: &mut BTreeMap<u32, Pending>, count: &mut LossCount, now: Instant, mut keep: impl FnMut(u32, &Pending) -> bool) {
    pending.retain(|&s, p| {
        let kept = keep(s, p);
        if !kept {
            count.let_go(p, now);
        }
        kept
    });
}

/// The datagrams frame `body` of `kind` goes as (`seq` its number, `epoch` the configs before it), shards no longer
/// than `max_datagram` allows; `prev`: the audio packet before it, carried along where both fit one datagram (RFC 2198's
/// way: a packet lost is had with the next). None where it is too long for any (255 blocks).
#[allow(clippy::too_many_arguments)]
pub(crate) fn datagrams_of(token: u32, kind: u8, key: bool, epoch: u8, seq: u32, body: &[u8], prev: Option<&[u8]>, max_datagram: usize, loss: f64) -> Option<Vec<Vec<u8>>> {
    let cap = max_datagram.saturating_sub(HEADER_LEN + 2).min(SHARD_MOST);
    if cap == 0 {
        return None;
    }
    let head = |block: u8, blocks: u8, k: u8, m: u8, shard: u8, red: bool| Head { kind, key, red, ack_cap: true, token, epoch, seq, block, blocks, k, m, shard };
    if kind == FRAME_AUDIO && body.len() <= cap {
        let red = prev.filter(|p| body.len() + p.len() <= cap);
        let mut d = Vec::with_capacity(HEADER_LEN + 2 + body.len() + red.map_or(0, <[u8]>::len));
        head(0, 1, 1, 0, 0, red.is_some()).put(&mut d);
        d.extend((body.len() as u16).to_be_bytes());
        d.extend_from_slice(body);
        if let Some(p) = red {
            d.extend_from_slice(p);
        }
        return Some(vec![d]);
    }
    let n = body.len().div_ceil(cap).max(1);
    let blocks = n.div_ceil(MAX_K);
    if blocks > 255 {
        return None;
    }
    let (base, extra) = (n / blocks, n % blocks);
    let mut out = Vec::new();
    let mut shard_at = 0usize;
    for b in 0..blocks {
        let k = base + usize::from(b < extra);
        let m = if kind == FRAME_AUDIO { 1 } else { parity_for(k, key, loss) };
        let pieces: Vec<&[u8]> = (shard_at..shard_at + k).map(|s| &body[(s * cap).min(body.len())..((s + 1) * cap).min(body.len())]).collect();
        shard_at += k;
        let len = 2 + pieces.iter().map(|p| p.len()).max().unwrap_or(0);
        let data: Vec<Vec<u8>> = pieces
            .iter()
            .map(|p| {
                let mut d = Vec::with_capacity(len);
                d.extend((p.len() as u16).to_be_bytes());
                d.extend_from_slice(p);
                d.resize(len, 0);
                d
            })
            .collect();
        let parity = rs_encode(&data, m);
        for (i, shard) in data.iter().chain(parity.iter()).enumerate() {
            let mut d = Vec::with_capacity(HEADER_LEN + shard.len());
            head(b as u8, blocks as u8, k as u8, m as u8, i as u8, false).put(&mut d);
            // (a data shard goes without its padding: the parity's length says it where it is needed)
            let used = if i < k { 2 + pieces[i].len() } else { shard.len() };
            d.extend_from_slice(&shard[..used]);
            out.push(d);
        }
    }
    Some(out)
}

/// The share of packets a connection lost lately, across its paths (iroh's counters, read again each `LOSS_EVERY`).
#[derive(Default)]
pub(crate) struct LossMeter {
    last: Option<(Instant, u64, u64)>,
    rate: f64,
}

impl LossMeter {
    /// The rate from the counters now (`lost`, `sent`: totals since the connection opened).
    pub(crate) fn update(&mut self, now: Instant, lost: u64, sent: u64) -> f64 {
        match self.last {
            Some((at, _, _)) if now.duration_since(at) < LOSS_EVERY => {}
            Some((_, l, s)) => {
                let (dl, ds) = (lost.saturating_sub(l), sent.saturating_sub(s));
                if ds > 0 {
                    self.rate = (dl as f64 / ds as f64).min(1.0);
                }
                self.last = Some((now, lost, sent));
            }
            None => self.last = Some((now, lost, sent)),
        }
        self.rate
    }

    fn of(&mut self, conn: &Connection) -> f64 {
        let now = Instant::now();
        if matches!(self.last, Some((at, _, _)) if now.duration_since(at) < LOSS_EVERY) {
            return self.rate;
        }
        let (mut lost, mut sent) = (0u64, 0u64);
        for p in conn.paths().iter() {
            let s = p.stats();
            lost += s.lost_packets;
            sent += s.udp_tx.datagrams;
        }
        self.update(now, lost, sent)
    }
}

/// Target send deadline for shard `index` of a `total`-shard frame started at `start`.
/// Small frames (`total <= PACE_SMALL`) return `None` (zero-delay direct send). Medium/large frames spread in
/// micro-batches of `PACE_BATCH` shards across a linear budget capped at `PACE_MOST` (P-frame) or `PACE_MOST_KEY`
/// (keyframe). Using an absolute deadline from `start` deducts actual `send_datagram_wait` time automatically.
pub(crate) fn pace_deadline(start: Instant, index: usize, total: usize, key: bool) -> Option<Instant> {
    if total <= PACE_SMALL || index == 0 || index % PACE_BATCH != 0 {
        return None;
    }
    let batches = total.div_ceil(PACE_BATCH);
    if batches <= 1 {
        return None;
    }
    let intervals = (batches - 1) as u64;
    let batch_idx = ((index / PACE_BATCH) as u64).min(intervals);
    let cap = if key { PACE_MOST_KEY } else { PACE_MOST };
    let budget_us = (total as u64).saturating_mul(PACE_US_PER_SHARD).min(cap.as_micros() as u64);
    let offset_us = budget_us.saturating_mul(batch_idx) / intervals;
    Some(start + Duration::from_micros(offset_us))
}

/// A view's stream, sending: what is written on it taken apart into its frames, its video and audio frames sent as
/// datagrams on its connection, the rest written on the stream as it came (the reply's head line first, whole).
pub(crate) struct MediaOut {
    token: u32,
    conn: Connection,
    line_done: bool,
    /// What came of a frame not whole yet.
    buf: Vec<u8>,
    /// Out of step (a frame no frame could be): everything on the stream from here.
    raw: bool,
    video_epoch: u8,
    audio_epoch: u8,
    video_seq: u32,
    audio_seq: u32,
    /// Its kind on the stream from now on (datagrams too small or refused): the client stops taking its datagrams.
    video_off: bool,
    audio_off: bool,
    prev_audio: Option<Vec<u8>>,
    loss: LossMeter,
    /// What the receiving end says of the loss its frames have (None: not heard; an end from before says nothing).
    heard: Option<Heard>,
    /// Datagram ACKs arriving for this view's token, handed to the stream reader via `take_ack_rx`.
    ack_rx: Option<AckRx>,
    /// A test's: datagrams dropped before they go (each one with this chance, by a seeded draw), the loss the parity is
    /// made for, and no parity at all (to compare with).
    #[cfg(test)]
    pub(crate) lose: Option<(f64, u64)>,
    #[cfg(test)]
    pub(crate) assumed_loss: Option<f64>,
    #[cfg(test)]
    pub(crate) no_parity: bool,
    /// A test's: as it was before the receiving end's reports (one parity shard on a clean link, the connection's
    /// counters alone, 250 µs asleep every 8 shards), to compare with; lost datagrams `burst` in a row; and how long
    /// each video frame took to send.
    #[cfg(test)]
    pub(crate) before: bool,
    #[cfg(test)]
    pub(crate) burst: usize,
    #[cfg(test)]
    pub(crate) took: Vec<Duration>,
    #[cfg(test)]
    pub(crate) shards: (u64, u64),
}

impl MediaOut {
    /// None where the connection's datagrams are too small to be worth it (or none).
    pub(crate) fn new(conn: Connection, token: u32) -> Option<MediaOut> {
        if token == 0 || conn.max_datagram_size().is_none_or(|n| n < DATAGRAM_LEAST) {
            return None;
        }
        let heard = hear(&conn, token);
        let ack_rx = hear_acks(&conn, token);
        Some(MediaOut { token, conn, line_done: false, buf: Vec::new(), raw: false, video_epoch: 0, audio_epoch: 0, video_seq: 0, audio_seq: 0, video_off: false, audio_off: false, prev_audio: None, loss: LossMeter::default(), heard, ack_rx, #[cfg(test)] lose: None, #[cfg(test)] assumed_loss: None, #[cfg(test)] no_parity: false, #[cfg(test)] before: false, #[cfg(test)] burst: 1, #[cfg(test)] took: Vec::new(), #[cfg(test)] shards: (0, 0) })
    }

    /// Takes the datagram ACK receiver for this view so the stream's read half can inject `KIND.ack` frames at
    /// stream frame boundaries.
    pub(crate) fn take_ack_rx(&mut self) -> Option<AckRx> {
        self.ack_rx.take()
    }

    /// `bytes` written: on the stream, or as datagrams where they are a frame of a picture or of sound.
    pub(crate) async fn write(&mut self, send: &mut SendStream, mut bytes: &[u8]) -> Result<(), String> {
        if !self.line_done {
            match bytes.iter().position(|&b| b == b'\n') {
                Some(at) => {
                    send.write_all(&bytes[..=at]).await.map_err(|e| e.to_string())?;
                    self.line_done = true;
                    bytes = &bytes[at + 1..];
                }
                None => return send.write_all(bytes).await.map_err(|e| e.to_string()),
            }
        }
        if self.raw {
            return send.write_all(bytes).await.map_err(|e| e.to_string());
        }
        let owned;
        let data: &[u8] = if self.buf.is_empty() {
            bytes
        } else {
            self.buf.extend_from_slice(bytes);
            owned = std::mem::take(&mut self.buf);
            &owned
        };
        let mut at = 0;
        // stream bytes not written yet, from `plain` to `at`
        let mut plain = 0;
        while data.len() - at >= 5 {
            let len = u32::from_be_bytes([data[at + 1], data[at + 2], data[at + 3], data[at + 4]]) as usize;
            if len > FRAME_MAX {
                self.raw = true;
                at = data.len();
                break;
            }
            if data.len() - at < 5 + len {
                break;
            }
            let (kind, body) = (data[at], &data[at + 5..at + 5 + len]);
            let media = match kind {
                FRAME_VIDEO => !self.video_off && body.len() >= 9,
                FRAME_AUDIO => !self.audio_off && body.len() > 8,
                FRAME_CONFIG => {
                    self.video_epoch = self.video_epoch.wrapping_add(1);
                    false
                }
                FRAME_AUDIO_CONFIG => {
                    self.audio_epoch = self.audio_epoch.wrapping_add(1);
                    self.prev_audio = None;
                    false
                }
                _ => false,
            };
            if media {
                if plain < at {
                    send.write_all(&data[plain..at]).await.map_err(|e| e.to_string())?;
                }
                if !self.send_media(kind, body).await? {
                    send.write_all(&data[at..at + 5 + len]).await.map_err(|e| e.to_string())?;
                }
                plain = at + 5 + len;
            }
            at += 5 + len;
        }
        if self.raw {
            at = data.len();
        }
        if plain < at {
            send.write_all(&data[plain..at]).await.map_err(|e| e.to_string())?;
        }
        if at < data.len() {
            self.buf = data[at..].to_vec();
        }
        Ok(())
    }

    /// Frame `body` of `kind` sent as datagrams: false where it goes on the stream (and its kind from now on).
    async fn send_media(&mut self, kind: u8, body: &[u8]) -> Result<bool, String> {
        let video = kind == FRAME_VIDEO;
        let off = |me: &mut MediaOut| {
            if video {
                me.video_off = true;
            } else {
                me.audio_off = true;
            }
            crate::tally(if video { "dgram.video.off" } else { "dgram.audio.off" });
            Ok(false)
        };
        let Some(max) = self.conn.max_datagram_size().filter(|&n| n >= DATAGRAM_LEAST) else { return off(self) };
        // (the larger of the connection's counters, which miss a datagram lost, and what the receiving end says)
        let loss = self.loss.of(&self.conn).max(self.heard.as_ref().map_or(0.0, |h| h.loss.at(Instant::now())));
        #[cfg(test)]
        let loss = if self.before { self.loss.of(&self.conn) } else { loss };
        #[cfg(test)]
        let loss = self.assumed_loss.unwrap_or(loss);
        let (seq, epoch) = if video {
            self.video_seq = self.video_seq.wrapping_add(1).max(1);
            (self.video_seq, self.video_epoch)
        } else {
            self.audio_seq = self.audio_seq.wrapping_add(1).max(1);
            (self.audio_seq, self.audio_epoch)
        };
        let key = video && body[0] & 1 == 1;
        let prev = if video { None } else { self.prev_audio.as_deref() };
        let Some(datagrams) = datagrams_of(self.token, kind, key, epoch, seq, body, prev, max, loss) else { return off(self) };
        #[cfg(test)]
        let datagrams: Vec<Vec<u8>> = {
            let (before, mut left) = (self.before, 0usize);
            let datagrams: Vec<Vec<u8>> = datagrams
                .into_iter()
                .filter(|d| !self.no_parity || Head::of(d).is_some_and(|h| h.shard < h.k))
                // (the parity rows do not depend on how many there are: the first of them are what fewer would be)
                .filter(|d| !before || !video || Head::of(d).is_some_and(|h| (h.shard as usize) < h.k as usize + parity_before(h.k as usize, h.key, loss)))
                .collect();
            if video {
                let data = datagrams.iter().filter(|d| Head::of(d).is_some_and(|h| h.shard < h.k)).count() as u64;
                self.shards.0 += data;
                self.shards.1 += datagrams.len() as u64 - data;
            }
            let burst = self.burst.max(1);
            datagrams
                .into_iter()
                .filter(|_| match &mut self.lose {
                    _ if left > 0 => {
                        left -= 1;
                        false
                    }
                    Some((chance, state)) => {
                        *state ^= *state << 13;
                        *state ^= *state >> 7;
                        *state ^= *state << 17;
                        let kept = (*state % 1_000_000) as f64 / 1_000_000.0 >= *chance;
                        if !kept {
                            left = burst - 1;
                        }
                        kept
                    }
                    None => true,
                })
                .collect()
        };
        if !video {
            self.prev_audio = Some(body.to_vec());
        }
        let (start, total) = (Instant::now(), datagrams.len());
        for (i, d) in datagrams.into_iter().enumerate() {
            #[cfg(test)]
            if self.before {
                if i > 0 && i % 8 == 0 && total > 8 && start.elapsed() < PACE_BEFORE_MOST {
                    tokio::time::sleep(Duration::from_micros(250)).await;
                }
            } else if let Some(deadline) = pace_deadline(start, i, total, key) {
                if Instant::now() < deadline {
                    tokio::time::sleep_until(deadline).await;
                } else if i % PACE_EVERY == 0 {
                    tokio::task::yield_now().await;
                }
            }
            #[cfg(not(test))]
            if let Some(deadline) = pace_deadline(start, i, total, key) {
                if Instant::now() < deadline {
                    tokio::time::sleep_until(deadline).await;
                } else if i % PACE_EVERY == 0 {
                    tokio::task::yield_now().await;
                }
            }
            match self.conn.send_datagram_wait(Bytes::from(d)).await {
                Ok(()) => {}
                Err(SendDatagramError::ConnectionLost(e)) => return Err(e.to_string()),
                Err(_) => return off(self),
            }
        }
        #[cfg(test)]
        if video {
            self.took.push(start.elapsed());
        }
        crate::tally(if video { "dgram.video" } else { "dgram.audio" });
        Ok(true)
    }
}

// ---- What is received ----

/// A block of a frame as its shards come.
struct Block {
    k: usize,
    m: usize,
    shards: Vec<Option<Vec<u8>>>,
    have: usize,
    /// The parity's length (every data shard's padded to it): 0 until a parity shard came.
    len: usize,
    /// Its bytes, once had.
    data: Option<Vec<u8>>,
    /// The shards that came (till it was had), and one past the last of them (the loss: `LossCount`).
    got: usize,
    top: usize,
}

/// A frame as its blocks come.
struct Pending {
    key: bool,
    epoch: u8,
    blocks: Vec<Option<Block>>,
    done: usize,
    first: Instant,
    /// Most recent time any valid shard of this frame arrived.
    last_activity: Instant,
    /// Whether this frame spans more than one shard (used to avoid pulling jitter EWMA to 0 on 1-shard frames).
    multi_shard: bool,
    whole: Option<(Vec<u8>, Instant)>,
    /// The audio packet before it, carried along.
    prev: Option<Vec<u8>>,
}

impl Pending {
    fn new(h: &Head, now: Instant) -> Pending {
        Pending {
            key: h.key,
            epoch: h.epoch,
            blocks: (0..h.blocks).map(|_| None).collect(),
            done: 0,
            first: now,
            last_activity: now,
            multi_shard: h.blocks > 1 || h.k > 1,
            whole: None,
            prev: None,
        }
    }

    /// A shard taken in; whether the frame is whole now (a block had counted in `count`).
    fn take(&mut self, h: &Head, shard: &[u8], now: Instant, count: &mut LossCount) -> bool {
        if self.whole.is_some() || h.blocks as usize != self.blocks.len() || h.key != self.key || h.epoch != self.epoch {
            return false;
        }
        let (k, m) = (h.k as usize, h.m as usize);
        let block = self.blocks[h.block as usize].get_or_insert_with(|| Block { k, m, shards: vec![None; k + m], have: 0, len: 0, data: None, got: 0, top: 0 });
        if block.k != k || block.m != m || block.data.is_some() || block.shards[h.shard as usize].is_some() || shard.len() < 2 {
            return false;
        }
        self.last_activity = now;
        let i = h.shard as usize;
        block.got += 1;
        block.top = block.top.max(i + 1);
        if i >= k {
            if block.len != 0 && block.len != shard.len() {
                return false;
            }
            block.len = shard.len();
        } else if h.red && k == 1 {
            // the packet, then the one before it
            let n = u16::from_be_bytes([shard[0], shard[1]]) as usize;
            if 2 + n > shard.len() {
                return false;
            }
            if 2 + n < shard.len() {
                self.prev = Some(shard[2 + n..].to_vec());
            }
            block.shards[i] = Some(shard[..2 + n].to_vec());
            block.have += 1;
            return self.block_whole(h.block as usize, now, count);
        }
        block.shards[i] = Some(shard.to_vec());
        block.have += 1;
        self.block_whole(h.block as usize, now, count)
    }

    fn block_whole(&mut self, b: usize, now: Instant, count: &mut LossCount) -> bool {
        let block = self.blocks[b].as_mut().unwrap();
        if block.have < block.k {
            return false;
        }
        let all_data = block.shards[..block.k].iter().all(Option::is_some);
        let shards = if all_data {
            block.shards[..block.k].iter().map(|s| s.clone().unwrap()).collect()
        } else {
            let len = block.len;
            let padded: Vec<Option<Vec<u8>>> = block
                .shards
                .iter()
                .enumerate()
                .map(|(i, s)| {
                    s.as_ref().map(|s| {
                        let mut s = s.clone();
                        if i < block.k {
                            s.resize(len, 0);
                        }
                        s
                    })
                })
                .collect();
            match rs_decode(block.k, &padded, len) {
                Some(d) => d,
                None => return false,
            }
        };
        let mut data = Vec::new();
        for s in &shards {
            let n = u16::from_be_bytes([s[0], s[1]]) as usize;
            if 2 + n > s.len() {
                // not made again as it was sent: the frame cannot be had
                block.shards.iter_mut().for_each(|s| *s = None);
                block.have = 0;
                return false;
            }
            data.extend_from_slice(&s[2..2 + n]);
        }
        if !all_data {
            crate::tally("dgram.recovered");
        }
        block.data = Some(data);
        block.shards = Vec::new();
        count.had(block.got, block.top);
        self.done += 1;
        if self.done < self.blocks.len() {
            return false;
        }
        let mut frame = Vec::new();
        for b in self.blocks.iter_mut() {
            frame.append(b.as_mut().unwrap().data.as_mut().unwrap());
        }
        self.whole = Some((frame, now));
        true
    }
}

/// A view's frames of one kind as they come.
#[derive(Default)]
struct Kind {
    pending: BTreeMap<u32, Pending>,
    /// The last given (0: none yet).
    last: u32,
    /// A frame was given up: none given until a key frame (video).
    broken: bool,
    /// The stream carries this kind now: its datagrams are passed over.
    closed: bool,
    /// Frames given, of a config the stream has not carried yet: held for it.
    held: VecDeque<(u8, Vec<u8>)>,
}

/// What a view's receiving end counts (a test's, and the shell's tallies).
#[derive(Default, Debug, Clone, Copy, PartialEq)]
pub(crate) struct Counts {
    pub(crate) video: u64,
    pub(crate) audio: u64,
    pub(crate) red: u64,
    pub(crate) given_up: u64,
    pub(crate) keyframes: u64,
}

/// A view's stream, receiving: its frames that come as datagrams (`datagram`) made whole again and put in order, each
/// given (`ready`) where the stream is between two of its frames (`stream` follows what the stream carries: its
/// configs, and where its frames start and end).
pub(crate) struct MediaIn {
    token: u32,
    line_done: bool,
    head: [u8; 5],
    head_have: usize,
    kind: u8,
    rem: usize,
    out_of_step: bool,
    video_epoch: u8,
    audio_epoch: u8,
    video: Kind,
    audio: Kind,
    /// Frames to give, whole (`[kind, length, body]` each), in order.
    pub(crate) ready: VecDeque<(u8, Vec<u8>)>,
    want_keyframe: bool,
    asked_keyframe: Option<Instant>,
    wait_from: Option<Instant>,
    /// A config's first frame, if it has not arrived; and the epoch of the last frame made whole (which may precede its config).
    first_frame: Option<(u8, Instant)>,
    last_video_epoch: Option<u8>,
    pub(crate) counts: Counts,
    /// The shards missing of the frames had or let go since the loss was last said (`take_report`).
    pub(crate) loss: LossCount,
    /// The time last told (a datagram's, a tick's): when what is let go between is counted.
    clock: Option<Instant>,
    /// EWMA of observed video shard arrival span / reorder wait in microseconds, driving adaptive `gap_wait()`.
    jitter_us: f64,
    /// Shared flag flipped true once any datagram from the sender carries `FLAG_ACK`.
    peer_ack_cap: Option<Arc<AtomicBool>>,
}

/// `[kind, length (u32, big-endian), body]`.
#[cfg(test)]
pub(crate) fn frame_bytes(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(5 + body.len());
    f.push(kind);
    f.extend((body.len() as u32).to_be_bytes());
    f.extend_from_slice(body);
    f
}

impl MediaIn {
    /// `line`: the stream's first line (its reply's head) is still to come.
    pub(crate) fn new(token: u32, line: bool) -> MediaIn {
        MediaIn {
            token,
            line_done: !line,
            head: [0; 5],
            head_have: 0,
            kind: 0,
            rem: 0,
            out_of_step: false,
            video_epoch: 0,
            audio_epoch: 0,
            video: Kind::default(),
            audio: Kind::default(),
            ready: VecDeque::new(),
            want_keyframe: false,
            asked_keyframe: None,
            wait_from: None,
            first_frame: None,
            last_video_epoch: None,
            counts: Counts::default(),
            loss: LossCount::default(),
            clock: None,
            jitter_us: 0.0,
            peer_ack_cap: None,
        }
    }

    /// Registers a shared atomic flag that will be set to `true` once any datagram for this view advertises `FLAG_ACK`.
    #[allow(dead_code)] // Used by stillfail-shell (client side); station's stillfail-mesh only reads KIND_ACK.
    pub(crate) fn set_peer_ack_cap(&mut self, cap: Arc<AtomicBool>) {
        self.peer_ack_cap = Some(cap);
    }

    /// Adaptive reorder/gap wait: `GAP_WAIT_MIN` (12 ms) on a clean link, expanding up to `GAP_WAIT_MAX` (45 ms)
    /// when shard arrival span or inter-frame reordering jitter is observed.
    pub(crate) fn gap_wait(&self) -> Duration {
        let target_us = (self.jitter_us * 2.0).round() as u64;
        Duration::from_micros(target_us).clamp(GAP_WAIT_MIN, GAP_WAIT_MAX)
    }

    fn record_jitter(&mut self, sample: Duration) {
        let sample_us = sample.as_micros() as f64;
        // Envelope-tracking EWMA: fast rise on jitter spikes (0.35), slow decay when calm (0.03) so periodic
        // metro/Wi-Fi jitter spikes keep `gap_wait` above the spike tail without staying high forever.
        let alpha = if sample_us > self.jitter_us { 0.35 } else { 0.03 };
        self.jitter_us += alpha * (sample_us - self.jitter_us);
    }

    /// Whether what the stream carried so far ends between two of its frames.
    pub(crate) fn at_boundary(&self) -> bool {
        self.line_done && !self.out_of_step && self.rem == 0 && self.head_have == 0
    }

    /// What came next on the stream, followed: where the last place in it is that is between two frames (the frames
    /// ready go there), None where there is none.
    pub(crate) fn stream(&mut self, chunk: &[u8], now: Instant) -> Option<usize> {
        let mut at = 0;
        if !self.line_done {
            at = chunk.iter().position(|&b| b == b'\n')? + 1;
            self.line_done = true;
        }
        if self.out_of_step {
            return None;
        }
        let mut boundary = self.at_boundary().then_some(at);
        while at < chunk.len() {
            if self.rem > 0 {
                let take = self.rem.min(chunk.len() - at);
                at += take;
                self.rem -= take;
                if self.rem == 0 {
                    self.frame_done(now);
                    boundary = Some(at);
                }
                continue;
            }
            self.head[self.head_have] = chunk[at];
            self.head_have += 1;
            at += 1;
            if self.head_have == 5 {
                self.head_have = 0;
                self.kind = self.head[0];
                let len = u32::from_be_bytes([self.head[1], self.head[2], self.head[3], self.head[4]]) as usize;
                if len > FRAME_MAX {
                    self.out_of_step = true;
                    return None;
                }
                self.rem = len;
                // A reliable video frame is on its way. It can take longer than the datagram deadline to arrive.
                if self.kind == FRAME_VIDEO {
                    self.first_frame = None;
                }
                if len == 0 {
                    self.frame_done(now);
                    boundary = Some(at);
                }
            }
        }
        boundary
    }

    fn frame_done(&mut self, now: Instant) {
        match self.kind {
            FRAME_CONFIG => {
                self.video_epoch = self.video_epoch.wrapping_add(1);
                let had_frame = self.last_video_epoch == Some(self.video_epoch) || self.video.held.iter().any(|(epoch, _)| *epoch == self.video_epoch);
                Self::config_came(&mut self.video, self.video_epoch, &mut self.ready, FRAME_VIDEO, &mut self.loss, self.clock);
                self.wait_from = None;
                self.first_frame = (!self.video.closed && !had_frame).then_some((self.video_epoch, now + FIRST_FRAME_WAIT));
            }
            FRAME_AUDIO_CONFIG => {
                self.audio_epoch = self.audio_epoch.wrapping_add(1);
                Self::config_came(&mut self.audio, self.audio_epoch, &mut self.ready, FRAME_AUDIO, &mut self.loss, self.clock);
            }
            // (the station sends this kind on the stream now: what came of it as datagrams is no longer to be given)
            FRAME_VIDEO => {
                self.first_frame = None;
                Self::close(&mut self.video);
            }
            FRAME_AUDIO => Self::close(&mut self.audio),
            _ => {}
        }
    }

    fn close(kind: &mut Kind) {
        kind.closed = true;
        kind.pending.clear();
        kind.held.clear();
    }

    /// A config of `kind` came on the stream (its `epoch` now): what was held for it given, what was of the one before
    /// dropped.
    fn config_came(kind: &mut Kind, epoch: u8, ready: &mut VecDeque<(u8, Vec<u8>)>, which: u8, count: &mut LossCount, now: Option<Instant>) {
        match now {
            Some(now) => retain_counted(&mut kind.pending, count, now, |_, p| (p.epoch.wrapping_sub(epoch) as i8) >= 0),
            None => kind.pending.retain(|_, p| (p.epoch.wrapping_sub(epoch) as i8) >= 0),
        }
        while let Some((e, _)) = kind.held.front() {
            match e.wrapping_sub(epoch) as i8 {
                0 => ready.push_back((which, kind.held.pop_front().unwrap().1)),
                d if d < 0 => {
                    kind.held.pop_front();
                }
                _ => break,
            }
        }
    }

    /// A datagram that came on the connection for this view.
    pub(crate) fn datagram(&mut self, d: &[u8], now: Instant) {
        let Some(h) = Head::of(d) else { return };
        if h.token != self.token {
            return;
        }
        if h.ack_cap {
            if let Some(cap) = &self.peer_ack_cap {
                cap.store(true, Ordering::Relaxed);
            }
        }
        self.clock = Some(now);
        let shard = &d[HEADER_LEN..];
        let video = h.kind == FRAME_VIDEO;
        let kind = if video { &mut self.video } else { &mut self.audio };
        if kind.closed || h.seq <= kind.last {
            return;
        }
        let whole = kind.pending.entry(h.seq).or_insert_with(|| Pending::new(&h, now)).take(&h, shard, now, &mut self.loss);
        let jitter_sample = if whole && video {
            let p = kind.pending.get(&h.seq);
            let span = p.map(|p| now.saturating_duration_since(p.first)).unwrap_or(Duration::ZERO);
            let multi = p.is_some_and(|p| p.multi_shard);
            let reorder = if h.seq == kind.last.wrapping_add(1) {
                self.wait_from.map(|wf| now.saturating_duration_since(wf)).unwrap_or(Duration::ZERO)
            } else {
                Duration::ZERO
            };
            let sample = span.max(reorder);
            (multi || !sample.is_zero()).then_some(sample)
        } else {
            None
        };
        // the oldest let go past the window
        let mut lost_next = false;
        while kind.pending.len() > WINDOW {
            let (oldest, p) = kind.pending.pop_first().unwrap();
            self.loss.let_go(&p, now);
            lost_next |= video && oldest == kind.last.wrapping_add(1) && !kind.broken;
        }
        if let Some(sample) = jitter_sample {
            self.record_jitter(sample);
        }
        if lost_next {
            self.give_up();
        }
        if whole {
            if video {
                self.advance(now);
                if self.video.broken {
                    self.want_keyframe = true;
                }
            } else {
                self.audio_whole(h.seq);
            }
        }
    }

    fn audio_whole(&mut self, seq: u32) {
        let Some(mut p) = self.audio.pending.remove(&seq) else { return };
        let (frame, _) = p.whole.take().unwrap();
        if let Some(prev) = p.prev.take() {
            if seq > 1 && seq - 1 > self.audio.last {
                self.counts.red += 1;
                crate::tally("dgram.audio.red");
                self.gate(false, p.epoch, prev);
            }
        }
        self.audio.last = seq;
        let now = self.clock.unwrap_or(p.first);
        retain_counted(&mut self.audio.pending, &mut self.loss, now, |s, _| s > seq);
        self.counts.audio += 1;
        self.gate(false, p.epoch, frame);
    }

    /// Video frames given as far as they can be: in order from the last given, or from a key frame that came whole.
    fn advance(&mut self, now: Instant) {
        loop {
            let next = self.video.last.wrapping_add(1);
            if !self.video.broken && self.video.pending.get(&next).is_some_and(|p| p.whole.is_some()) {
                let p = self.video.pending.remove(&next).unwrap();
                self.give_video(next, p);
                continue;
            }
            let key = self.video.pending.iter().find(|(s, p)| p.key && p.whole.is_some() && **s > self.video.last).map(|(s, _)| *s);
            match key {
                Some(s) => {
                    let p = self.video.pending.remove(&s).unwrap();
                    retain_counted(&mut self.video.pending, &mut self.loss, now, |q, _| q > s);
                    self.video.broken = false;
                    self.want_keyframe = false;
                    self.give_video(s, p);
                }
                None => break,
            }
        }
        if self.video.broken {
            return;
        }
        let next = self.video.last.wrapping_add(1);
        let gap_wait = self.gap_wait();
        let next_p = self.video.pending.get(&next);
        let next_active = next_p.is_some_and(|p| {
            now.saturating_duration_since(p.last_activity) < gap_wait
                && now.saturating_duration_since(p.first) < STALE_MAX
        });
        let after = self.video.pending.iter().filter(|(s, p)| **s > next && p.whole.is_some()).map(|(s, p)| (*s, p.whole.as_ref().unwrap().1)).last();
        match after {
            Some((s, _)) if s > next.wrapping_add(4) => self.give_up(),
            Some((s, at)) if s >= next.wrapping_add(2) => {
                if !next_active {
                    self.give_up();
                } else {
                    let from = *self.wait_from.get_or_insert(at);
                    if now.saturating_duration_since(from) >= gap_wait {
                        self.give_up();
                    }
                }
            }
            Some((_, at)) => {
                let from = *self.wait_from.get_or_insert(at);
                if now.saturating_duration_since(from) >= gap_wait
                    || next_p.is_some_and(|p| now.saturating_duration_since(p.first) >= STALE_MAX)
                {
                    self.give_up();
                }
            }
            None => {
                self.wait_from = None;
                if next_p.is_some_and(|p| {
                    now.saturating_duration_since(p.last_activity) >= STALE
                        || now.saturating_duration_since(p.first) >= STALE_MAX
                }) {
                    self.give_up();
                }
            }
        }
    }

    fn give_video(&mut self, seq: u32, mut p: Pending) {
        self.video.last = seq;
        self.wait_from = None;
        self.last_video_epoch = Some(p.epoch);
        if self.first_frame.is_some_and(|(epoch, _)| epoch == p.epoch) {
            self.first_frame = None;
        }
        self.counts.video += 1;
        let (frame, _) = p.whole.take().unwrap();
        self.gate(true, p.epoch, frame);
    }

    /// The frame waited on cannot be had: none given until a key frame, which the station is asked for.
    fn give_up(&mut self) {
        self.video.broken = true;
        let now = self.clock.unwrap_or_else(Instant::now);
        retain_counted(&mut self.video.pending, &mut self.loss, now, |_, p| p.key);
        self.wait_from = None;
        self.first_frame = None;
        self.want_keyframe = true;
        self.counts.given_up += 1;
        crate::tally("dgram.video.lost");
    }

    /// A frame given where the stream has carried its config; held for it where it has not yet.
    fn gate(&mut self, video: bool, epoch: u8, frame: Vec<u8>) {
        let (kind, seen, which) = if video { (&mut self.video, self.video_epoch, FRAME_VIDEO) } else { (&mut self.audio, self.audio_epoch, FRAME_AUDIO) };
        let overflow = match epoch.wrapping_sub(seen) as i8 {
            0 if kind.held.is_empty() => {
                self.ready.push_back((which, frame));
                false
            }
            d if d < 0 => false,
            _ => {
                kind.held.push_back((epoch, frame));
                let over = kind.held.len() > WINDOW;
                if over {
                    kind.held.clear();
                }
                over
            }
        };
        if overflow && video {
            self.give_up();
        }
    }

    /// When `tick` is to be called next (a frame waited on given up then), if ever.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        if self.video.closed {
            return None;
        }
        if self.video.broken {
            return if self.want_keyframe {
                self.asked_keyframe.map(|at| at + KEYFRAME_EVERY).filter(|at| self.clock.is_some_and(|now| now < *at))
            } else {
                self.asked_keyframe.map(|at| at + KEYFRAME_RETRY)
            };
        }
        let gap_wait = self.gap_wait();
        let wait = self.wait_from.map(|w| w + gap_wait);
        let next = self.video.last.wrapping_add(1);
        let next_p = self.video.pending.get(&next).filter(|p| p.whole.is_none());
        let active_expire = if self.wait_from.is_some()
            && self.video.pending.iter().any(|(s, p)| *s >= next.wrapping_add(2) && p.whole.is_some())
        {
            next_p.map(|p| p.last_activity + gap_wait)
        } else {
            None
        };
        let stale = next_p.map(|p| (p.last_activity + STALE).min(p.first + STALE_MAX));
        [wait, active_expire, stale, self.first_frame.map(|(_, at)| at)].into_iter().flatten().min()
    }

    pub(crate) fn tick(&mut self, now: Instant) {
        self.clock = Some(now);
        if self.video.closed {
            return;
        }
        if self.video.broken {
            if !self.want_keyframe && self.asked_keyframe.is_some_and(|at| now.duration_since(at) >= KEYFRAME_RETRY) {
                self.want_keyframe = true;
            }
            return;
        }
        if self.first_frame.is_some_and(|(_, at)| now >= at) {
            self.give_up();
            return;
        }
        self.advance(now);
    }

    /// Whether the station is to be asked for a key frame now (`KEYFRAME_FRAME` on the stream).
    pub(crate) fn take_keyframe(&mut self, now: Instant) -> bool {
        if !self.want_keyframe {
            return false;
        }
        if self.asked_keyframe.is_some_and(|at| now.duration_since(at) < KEYFRAME_EVERY) {
            // (asked lately: asked again only while still broken, once that long has gone)
            return false;
        }
        self.want_keyframe = false;
        self.asked_keyframe = Some(now);
        self.counts.keyframes += 1;
        true
    }

    /// The loss to say to the sending end now (`report_bytes`), if it is time to.
    pub(crate) fn take_report(&mut self, now: Instant) -> Option<[u8; REPORT_LEN]> {
        let (ppm, shards) = self.loss.report(now)?;
        Some(report_bytes(self.token, ppm, shards))
    }

    /// The frames ready, whole, appended to `out`.
    pub(crate) fn drain_into(&mut self, out: &mut Vec<u8>) {
        while let Some((kind, body)) = self.ready.pop_front() {
            out.push(kind);
            out.extend((body.len() as u32).to_be_bytes());
            out.extend(body);
        }
    }
}

// ---- A connection's datagrams, to the views they are for ----

/// The datagrams a view's token is given at most while not taken (a reader that stopped): the newest are dropped.
const ROUTE_QUEUE: usize = 4096;

/// Maximum buffered datagram ACKs per view before newest are dropped.
const ACK_QUEUE: usize = 256;

/// A connection's datagrams read once views ask for them (`route`, `hear`, `hear_acks`), each frame's given to the view
/// its token names, each report to the view sending under it, and each datagram ACK to its view's read half; others
/// (`conn.answers`' one byte, a view's gone) passed over. Read until the last view lets go. One a connection, whoever
/// asks (the shell's or the addon's slot, or a view sent).
pub(crate) struct Demux {
    /// The connection's `stable_id` (its entry in `demuxes`).
    id: usize,
    conn: Connection,
    routes: StdMutex<HashMap<u32, mpsc::Sender<Bytes>>>,
    reports: StdMutex<HashMap<u32, Arc<PeerLoss>>>,
    acks: StdMutex<HashMap<u32, mpsc::Sender<(u64, u32)>>>,
    task: StdMutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Demux {
    fn drop(&mut self) {
        if let Some(task) = self.task.lock().unwrap().take() {
            task.abort();
        }
        let mut all = demuxes().lock().unwrap();
        if all.get(&self.id).is_some_and(|w| w.strong_count() == 0) {
            all.remove(&self.id);
        }
    }
}

/// Every connection's reader, by its `stable_id`: a connection is read by one only.
fn demuxes() -> &'static StdMutex<HashMap<usize, Weak<Demux>>> {
    static ALL: OnceLock<StdMutex<HashMap<usize, Weak<Demux>>>> = OnceLock::new();
    ALL.get_or_init(StdMutex::default)
}

/// `conn`'s reader (`slot`'s, or the one started for it elsewhere, or a new one).
fn demux_of(slot: Option<&StdMutex<Weak<Demux>>>, conn: &Connection) -> Arc<Demux> {
    let mut slot = slot.map(|s| s.lock().unwrap());
    if let Some(d) = slot.as_ref().and_then(|s| s.upgrade()) {
        return d;
    }
    let id = conn.stable_id();
    let mut all = demuxes().lock().unwrap();
    let d = match all.get(&id).and_then(Weak::upgrade) {
        Some(d) => d,
        None => {
            let d = Arc::new(Demux { id, conn: conn.clone(), routes: StdMutex::default(), reports: StdMutex::default(), acks: StdMutex::default(), task: StdMutex::default() });
            let (weak, conn) = (Arc::downgrade(&d), conn.clone());
            let task = tokio::spawn(async move {
                while let Ok(datagram) = conn.read_datagram().await {
                    let Some(demux) = weak.upgrade() else { break };
                    if let Some((token, ppm)) = report_of(&datagram) {
                        let to = demux.reports.lock().unwrap().get(&token).cloned();
                        if let Some(to) = to {
                            to.heard(ppm, Instant::now());
                            crate::tally("dgram.loss.heard");
                        }
                        continue;
                    }
                    if let Some((token, ts, wait_us)) = ack_of(&datagram) {
                        let to = demux.acks.lock().unwrap().get(&token).cloned();
                        if let Some(to) = to {
                            let _ = to.try_send((ts, wait_us));
                            crate::tally("dgram.ack.heard");
                        }
                        continue;
                    }
                    let Some(h) = Head::of(&datagram) else { continue };
                    let to = demux.routes.lock().unwrap().get(&h.token).cloned();
                    if let Some(to) = to {
                        let _ = to.try_send(datagram);
                    }
                }
            });
            *d.task.lock().unwrap() = Some(task);
            all.insert(id, Arc::downgrade(&d));
            d
        }
    };
    if let Some(slot) = slot.as_mut() {
        **slot = Arc::downgrade(&d);
    }
    d
}

/// A view's datagrams, given to it till this is dropped.
pub(crate) struct Route {
    demux: Arc<Demux>,
    token: u32,
}

impl Drop for Route {
    fn drop(&mut self) {
        self.demux.routes.lock().unwrap().remove(&self.token);
    }
}

/// The datagrams of `conn` for `token` (its connection's reader started where none is: `slot` holds it): None where
/// another view of it has that token.
pub(crate) fn route(slot: &StdMutex<Weak<Demux>>, conn: &Connection, token: u32) -> Option<(Route, mpsc::Receiver<Bytes>)> {
    if token == 0 {
        return None;
    }
    let demux = demux_of(Some(slot), conn);
    let (to, rx) = mpsc::channel(ROUTE_QUEUE);
    {
        let mut routes = demux.routes.lock().unwrap();
        if routes.contains_key(&token) {
            return None;
        }
        routes.insert(token, to);
    }
    Some((Route { demux, token }, rx))
}

/// A view's receiving end at the shell or the addon: what it follows, and its datagrams.
pub(crate) struct MediaRx {
    pub(crate) media: MediaIn,
    pub(crate) rx: mpsc::Receiver<Bytes>,
    /// The route's channel ended (its connection's reader stopped): only the stream from here.
    pub(crate) rx_done: bool,
    pub(crate) _route: Route,
}

impl MediaRx {
    /// Every datagram waiting taken in.
    pub(crate) fn take_waiting(&mut self, first: Option<Bytes>, now: Instant) {
        match first {
            Some(d) => self.media.datagram(&d, now),
            None => self.rx_done = true,
        }
        while let Ok(d) = self.rx.try_recv() {
            self.media.datagram(&d, now);
        }
        // (the loss its frames had said back to the sending end, which makes its parity for it)
        if let Some(report) = self.media.take_report(now) {
            if self._route.demux.conn.send_datagram(Bytes::copy_from_slice(&report)).is_ok() {
                crate::tally("dgram.loss.told");
            }
        }
    }

    /// The next datagram (pending forever once the route ended).
    pub(crate) async fn next(&mut self) -> Option<Bytes> {
        if self.rx_done {
            return std::future::pending().await;
        }
        self.rx.recv().await
    }
}

/// Tracks client -> station binary frame boundaries so datagram ACKs are only injected between frames, never inside one.
#[derive(Default)]
pub(crate) struct AckFraming {
    head: [u8; 5],
    head_have: usize,
    rem: usize,
    out_of_step: bool,
}

impl AckFraming {
    pub(crate) fn at_boundary(&self) -> bool {
        !self.out_of_step && self.rem == 0 && self.head_have == 0
    }

    /// Advances over `chunk` and returns the last offset in `chunk` that lies between two frames (if any).
    pub(crate) fn stream(&mut self, chunk: &[u8]) -> Option<usize> {
        if self.out_of_step {
            return None;
        }
        let mut at = 0;
        let mut boundary = self.at_boundary().then_some(0);
        while at < chunk.len() {
            if self.rem > 0 {
                let take = self.rem.min(chunk.len() - at);
                at += take;
                self.rem -= take;
                if self.rem == 0 {
                    boundary = Some(at);
                }
                continue;
            }
            self.head[self.head_have] = chunk[at];
            self.head_have += 1;
            at += 1;
            if self.head_have == 5 {
                self.head_have = 0;
                let len = u32::from_be_bytes([self.head[1], self.head[2], self.head[3], self.head[4]]) as usize;
                if len > FRAME_MAX {
                    self.out_of_step = true;
                    return None;
                }
                self.rem = len;
                if len == 0 {
                    boundary = Some(at);
                }
            }
        }
        boundary
    }
}

struct AckRoute {
    demux: Arc<Demux>,
    token: u32,
    tx: mpsc::Sender<(u64, u32)>,
}

impl Drop for AckRoute {
    fn drop(&mut self) {
        let mut acks = self.demux.acks.lock().unwrap();
        if acks.get(&self.token).is_some_and(|tx| tx.same_channel(&self.tx)) {
            acks.remove(&self.token);
        }
    }
}

/// Station-side receiver for unreliable `KIND_ACK` datagrams of a view, injecting standard 17-byte `KIND.ack` frames
/// into the stream's read half at frame boundaries.
pub(crate) struct AckRx {
    framing: AckFraming,
    rx: mpsc::Receiver<(u64, u32)>,
    rx_done: bool,
    ready: VecDeque<(u64, u32)>,
    _route: AckRoute,
}

impl AckRx {
    pub(crate) fn at_boundary(&self) -> bool {
        self.framing.at_boundary()
    }

    pub(crate) fn stream(&mut self, chunk: &[u8]) -> Option<usize> {
        self.framing.stream(chunk)
    }

    pub(crate) fn take_waiting(&mut self, first: Option<(u64, u32)>) {
        match first {
            Some(a) => self.ready.push_back(a),
            None => self.rx_done = true,
        }
        while let Ok(a) = self.rx.try_recv() {
            self.ready.push_back(a);
        }
    }

    pub(crate) fn drain_into(&mut self, out: &mut Vec<u8>) {
        while let Some((ts, wait_us)) = self.ready.pop_front() {
            out.extend_from_slice(&ack_frame_bytes(ts, wait_us));
        }
    }

    pub(crate) async fn next(&mut self) -> Option<(u64, u32)> {
        if self.rx_done {
            return std::future::pending().await;
        }
        self.rx.recv().await
    }
}

/// Registers datagram ACK reception for `token` on `conn` (sharing the connection's `Demux`). None outside a tokio runtime.
pub(crate) fn hear_acks(conn: &Connection, token: u32) -> Option<AckRx> {
    if token == 0 {
        return None;
    }
    tokio::runtime::Handle::try_current().ok()?;
    let demux = demux_of(None, conn);
    let (tx, rx) = mpsc::channel(ACK_QUEUE);
    demux.acks.lock().unwrap().insert(token, tx.clone());
    Some(AckRx { framing: AckFraming::default(), rx, rx_done: false, ready: VecDeque::new(), _route: AckRoute { demux, token, tx } })
}

/// Until `at` (forever where it is none: `MediaIn::deadline`).
pub(crate) async fn until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video_body(key: bool, ts: u64, len: usize, fill: u8) -> Vec<u8> {
        let mut b = vec![key as u8];
        b.extend(ts.to_be_bytes());
        b.extend((0..len).map(|i| (i as u8).wrapping_mul(31).wrapping_add(fill)));
        b
    }

    fn config(n: u8) -> Vec<u8> {
        frame_bytes(FRAME_CONFIG, format!(r#"{{"codec":"h264","width":{n}}}"#).as_bytes())
    }

    fn stream_of(media: &mut MediaIn, bytes: &[u8]) -> Vec<u8> {
        stream_at(media, bytes, Instant::now())
    }

    fn stream_at(media: &mut MediaIn, bytes: &[u8], now: Instant) -> Vec<u8> {
        // what a read gives: the stream's bytes with the frames ready put at its last boundary
        let mut out = Vec::new();
        match media.stream(bytes, now) {
            Some(b) => {
                out.extend_from_slice(&bytes[..b]);
                media.drain_into(&mut out);
                out.extend_from_slice(&bytes[b..]);
            }
            None => out.extend_from_slice(bytes),
        }
        out
    }

    fn given(media: &mut MediaIn) -> Vec<(u8, Vec<u8>)> {
        media.ready.drain(..).collect()
    }

    #[test]
    fn reed_solomon_makes_a_block_again_from_any_k_of_its_shards() {
        let mut seed = 7u32;
        let mut rand = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        for (k, m) in [(1, 1), (2, 1), (5, 3), (16, 4), (48, 24), (48, 1), (3, 0)] {
            let data: Vec<Vec<u8>> = (0..k).map(|_| (0..97).map(|_| rand() as u8).collect()).collect();
            let parity = rs_encode(&data, m);
            let all: Vec<Vec<u8>> = data.iter().chain(parity.iter()).cloned().collect();
            for _ in 0..40 {
                // drop m of them, at random
                let mut shards: Vec<Option<Vec<u8>>> = all.iter().cloned().map(Some).collect();
                let mut dropped = 0;
                while dropped < m {
                    let i = rand() as usize % (k + m);
                    if shards[i].is_some() {
                        shards[i] = None;
                        dropped += 1;
                    }
                }
                assert_eq!(rs_decode(k, &shards, 97).as_ref(), Some(&data), "k {k} m {m}");
                // one more lost: not to be had
                if let Some(i) = (0..k + m).find(|&i| shards[i].is_some()) {
                    shards[i] = None;
                    assert_eq!(rs_decode(k, &shards, 97), None);
                }
            }
        }
    }

    #[test]
    fn the_parity_grows_with_the_loss() {
        assert_eq!(parity_for(1, false, 0.0), 0);
        assert_eq!(parity_for(1, true, 0.0), 1);
        assert_eq!(parity_for(1, false, 0.001), 1);
        // a clean link: a tenth (a key frame 15%, two at least), however few lost lately
        assert_eq!(parity_for(2, false, 0.0), 1);
        assert_eq!(parity_for(10, false, 0.0), 1);
        assert_eq!(parity_for(11, false, 0.0), 2);
        assert_eq!(parity_for(20, false, 0.0), 2);
        assert_eq!(parity_for(30, false, 0.0), 3);
        assert_eq!(parity_for(40, false, 0.0), 4);
        assert_eq!(parity_for(48, false, 0.004), 5);
        assert_eq!(parity_for(2, true, 0.0), 2);
        assert_eq!(parity_for(42, true, 0.0), 7);
        assert_eq!(parity_for(48, true, 0.0), 8);
        assert_eq!(parity_for(20, false, 0.01), 4); // 20 * 0.17
        assert_eq!(parity_for(20, false, 0.02), 4); // 20 * 0.20
        assert_eq!(parity_for(20, false, 0.05), 6); // 20 * 0.29
        assert_eq!(parity_for(17, false, 0.063), 6); // 17 * 0.329: three bursts of two
        // bursts: four at least from 2%, six from 4% in a block of 12 or more
        assert_eq!(parity_for(5, false, 0.02), 4);
        assert_eq!(parity_for(3, false, 0.02), 1);
        assert_eq!(parity_for(10, false, 0.019), 2);
        assert_eq!(parity_for(12, false, 0.04), 6);
        assert_eq!(parity_for(11, false, 0.04), 4);
        assert_eq!(parity_for(2, true, 0.01), 2);
        assert_eq!(parity_for(48, false, 0.5), 21); // 48 * 0.42
        assert_eq!(parity_for(48, true, 0.006), 8); // never below the clean link's
        assert_eq!(parity_for(48, true, 0.01), 9); // 48 * 0.17
        assert_eq!(parity_for(48, true, 0.5), 21);
        let mut meter = LossMeter::default();
        let t0 = Instant::now();
        assert_eq!(meter.update(t0, 0, 0), 0.0);
        assert_eq!(meter.update(t0 + Duration::from_millis(250), 5, 100), 0.05);
        // (read again only once LOSS_EVERY has gone)
        assert_eq!(meter.update(t0 + Duration::from_millis(300), 100, 100), 0.05);
        assert_eq!(meter.update(t0 + Duration::from_millis(500), 100, 200), 0.95);
        assert_eq!(meter.update(t0 + Duration::from_millis(750), 100, 300), 0.0);
    }

    /// A sequence of frames as datagrams (`loss` 0: one parity shard).
    fn send(token: u32, frames: &[(u8, bool, Vec<u8>)], epoch: u8, loss: f64) -> Vec<Vec<Vec<u8>>> {
        let (mut vs, mut aus) = (0u32, 0u32);
        let mut prev: Option<Vec<u8>> = None;
        frames
            .iter()
            .map(|(kind, key, body)| {
                let seq = if *kind == FRAME_VIDEO {
                    vs += 1;
                    vs
                } else {
                    aus += 1;
                    aus
                };
                let d = datagrams_of(token, *kind, *key, epoch, seq, body, if *kind == FRAME_AUDIO { prev.as_deref() } else { None }, 1200, loss).unwrap();
                if *kind == FRAME_AUDIO {
                    prev = Some(body.clone());
                }
                d
            })
            .collect()
    }

    #[test]
    fn frames_come_whole_whatever_shards_of_them_were_lost_within_their_parity() {
        let t = Instant::now();
        let mut media = MediaIn::new(9, false);
        assert_eq!(stream_of(&mut media, &config(1)), config(1));
        let bodies: Vec<Vec<u8>> = (0..5).map(|i| video_body(i == 0, i as u64, [70_000, 3_000, 900, 120_000, 5][i], i as u8)).collect();
        let frames: Vec<(u8, bool, Vec<u8>)> = bodies.iter().enumerate().map(|(i, b)| (FRAME_VIDEO, i == 0, b.clone())).collect();
        let sent = send(9, &frames, 1, 0.05);
        for dgrams in &sent {
            // each block loses as many as its parity: the first of each
            let mut lost_in: HashMap<u8, usize> = HashMap::new();
            for d in dgrams {
                let h = Head::of(d).unwrap();
                let lost = lost_in.entry(h.block).or_default();
                if *lost < h.m as usize && h.shard % 2 == 0 {
                    *lost += 1;
                    continue;
                }
                media.datagram(d, t);
            }
        }
        let got = given(&mut media);
        assert_eq!(got, bodies.iter().map(|b| (FRAME_VIDEO, b.clone())).collect::<Vec<_>>());
        assert_eq!(media.counts.given_up, 0);
        assert!(!media.take_keyframe(t));
    }

    #[test]
    fn other_datagrams_on_the_connection_are_passed_over() {
        let t = Instant::now();
        let mut media = MediaIn::new(9, false);
        stream_of(&mut media, &config(1));
        // conn.answers' probe, another view's, one cut short, one that says nonsense
        media.datagram(&[0], t);
        let other = send(10, &[(FRAME_VIDEO, true, video_body(true, 1, 10, 0))], 1, 0.0);
        for d in &other[0] {
            media.datagram(d, t);
        }
        let mine = send(9, &[(FRAME_VIDEO, true, video_body(true, 1, 10, 0))], 1, 0.0);
        media.datagram(&mine[0][0][..HEADER_LEN], t);
        let mut bad = mine[0][0].clone();
        bad[13] = 0;
        media.datagram(&bad, t);
        assert!(media.ready.is_empty());
        assert!(Head::of(&[0]).is_none());
        media.datagram(&mine[0][0], t);
        assert_eq!(given(&mut media).len(), 1);
    }

    #[test]
    fn a_frame_of_a_config_still_coming_waits_for_it() {
        let t = Instant::now();
        let mut media = MediaIn::new(3, true);
        let line = b"{\"status\":200}\n";
        let key = video_body(true, 1, 2000, 1);
        let p = video_body(false, 2, 100, 2);
        // the key frame of the first config comes before the config (its stream retransmitted)
        for d in send(3, &[(FRAME_VIDEO, true, key.clone()), (FRAME_VIDEO, false, p.clone())], 1, 0.0).iter().flatten() {
            media.datagram(d, t);
        }
        assert!(media.ready.is_empty(), "held for the config");
        // the stream: the reply's line, then the config cut in two
        let mut wire = line.to_vec();
        wire.extend(config(1));
        assert_eq!(stream_of(&mut media, &wire[..wire.len() - 3]), wire[..wire.len() - 3].to_vec());
        let out = stream_of(&mut media, &wire[wire.len() - 3..]);
        let mut want = wire[wire.len() - 3..].to_vec();
        want.extend(frame_bytes(FRAME_VIDEO, &key));
        want.extend(frame_bytes(FRAME_VIDEO, &p));
        assert_eq!(out, want, "given right after the config");
        assert_eq!(media.deadline(), None, "a frame received ahead of its config needs no retry");
        // a frame of the config before, late: dropped
        let old = datagrams_of(3, FRAME_VIDEO, false, 0, 3, &video_body(false, 3, 10, 3), None, 1200, 0.0).unwrap();
        media.datagram(&old[0], t);
        assert!(media.ready.is_empty());
    }

    #[test]
    fn frames_are_put_between_the_streams_frames_never_inside_one() {
        let t = Instant::now();
        let mut media = MediaIn::new(3, false);
        stream_of(&mut media, &config(1));
        let state = frame_bytes(3, br#"{"title":"a long state"}"#);
        // half a state came
        assert_eq!(stream_of(&mut media, &state[..7]), state[..7].to_vec());
        assert!(!media.at_boundary());
        let key = video_body(true, 1, 10, 1);
        for d in send(3, &[(FRAME_VIDEO, true, key.clone())], 1, 0.0).iter().flatten() {
            media.datagram(d, t);
        }
        assert_eq!(media.ready.len(), 1, "ready, not given inside the state");
        // the rest of it and the start of another: given between the two
        let mut rest = state[7..].to_vec();
        rest.extend(&state[..2]);
        let out = stream_of(&mut media, &rest);
        let mut want = state[7..].to_vec();
        want.extend(frame_bytes(FRAME_VIDEO, &key));
        want.extend(&state[..2]);
        assert_eq!(out, want);
    }

    #[test]
    fn a_frame_lost_past_its_parity_is_never_given_and_a_key_frame_is_asked_for() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..6).map(|i| (FRAME_VIDEO, i == 0 || i == 5, video_body(i == 0 || i == 5, i, 3000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        let take = |media: &mut MediaIn, i: usize, at: Instant| sent[i].iter().for_each(|d| media.datagram(d, at));
        take(&mut media, 0, t);
        take(&mut media, 1, t);
        // frame 3 (seq 3) loses two shards with one parity
        for d in sent[2].iter().skip(2) {
            media.datagram(d, t);
        }
        // 4 comes whole: waited GAP_WAIT_MIN (12 ms) for 3
        take(&mut media, 3, t + Duration::from_millis(1));
        assert_eq!(given(&mut media).len(), 2);
        assert_eq!(media.deadline(), Some(t + Duration::from_millis(1) + GAP_WAIT_MIN));
        media.tick(t + Duration::from_millis(1) + GAP_WAIT_MIN);
        assert_eq!(media.counts.given_up, 1);
        assert!(media.take_keyframe(t + Duration::from_millis(1) + GAP_WAIT_MIN));
        // (asked once in KEYFRAME_EVERY)
        take(&mut media, 4, t + Duration::from_millis(20));
        assert!(!media.take_keyframe(t + Duration::from_millis(20)));
        assert!(media.ready.is_empty(), "nothing given that lost its reference");
        // the key frame: given at once, and on from it
        take(&mut media, 5, t + Duration::from_millis(30));
        assert_eq!(given(&mut media), vec![(FRAME_VIDEO, frames[5].2.clone())]);
        assert!(!media.video.broken);
    }

    #[test]
    fn a_key_frame_lost_itself_on_a_still_screen_is_asked_for_again() {
        let t = Instant::now();
        let ms = |n: u64| t + Duration::from_millis(n);
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..5).map(|i| (FRAME_VIDEO, i == 0 || i >= 3, video_body(i == 0 || i >= 3, i, 3000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        // 2 loses two shards with one parity, 3 comes whole: 2 given up GAP_WAIT_MIN on, a key frame asked for
        sent[1].iter().skip(2).for_each(|d| media.datagram(d, t));
        sent[2].iter().for_each(|d| media.datagram(d, t));
        media.tick(ms(15));
        assert_eq!(media.counts.given_up, 1);
        assert!(media.take_keyframe(ms(15)));
        // the key frame sent for it loses past its two parity shards too, and then the screen is still: nothing more comes
        for d in sent[3].iter().skip(3) {
            media.datagram(d, ms(25));
        }
        assert!(!media.take_keyframe(ms(25)));
        assert_eq!(media.deadline(), Some(ms(515)), "asked again KEYFRAME_RETRY after");
        media.tick(ms(400));
        assert!(!media.take_keyframe(ms(400)));
        media.tick(ms(515));
        assert_eq!(media.deadline(), None, "nothing waited for until it is asked");
        assert!(media.take_keyframe(ms(515)));
        assert_eq!(media.deadline(), Some(ms(1015)));
        // the next key frame comes whole: given, and nothing more to wait for
        sent[4].iter().for_each(|d| media.datagram(d, ms(530)));
        assert_eq!(given(&mut media).into_iter().map(|g| g.1).collect::<Vec<_>>(), vec![frames[0].2.clone(), frames[4].2.clone()]);
        assert_eq!(media.deadline(), None);
        assert!(!media.take_keyframe(ms(530)));
    }

    #[test]
    fn another_loss_soon_after_recovery_waits_for_the_next_keyframe_slot() {
        let t = Instant::now();
        let ms = |n: u64| t + Duration::from_millis(n);
        let mut media = MediaIn::new(5, false);
        stream_at(&mut media, &config(1), t);
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..7).map(|i| (FRAME_VIDEO, i == 0 || i == 3 || i == 6, video_body(i == 0 || i == 3 || i == 6, i, 3000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        sent[1].iter().skip(2).for_each(|d| media.datagram(d, t));
        sent[2].iter().for_each(|d| media.datagram(d, t));
        media.tick(ms(12));
        assert!(media.take_keyframe(ms(12)));
        sent[3].iter().for_each(|d| media.datagram(d, ms(30)));
        assert!(!media.video.broken);
        sent[4].iter().skip(2).for_each(|d| media.datagram(d, ms(40)));
        sent[5].iter().for_each(|d| media.datagram(d, ms(40)));
        media.tick(ms(52));
        assert!(!media.take_keyframe(ms(52)), "the next request is rate-limited");
        assert_eq!(media.deadline(), Some(ms(312)), "wake when the limit expires even if no more frames arrive");
        media.tick(ms(312));
        assert!(media.take_keyframe(ms(312)));
        sent[6].iter().for_each(|d| media.datagram(d, ms(330)));
        assert!(!media.video.broken);
        assert_eq!(media.deadline(), None);
    }

    #[test]
    fn the_first_frame_lost_entirely_on_a_still_screen_is_asked_for_again() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_at(&mut media, &config(1), t);
        // No shard of the first frame came. A still screen sends nothing else to reveal the loss.
        assert_eq!(media.deadline(), Some(t + FIRST_FRAME_WAIT));
        media.tick(t + FIRST_FRAME_WAIT - Duration::from_millis(1));
        assert!(!media.take_keyframe(t + FIRST_FRAME_WAIT - Duration::from_millis(1)));
        media.tick(t + FIRST_FRAME_WAIT);
        assert!(media.take_keyframe(t + FIRST_FRAME_WAIT));
        assert_eq!(media.deadline(), Some(t + FIRST_FRAME_WAIT + KEYFRAME_RETRY));
        // Chrome repeats the config with its requested key frame, which follows the missing sequence 1.
        stream_at(&mut media, &config(2), t + FIRST_FRAME_WAIT + Duration::from_millis(10));
        let body = video_body(true, 2, 100, 2);
        let recovery = datagrams_of(5, FRAME_VIDEO, true, 2, 2, &body, None, 1200, 0.0).unwrap();
        for d in recovery {
            media.datagram(&d, t + FIRST_FRAME_WAIT + Duration::from_millis(20));
        }
        assert_eq!(given(&mut media), vec![(FRAME_VIDEO, body)]);
        assert_eq!(media.deadline(), None);
        assert!(!media.take_keyframe(t + FIRST_FRAME_WAIT + Duration::from_millis(20)));
    }

    #[test]
    fn a_frame_on_the_reliable_stream_cancels_the_first_frame_deadline() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_at(&mut media, &config(1), t);
        assert_eq!(media.deadline(), Some(t + FIRST_FRAME_WAIT));
        let video = frame_bytes(FRAME_VIDEO, &video_body(true, 1, 10, 1));
        stream_at(&mut media, &video[..5], t);
        assert_eq!(media.deadline(), None);
        media.tick(t + FIRST_FRAME_WAIT);
        assert!(!media.take_keyframe(t + FIRST_FRAME_WAIT));
        stream_at(&mut media, &video[5..], t + FIRST_FRAME_WAIT);
    }

    #[test]
    fn a_key_frame_whole_is_given_at_once_over_what_is_missing_before_it() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..4).map(|i| (FRAME_VIDEO, i == 0 || i == 2, video_body(i == 0 || i == 2, i, 500, 0))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        // 2 never comes; the key frame 3 does, and 4 after it
        sent[2].iter().for_each(|d| media.datagram(d, t));
        sent[3].iter().for_each(|d| media.datagram(d, t));
        assert_eq!(given(&mut media).into_iter().map(|g| g.1).collect::<Vec<_>>(), vec![frames[0].2.clone(), frames[2].2.clone(), frames[3].2.clone()]);
        assert_eq!(media.counts.given_up, 0);
    }

    #[test]
    fn two_frames_on_whole_before_the_one_waited_on_give_it_up_at_once() {
        let t = Instant::now();
        let mut media = MediaIn::new(5, false);
        stream_of(&mut media, &config(1));
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..4).map(|i| (FRAME_VIDEO, i == 0, video_body(i == 0, i, 500, 0))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        sent[2].iter().for_each(|d| media.datagram(d, t));
        sent[3].iter().for_each(|d| media.datagram(d, t));
        assert_eq!(media.counts.given_up, 1);
        assert_eq!(given(&mut media).len(), 1);
        assert!(media.take_keyframe(t));
    }

    #[test]
    fn opus_carries_the_packet_before_it_so_one_lost_is_had_with_the_next() {
        let t = Instant::now();
        let mut media = MediaIn::new(4, false);
        let ac = frame_bytes(FRAME_AUDIO_CONFIG, br#"{"codec":"opus","sampleRate":48000,"channels":2}"#);
        stream_of(&mut media, &ac);
        let packets: Vec<(u8, bool, Vec<u8>)> = (0..5u64).map(|i| {
            let mut b = (i * 20_000).to_be_bytes().to_vec();
            b.extend(vec![i as u8; 160]);
            (FRAME_AUDIO, false, b)
        }).collect();
        let sent = send(4, &packets, 1, 0.0);
        assert!(sent.iter().all(|d| d.len() == 1), "one datagram each");
        for (i, d) in sent.iter().enumerate() {
            if i == 2 {
                continue;
            }
            media.datagram(&d[0], t);
        }
        assert_eq!(given(&mut media).into_iter().map(|g| g.1).collect::<Vec<_>>(), packets.iter().map(|p| p.2.clone()).collect::<Vec<_>>());
        assert_eq!(media.counts.red, 1);
        // PCM's packets: cut in four with a parity shard
        let mut pcm = 9u64.to_be_bytes().to_vec();
        pcm.extend(vec![7u8; 3840]);
        let d = datagrams_of(4, FRAME_AUDIO, false, 1, 6, &pcm, None, 1200, 0.0).unwrap();
        assert_eq!(d.len(), 5);
        for x in d.iter().skip(1) {
            media.datagram(x, t);
        }
        assert_eq!(given(&mut media), vec![(FRAME_AUDIO, pcm)]);
    }

    #[test]
    fn the_receiving_end_says_the_shards_lost_never_the_parity_it_did_not_need() {
        let t = Instant::now();
        let ms = |n: u64| t + Duration::from_millis(n);
        let mut media = MediaIn::new(6, false);
        stream_of(&mut media, &config(1));
        // 40 frames of 10 shards, one parity shard each
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..40).map(|i| (FRAME_VIDEO, i == 0, video_body(i == 0, i, 11_000, i as u8))).collect();
        let sent = send(6, &frames, 1, 0.0);
        assert!(sent[1..].iter().all(|d| d.len() == 11 && Head::of(&d[0]).unwrap().k == 10));
        // the first 20 whole: had at their 10th data shard, the parity after it not counted lost
        for (i, d) in sent[..20].iter().enumerate() {
            d.iter().for_each(|x| media.datagram(x, ms(i as u64 * 16)));
        }
        assert_eq!(media.take_report(ms(320)), None, "counting from the first asked");
        assert_eq!((media.loss.missing, media.loss.shards), (0, 20 * 10));
        assert_eq!(media.take_report(ms(400)), None, "not yet REPORT_EVERY");
        let report = media.take_report(ms(570)).unwrap();
        assert_eq!(report_of(&report), Some((6, 0)));
        // the next 20 lose their 4th shard each, made again from the parity: one lost of each 11
        for (i, d) in sent[20..].iter().enumerate() {
            d.iter().enumerate().filter(|(j, _)| *j != 3).for_each(|(_, x)| media.datagram(x, ms(600 + i as u64 * 16)));
        }
        assert_eq!(given(&mut media).len(), 40);
        assert_eq!(media.take_report(ms(800)), None);
        let report = media.take_report(ms(1000)).unwrap();
        assert_eq!(report_of(&report), Some((6, 20 * 1_000_000 / 220)));
        assert_eq!(u32::from_be_bytes(report[10..14].try_into().unwrap()), 220);
        // a frame let go, lost past its parity long enough: all its shards that did not come
        let more = send(6, &[(FRAME_VIDEO, false, video_body(false, 41, 11_000, 0))], 1, 0.0);
        let mut seq41 = more[0].clone();
        for d in &mut seq41 {
            d[7..11].copy_from_slice(&41u32.to_be_bytes());
        }
        seq41[..5].iter().for_each(|x| media.datagram(x, ms(1100)));
        media.tick(ms(1100 + STALE.as_millis() as u64));
        assert_eq!(media.counts.given_up, 1);
        assert_eq!((media.loss.missing, media.loss.shards), (6, 11));
    }

    #[test]
    fn a_report_is_passed_over_by_an_end_from_before_and_heard_by_its_view() {
        let r = report_bytes(9, 31_250, 640);
        assert_eq!(r.len(), REPORT_LEN);
        assert_eq!(report_of(&r), Some((9, 31_250)));
        // no head of a frame: an end from before (Head::of) passes it over, and so does the view's receiving end
        assert!(Head::of(&r).is_none());
        let t = Instant::now();
        let mut media = MediaIn::new(9, false);
        stream_of(&mut media, &config(1));
        media.datagram(&r, t);
        assert!(media.ready.is_empty() && media.video.pending.is_empty());
        assert_eq!(report_of(&report_bytes(0, 1, 1)), None);
        assert_eq!(report_of(&report_bytes(9, 1_000_001, 1)), None);
        assert_eq!(report_of(&r[..15]), None);
        let heard = PeerLoss::default();
        assert_eq!(heard.at(t), 0.0);
        heard.heard(31_250, t);
        assert_eq!(heard.at(t + Duration::from_millis(1999)), 0.03125);
        assert_eq!(heard.at(t + REPORT_FRESH), 0.0, "stale once the receiving end stopped saying");
        // what the sending end makes of it: the parity for 3%, not the clean link's
        assert_eq!(parity_for(40, false, heard.at(t)), 10);
    }

    #[test]
    fn a_kind_the_stream_carries_again_is_no_longer_taken_as_datagrams() {
        let t = Instant::now();
        let mut media = MediaIn::new(4, false);
        stream_of(&mut media, &config(1));
        let sent = send(4, &[(FRAME_VIDEO, true, video_body(true, 1, 5000, 1))], 1, 0.0);
        media.datagram(&sent[0][0], t);
        let on_stream = frame_bytes(FRAME_VIDEO, &video_body(false, 2, 4, 0));
        assert_eq!(stream_of(&mut media, &on_stream), on_stream);
        for d in &sent[0] {
            media.datagram(d, t);
        }
        assert!(media.ready.is_empty());
    }

    #[test]
    fn ack_datagram_roundtrip_and_backward_compatibility() {
        let a = ack_bytes(19, 1_234_567_890, 4_321);
        assert_eq!(a.len(), ACK_LEN);
        assert_eq!(ack_of(&a), Some((19, 1_234_567_890, 4_321)));
        // Older receivers ignore KIND_ACK (Head::of rejects kind == 5, report_of rejects len/kind).
        assert!(Head::of(&a).is_none());
        assert!(report_of(&a).is_none());
        assert_eq!(ack_of(&ack_bytes(0, 1, 0)), None);
        assert_eq!(ack_of(&a[..ACK_LEN - 1]), None);

        // Stream wire format for injected KIND.ack.
        let f = ack_frame_bytes(1_234_567_890, 4_321);
        assert_eq!(f.len(), 17);
        assert_eq!(f[0], FRAME_ACK);
        assert_eq!(u32::from_be_bytes(f[1..5].try_into().unwrap()), 12);
        assert_eq!(u64::from_be_bytes(f[5..13].try_into().unwrap()), 1_234_567_890);
        assert_eq!(u32::from_be_bytes(f[13..17].try_into().unwrap()), 4_321);

        // FLAG_ACK bit 5 is set on outgoing media datagrams and parsed by Head::of without breaking kind/key/red.
        let sent = send(7, &[(FRAME_VIDEO, true, video_body(true, 1, 100, 1))], 1, 0.0);
        let h = Head::of(&sent[0][0]).unwrap();
        assert!(h.ack_cap);
        assert!(h.key);
        assert_eq!(h.kind, FRAME_VIDEO);
        // Clearing FLAG_ACK (old station) still parses cleanly with ack_cap = false.
        let mut old_dgram = sent[0][0].clone();
        old_dgram[1] &= !FLAG_ACK;
        let h_old = Head::of(&old_dgram).unwrap();
        assert!(!h_old.ack_cap);
        assert!(h_old.key);
    }

    #[test]
    fn micro_pacing_zero_delay_for_small_and_smooth_for_large_frames() {
        let start = Instant::now();
        // Small frames (<= 8 shards): zero pacing deadlines.
        for total in 1..=PACE_SMALL {
            for i in 0..total {
                assert_eq!(pace_deadline(start, i, total, false), None);
                assert_eq!(pace_deadline(start, i, total, true), None);
            }
        }
        // Medium P-frame (36 shards): budget = 36 * 75us = 2.7ms, 6 batches of 6 -> 5 even intervals.
        let p_deadlines: Vec<Duration> = (0..36).filter_map(|i| pace_deadline(start, i, 36, false).map(|d| d - start)).collect();
        assert_eq!(p_deadlines.len(), 5);
        assert_eq!(*p_deadlines.last().unwrap(), Duration::from_micros(36 * PACE_US_PER_SHARD));
        assert!(*p_deadlines.last().unwrap() <= PACE_MOST);
        // Large P-frame (120 shards): capped at PACE_MOST (6 ms).
        let big_p: Vec<Duration> = (0..120).filter_map(|i| pace_deadline(start, i, 120, false).map(|d| d - start)).collect();
        assert_eq!(*big_p.last().unwrap(), PACE_MOST);
        // Keyframe (140 shards): capped at PACE_MOST_KEY (10 ms), micro-batched every PACE_BATCH (6) shards.
        let key_deadlines: Vec<Duration> = (0..140).filter_map(|i| pace_deadline(start, i, 140, true).map(|d| d - start)).collect();
        assert_eq!(key_deadlines.len(), 140usize.div_ceil(PACE_BATCH) - 1);
        assert_eq!(*key_deadlines.last().unwrap(), PACE_MOST_KEY);
        // Monotonic and evenly spaced (~0.43 ms per 6-shard batch vs old 64-shard burst!).
        for w in key_deadlines.windows(2) {
            let gap = w[1] - w[0];
            assert!(gap >= Duration::from_micros(350) && gap <= Duration::from_micros(550), "gap {gap:?}");
        }
    }

    #[test]
    fn active_next_frame_tolerates_up_to_four_frames_ahead_and_adapts_gap_wait() {
        let t = Instant::now();
        let ms = |n: u64| t + Duration::from_millis(n);
        let mut media = MediaIn::new(5, false);
        stream_at(&mut media, &config(1), t);
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..8).map(|i| (FRAME_VIDEO, i == 0, video_body(i == 0, i, 6_000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        // Frame 1 (key) arrives cleanly.
        sent[0].iter().for_each(|d| media.datagram(d, t));
        assert_eq!(given(&mut media).len(), 1);
        assert_eq!(media.gap_wait(), GAP_WAIT_MIN);

        // Frame 2 (next) receives its first shard at t=0, while frames 3 and 4 (next+1, next+2) finish at t=4ms.
        // Because frame 2 is actively receiving shards (`now - last_activity < gap_wait`) and s <= next+4, do NOT give_up!
        media.datagram(&sent[1][0], t);
        sent[2].iter().for_each(|d| media.datagram(d, ms(4)));
        sent[3].iter().for_each(|d| media.datagram(d, ms(4)));
        assert_eq!(media.counts.given_up, 0, "active next frame must not be killed by next+2");
        assert!(!media.video.broken);

        // Remaining shards of frame 2 arrive at t=10ms -> all 3 frames (2, 3, 4) delivered in order!
        for d in &sent[1][1..] {
            media.datagram(d, ms(10));
        }
        assert_eq!(media.counts.given_up, 0);
        assert_eq!(given(&mut media).len(), 3);
        // Observed 10ms span raised jitter EWMA; now feed frames with 24ms span and verify gap_wait adapts up to ~20-45ms.
        for idx in 4..8 {
            media.datagram(&sent[idx][0], ms(20 + idx as u64 * 30));
            for d in &sent[idx][1..] {
                media.datagram(d, ms(44 + idx as u64 * 30));
            }
        }
        assert!(media.gap_wait() > GAP_WAIT_MIN && media.gap_wait() <= GAP_WAIT_MAX, "adaptive gap_wait {:?}", media.gap_wait());
    }

    #[test]
    fn stale_tracks_last_activity_with_hard_cap() {
        let t = Instant::now();
        let ms = |n: u64| t + Duration::from_millis(n);
        let mut media = MediaIn::new(5, false);
        stream_at(&mut media, &config(1), t);
        let frames: Vec<(u8, bool, Vec<u8>)> = (0..2).map(|i| (FRAME_VIDEO, i == 0, video_body(i == 0, i, 20_000, i as u8))).collect();
        let sent = send(5, &frames, 1, 0.0);
        sent[0].iter().for_each(|d| media.datagram(d, t));
        let _ = given(&mut media);

        // Shard 0 arrives at t=0, shard 1 arrives at t=50ms -> last_activity resets STALE (80ms) past t=80ms,
        // but hard cap STALE_MAX (120ms from first) still gives up at t=120ms.
        media.datagram(&sent[1][0], ms(0));
        media.datagram(&sent[1][1], ms(50));
        media.tick(ms(85));
        assert_eq!(media.counts.given_up, 0, "activity at 50ms keeps frame alive past 80ms");
        assert_eq!(media.deadline(), Some(ms(120)), "capped at first + STALE_MAX");
        media.tick(ms(120));
        assert_eq!(media.counts.given_up, 1, "hard cap STALE_MAX prevents infinite stall");
    }

    /// Deterministic metro-network simulation comparing before (WINDOW=8, GAP_WAIT=3ms, STALE=40ms, immediate give_up at
    /// next+2, PACE_BURST=64) vs after (WINDOW=16, adaptive gap_wait 12..45ms, STALE=80/120ms, active next tolerance up
    /// to next+4, smooth 6-shard micro-pacing) under 20ms RTT, ±15ms shard reordering/jitter, 1.5% loss with 2-shard
    /// bursts, and mixed 120KB keyframes + 8KB P-frames.
    #[test]
    fn metro_network_simulation_before_and_after() {
        use std::cmp::Reverse;
        use std::collections::BinaryHeap;

        struct OldMediaIn {
            inner: MediaIn,
        }
        impl OldMediaIn {
            fn new(token: u32) -> Self {
                Self { inner: MediaIn::new(token, false) }
            }
            fn datagram(&mut self, d: &[u8], now: Instant) {
                let Some(h) = Head::of(d) else { return };
                if h.token != self.inner.token || h.kind != FRAME_VIDEO {
                    return;
                }
                self.inner.clock = Some(now);
                if self.inner.video.closed || h.seq <= self.inner.video.last {
                    return;
                }
                let whole = self.inner.video.pending.entry(h.seq).or_insert_with(|| Pending::new(&h, now)).take(&h, &d[HEADER_LEN..], now, &mut self.inner.loss);
                let mut lost_next = false;
                while self.inner.video.pending.len() > 8 {
                    let (oldest, p) = self.inner.video.pending.pop_first().unwrap();
                    self.inner.loss.let_go(&p, now);
                    lost_next |= oldest == self.inner.video.last.wrapping_add(1) && !self.inner.video.broken;
                }
                if lost_next {
                    self.inner.give_up();
                }
                if whole {
                    self.advance_old(now);
                    if self.inner.video.broken {
                        self.inner.want_keyframe = true;
                    }
                }
            }
            fn advance_old(&mut self, now: Instant) {
                loop {
                    let next = self.inner.video.last.wrapping_add(1);
                    if !self.inner.video.broken && self.inner.video.pending.get(&next).is_some_and(|p| p.whole.is_some()) {
                        let p = self.inner.video.pending.remove(&next).unwrap();
                        self.inner.give_video(next, p);
                        continue;
                    }
                    let key = self.inner.video.pending.iter().find(|(s, p)| p.key && p.whole.is_some() && **s > self.inner.video.last).map(|(s, _)| *s);
                    match key {
                        Some(s) => {
                            let p = self.inner.video.pending.remove(&s).unwrap();
                            retain_counted(&mut self.inner.video.pending, &mut self.inner.loss, now, |q, _| q > s);
                            self.inner.video.broken = false;
                            self.inner.want_keyframe = false;
                            self.inner.give_video(s, p);
                        }
                        None => break,
                    }
                }
                if self.inner.video.broken {
                    return;
                }
                let next = self.inner.video.last.wrapping_add(1);
                let after = self.inner.video.pending.iter().filter(|(s, p)| **s > next && p.whole.is_some()).map(|(s, p)| (*s, p.whole.as_ref().unwrap().1)).last();
                match after {
                    Some((s, _)) if s >= next.wrapping_add(2) => self.inner.give_up(),
                    Some((_, at)) => {
                        let from = *self.inner.wait_from.get_or_insert(at);
                        if now.saturating_duration_since(from) >= Duration::from_millis(3) {
                            self.inner.give_up();
                        }
                    }
                    None => {
                        self.inner.wait_from = None;
                        if self.inner.video.pending.get(&next).is_some_and(|p| now.saturating_duration_since(p.first) >= Duration::from_millis(40)) {
                            self.inner.give_up();
                        }
                    }
                }
            }
            fn deadline_old(&self) -> Option<Instant> {
                if self.inner.video.closed || self.inner.video.broken {
                    return None;
                }
                let wait = self.inner.wait_from.map(|w| w + Duration::from_millis(3));
                let stale = self.inner.video.pending.get(&self.inner.video.last.wrapping_add(1)).filter(|p| p.whole.is_none()).map(|p| p.first + Duration::from_millis(40));
                [wait, stale].into_iter().flatten().min()
            }
            fn tick_old(&mut self, now: Instant) {
                self.inner.clock = Some(now);
                if !self.inner.video.broken {
                    self.advance_old(now);
                }
            }
        }

        // Measure pacing burst distribution on a 120KB keyframe (~126 shards with parity).
        let t0 = Instant::now();
        let key_dgrams = datagrams_of(1, FRAME_VIDEO, true, 1, 1, &video_body(true, 1, 120_000, 1), None, 1200, 0.015).unwrap();
        let n_key = key_dgrams.len();
        // Old pacing: 64 shards at t=0, 64 shards at t=500us, remaining at t=1000us (max burst = 128 in 1ms).
        let mut old_buckets = BTreeMap::<u64, usize>::new();
        let mut new_buckets = BTreeMap::<u64, usize>::new();
        for i in 0..n_key {
            let old_ms = ((i / 64) as u64 * 500).min(4000) / 1000;
            *old_buckets.entry(old_ms).or_default() += 1;
            let batch_start = (i / PACE_BATCH) * PACE_BATCH;
            let new_ms = pace_deadline(t0, batch_start, n_key, true).map_or(0, |d| (d - t0).as_millis() as u64);
            *new_buckets.entry(new_ms).or_default() += 1;
        }
        let old_max_per_ms = *old_buckets.values().max().unwrap();
        let new_max_per_ms = *new_buckets.values().max().unwrap();
        assert!(old_max_per_ms >= 64 && new_max_per_ms <= 24, "old_max_per_ms={old_max_per_ms} new_max_per_ms={new_max_per_ms}");

        // Simulate 120 frames at 60fps (16.67ms/frame) over a metro link:
        // - 20ms base RTT (10ms one-way)
        // - Per-shard jitter: 0..4ms baseline + 15% of shards hit by 15..22ms metro/Wi-Fi jitter spike (reordering across
        //   adjacent frames, especially when a 120KB keyframe overlaps following 8KB P-frames)
        // - 1.5% packet loss (mix of single drops and 2-shard bursts)
        // Tested both without egress queue drops (isolating receiver anti-jitter) and with a 48-pkt/ms shallow queue
        // (evaluating combined sender micro-pacing + receiver anti-jitter).
        const FRAMES: u32 = 120;
        let run_sim = |use_new: bool, queue_cap_per_ms: Option<usize>| -> (u64, u64, u64) {
            let mut seed = 0x5EED_CAFE_BABE_1234u64;
            let mut next_u64 = || {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                seed
            };
            let mut events: BinaryHeap<Reverse<(u64, usize, Vec<u8>)>> = BinaryHeap::new();
            let mut ev_id = 0usize;
            let mut burst_drop = 0usize;
            let mut egress_ms_counts: HashMap<u64, usize> = HashMap::new();
            for f in 0..FRAMES {
                let seq = f + 1;
                let key = f % 30 == 0;
                let size = if key { 120_000 } else { 8_000 };
                let body = video_body(key, f as u64 * 16_667, size, f as u8);
                let dgrams = datagrams_of(7, FRAME_VIDEO, key, 1, seq, &body, None, 1200, 0.015).unwrap();
                let frame_start_us = f as u64 * 16_667;
                let total = dgrams.len();
                for (i, d) in dgrams.into_iter().enumerate() {
                    let pace_us = if use_new {
                        let batch_start = (i / PACE_BATCH) * PACE_BATCH;
                        pace_deadline(t0, batch_start, total, key).map_or(0, |dl| (dl - t0).as_micros() as u64)
                    } else {
                        ((i / 64) as u64 * 500).min(4000)
                    };
                    let send_us = frame_start_us + pace_us;
                    if let Some(cap) = queue_cap_per_ms {
                        let bucket = egress_ms_counts.entry(send_us / 1000).or_default();
                        *bucket += 1;
                        if *bucket > cap {
                            continue;
                        }
                    }
                    if burst_drop > 0 {
                        burst_drop -= 1;
                        continue;
                    }
                    // 1.5% random loss; 50% of loss events are 2-shard bursts.
                    if (next_u64() % 10_000) < 150 {
                        if (next_u64() & 1) == 1 {
                            burst_drop = 1;
                        }
                        continue;
                    }
                    // 10ms one-way + 0..4ms normal jitter + 15% chance of 15..22ms metro/Wi-Fi reordering spike.
                    let base_jitter = next_u64() % 4_000;
                    let spike = if (next_u64() % 100) < 15 { 15_000 + (next_u64() % 7_000) } else { 0 };
                    let arrive_us = send_us + 10_000 + base_jitter + spike;
                    ev_id += 1;
                    events.push(Reverse((arrive_us, ev_id, d)));
                }
            }
            if use_new {
                let mut media = MediaIn::new(7, false);
                stream_at(&mut media, &config(1), t0);
                while let Some(Reverse((at_us, _, d))) = events.pop() {
                    let now = t0 + Duration::from_micros(at_us);
                    while let Some(dl) = media.deadline() {
                        if now >= dl {
                            media.tick(dl);
                        } else {
                            break;
                        }
                    }
                    media.datagram(&d, now);
                }
                media.tick(t0 + Duration::from_secs(5));
                (media.counts.video, media.counts.given_up, media.gap_wait().as_millis() as u64)
            } else {
                let mut old = OldMediaIn::new(7);
                stream_at(&mut old.inner, &config(1), t0);
                while let Some(Reverse((at_us, _, d))) = events.pop() {
                    let now = t0 + Duration::from_micros(at_us);
                    while let Some(dl) = old.deadline_old() {
                        if now >= dl {
                            old.tick_old(dl);
                        } else {
                            break;
                        }
                    }
                    old.datagram(&d, now);
                }
                old.tick_old(t0 + Duration::from_secs(5));
                (old.inner.counts.video, old.inner.counts.given_up, 3)
            }
        };

        // Scenario A: Pure metro reordering + 1.5% burst loss (no egress queue drops).
        let (old_a_del, old_a_gu, _) = run_sim(false, None);
        let (new_a_del, new_a_gu, new_a_gap) = run_sim(true, None);
        eprintln!(
            "METRO SIM [A: jitter+loss]: BEFORE delivered={old_a_del}/120 ({:.1}%), given_up={old_a_gu} | AFTER delivered={new_a_del}/120 ({:.1}%), given_up={new_a_gu}, adaptive_gap_wait={new_a_gap}ms",
            old_a_del as f64 * 100.0 / FRAMES as f64,
            new_a_del as f64 * 100.0 / FRAMES as f64,
        );
        assert!(new_a_gu < old_a_gu, "Scenario A expected fewer keyframe storms: new={new_a_gu} vs old={old_a_gu}");
        assert!(new_a_del > old_a_del && new_a_del >= 115, "Scenario A expected >=95% delivery vs old: new={new_a_del} vs old={old_a_del}");
        assert!(new_a_gu <= 1, "Scenario A expected at most genuine unrecoverable burst loss, got {new_a_gu}");

        // Scenario B: Same metro link + shallow 48-pkt/ms Wi-Fi/router egress queue.
        let (old_b_del, old_b_gu, _) = run_sim(false, Some(48));
        let (new_b_del, new_b_gu, new_b_gap) = run_sim(true, Some(48));
        eprintln!(
            "METRO SIM [B: +48-pkt/ms queue]: BEFORE delivered={old_b_del}/120 ({:.1}%), given_up={old_b_gu}, keyframe_max_burst={old_max_per_ms}/ms | AFTER delivered={new_b_del}/120 ({:.1}%), given_up={new_b_gu}, adaptive_gap_wait={new_b_gap}ms, keyframe_max_burst={new_max_per_ms}/ms",
            old_b_del as f64 * 100.0 / FRAMES as f64,
            new_b_del as f64 * 100.0 / FRAMES as f64,
        );
        assert!(new_b_del >= 115 && new_b_del > old_b_del, "Scenario B expected >=95% delivery vs old: new={new_b_del} vs old={old_b_del}");
        assert!(new_b_gu <= 1, "Scenario B expected at most genuine unrecoverable burst loss, got {new_b_gu}");
    }
}
