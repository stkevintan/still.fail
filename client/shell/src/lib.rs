//! The native shell of the core in TypeScript in the apps (client/core-ts `hosts/bridge.ts`; apps/mbui/engine runs it
//! in Hermes from C++): everything the core asks of its host that a JS engine has not, done on tokio's threads and on
//! a thread for the disk, and answered through a C callback. What it does is what the Rust core's native host (client/ffi) did (reqwest,
//! tokio-tungstenite, a file per storage key in the data directory, TCP to adbd) and what the station's addon does for
//! Node (iroh), so a phone moving from the Rust core keeps its sign-in. Each signed-in account's database is SQLite,
//! `databases/<name>.db` (beside the storage keys' files: `accounts` is one), used synchronously by the core's thread
//! (`sql.*`); the former `core.db` is only read, once.
//!
//! Operations are named and take JSON and maybe bytes; bridge.ts lists them. `sf_shell_call` answers later through
//! `complete(ctx, id, json, error, bytes)` from any thread; `sf_shell_call_sync` answers at once.

use std::collections::HashMap;
use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};

use iroh::Endpoint;
use iroh::endpoint::Connection;
use serde_json::{Value, json};

mod adb;
mod crypto;
mod ffi;
mod fs_ops;
mod iroh_ops;
mod istream;
mod keep;
mod log;
mod mesh;
mod net;
mod screen_dgram;
mod screen_tap;
mod sql;
mod tar;
mod zstd_ops;

#[cfg(test)]
mod tests;

pub use ffi::{
    Complete, Media, Say, sf_free, sf_shell_call, sf_shell_call_sync, sf_shell_screen_ack, sf_shell_screen_ack_wait, sf_shell_screen_input, sf_shell_set_media, sf_shell_set_say, sf_shell_start,
    sf_shell_stats, sf_shell_stop, sf_utc_offset_min,
};

use ffi::Ctx;
use fs_ops::TextReader;
use iroh_ops::Kept;
use istream::Halves;
use net::{Listener, SocketRead, SocketWrite, WsFrame, http_client, tls_config};
use screen_tap::Tell;
use sql::{DbHandle, open_wait};
use zstd_ops::Unzstd;

/// An answer: JSON, and bytes where the operation has them.
pub(crate) struct Answer {
    pub(crate) json: Value,
    pub(crate) bytes: Option<Vec<u8>>,
}

impl Answer {
    pub(crate) fn json(json: Value) -> Answer {
        Answer { json, bytes: None }
    }
    pub(crate) fn bytes(json: Value, bytes: Vec<u8>) -> Answer {
        Answer { json, bytes: Some(bytes) }
    }
}

pub(crate) type Done = Result<Answer, String>;

pub(crate) fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

pub(crate) fn str_of<'a>(v: &'a Value, k: &str) -> Result<&'a str, String> {
    v.get(k).and_then(Value::as_str).ok_or_else(|| format!("missing {k}"))
}

pub(crate) fn id_of(v: &Value) -> Result<u64, String> {
    v.get("id").and_then(Value::as_u64).ok_or_else(|| "missing id".to_string())
}

#[derive(Clone)]
pub(crate) enum Handle {
    Response(Arc<tokio::sync::Mutex<reqwest::Response>>),
    Ws { incoming: Arc<tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Result<WsFrame, String>>>>, outgoing: tokio::sync::mpsc::UnboundedSender<WsFrame> },
    /// A socket to the device's own port, or a station's session on the phone's adb (`adb.open`).
    Tcp { read: SocketRead, write: SocketWrite },
    Endpoint(Endpoint, Arc<Kept>),
    Conn(Connection),
    /// A connection that closed, let go (its state, its streams), with what the core may still ask of it; `conn.close`
    /// with `forget: true` lets it go entirely, before or after it closed.
    Gone { remote: String, alpn: String, reason: Value, stats: Value },
    /// An endpoint closed (`iroh.close`), let go, with what the core may still ask of it: one bound anew in its place
    /// leaves a dial still under way on it asking its relays as it fails (mesh.ts `link`), as the station's addon answers.
    /// `iroh.close` with `forget: true` lets it go entirely, before or after it closed.
    Unbound { id: String },
    IStream(Arc<Halves>),
    /// A socket listening on this machine (`tcp.listen`, `unix.listen`): what a station's program serves (station/mb).
    Listener(Arc<Listener>),
    /// A zstd stream being taken apart (`zstd.open`).
    Unzstd(Arc<Mutex<Unzstd>>),
    /// A zstd stream being made (`zstd.stream`): each piece given flushed out whole (station/mesh/compress.ts's way).
    Zstd(Arc<Mutex<zstd::stream::raw::Encoder<'static>>>),
    /// A directory sync's sending (`pack.open`): each file's Git blob id as its pieces are packed (`zstd.pack`), by path,
    /// with where its next piece starts.
    Pack(Arc<Mutex<HashMap<String, (sha1::Sha1, u64)>>>),
}

impl Handle {
    fn kind(&self) -> &'static str {
        match self {
            Handle::Response(_) => "response",
            Handle::Ws { .. } => "ws",
            Handle::Tcp { .. } => "tcp",
            Handle::Endpoint(..) => "endpoint",
            Handle::Conn(_) => "conn",
            Handle::Gone { .. } => "gone",
            Handle::Unbound { .. } => "unbound",
            Handle::IStream(_) => "stream",
            Handle::Listener(_) => "listener",
            Handle::Unzstd(_) => "unzstd",
            Handle::Zstd(_) => "zstd",
            Handle::Pack(_) => "pack",
        }
    }
}

type Job = Box<dyn FnOnce() + Send>;

pub(crate) struct Inner {
    pub(crate) complete: Complete,
    pub(crate) ctx: Ctx,
    pub(crate) dir: PathBuf,
    /// One thread does every file and database job, in the order they were asked for (as the Rust core's did).
    disk: Mutex<mpsc::Sender<Job>>,
    pub(crate) db: Arc<Mutex<DbHandle>>,
    pub(crate) tls: Arc<rustls::ClientConfig>,
    pub(crate) http: Mutex<reqwest::Client>,
    /// The pool of requests that follow redirects (`redirect: "follow"`, up to ten); `http` follows none.
    pub(crate) http_follow: Mutex<reqwest::Client>,
    /// A pool for each cloud entry requests go through (`entry`: station/AGENTS.md, Cloud TCP entries), by its host and
    /// port and whether it follows redirects.
    pub(crate) entries: Mutex<HashMap<(String, u16, bool), reqwest::Client>>,
    /// Fetch calls still owned by the core. Their exchange is dropped when its caller stops waiting, even between
    /// response headers and the body. Registered before spawning, so an immediate cancellation cannot miss it.
    pub(crate) fetches: Mutex<HashMap<u64, tokio::sync::oneshot::Sender<()>>>,
    pub(crate) handles: Mutex<HashMap<u64, Handle>>,
    pub(crate) next: AtomicU64,
    /// The accounts' databases open, by id, with their files.
    pub(crate) sqls: Mutex<HashMap<u64, (Option<PathBuf>, rusqlite::Connection)>>,
    /// Files being read a part at a time (`text.open`), by id.
    pub(crate) texts: Mutex<HashMap<u64, TextReader>>,
    /// How long an account's database is waited for as it is opened, while another process holds it (`open_wait`).
    pub(crate) open_wait: std::time::Duration,
    /// Where a message for the app goes straight from here (`sf_shell_set_say`): none, nothing is tapped.
    pub(crate) say: Mutex<Option<(Say, Ctx)>>,
    /// Where a tapped view's records are offered first (`sf_shell_set_media`): none, all are said.
    pub(crate) media: Mutex<Option<(Media, Ctx)>>,
    pub(crate) adb: adb::Adb,
    /// Each connection's datagrams' reader, by its handle, while a view takes them (screen_dgram.rs `route`).
    pub(crate) demuxes: Mutex<HashMap<u64, Arc<Mutex<std::sync::Weak<screen_dgram::Demux>>>>>,
    /// What the app sends each tapped view straight (`sf_shell_screen_input`), by the view's call, in order.
    pub(crate) inputs: Mutex<HashMap<u64, Arc<istream::InputLine>>>,
}

pub struct Shell {
    pub(crate) runtime: tokio::runtime::Runtime,
    pub(crate) inner: Arc<Inner>,
}

/// What the shells have been asked, for when the app's memory runs away (the app's MemoryWatch.kt): the calls by
/// operation since the process started and those not answered yet, and the shells' handles by kind. A loop between the
/// core and the shell shows as one operation far ahead of the rest.
#[derive(Default)]
struct Stats {
    calls: HashMap<String, (u64, i64)>,
    shells: Vec<std::sync::Weak<Inner>>,
}

static STATS: std::sync::LazyLock<Mutex<Stats>> = std::sync::LazyLock::new(Mutex::default);

/// One more of `what` (the shell's own doings, beside the operations asked: `tap.video`, a remote screen's frame said to
/// the app), as counted operations are.
pub(crate) fn tally(what: &str) {
    let mut stats = STATS.lock().unwrap();
    // (no name made again for each: a screen's frames are counted a hundred times a second)
    match stats.calls.get_mut(what) {
        Some(c) => c.0 += 1,
        None => {
            stats.calls.insert(what.to_string(), (1, 0));
        }
    }
}

pub(crate) fn counted(op: &str, started: bool) {
    let mut stats = STATS.lock().unwrap();
    let c = stats.calls.entry(op.to_string()).or_default();
    if started {
        c.0 += 1;
        c.1 += 1;
    } else {
        c.1 -= 1;
    }
}

pub(crate) fn stats_json() -> Value {
    let mut stats = STATS.lock().unwrap();
    stats.shells.retain(|w| w.strong_count() > 0);
    let calls: serde_json::Map<String, Value> = stats.calls.iter().map(|(op, (n, open))| (op.clone(), json!([n, open]))).collect();
    let mut handles: HashMap<&'static str, u64> = HashMap::new();
    let mut sqls = 0;
    for inner in stats.shells.iter().filter_map(std::sync::Weak::upgrade) {
        for h in inner.handles.lock().unwrap().values() {
            *handles.entry(h.kind()).or_default() += 1;
        }
        sqls += inner.sqls.lock().unwrap().len();
    }
    json!({ "calls": calls, "handles": handles, "sqls": sqls })
}

impl Tell for Inner {
    fn media(&self, call: u64, kind: u8, key: bool, seq: u64, ts: u64, bytes: &[u8]) -> bool {
        let Some((media, ctx)) = &*self.media.lock().unwrap() else { return false };
        media(ctx.0, call, kind, key as u8, seq, ts, bytes.as_ptr(), bytes.len()) != 0
    }

    /// A message for the app said from here (`say`), as the core says one.
    fn say(&self, text: &[u8], bytes: Option<&[u8]>) {
        let Some((say, ctx)) = &*self.say.lock().unwrap() else { return };
        let (b, blen) = match bytes {
            Some(b) => (if b.is_empty() { [0u8; 1].as_ptr() } else { b.as_ptr() }, b.len()),
            None => (std::ptr::null(), 0),
        };
        say(ctx.0, text.as_ptr(), text.len(), b, blen);
    }
}

impl Inner {
    pub(crate) fn keep(&self, handle: Handle) -> u64 {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.handles.lock().unwrap().insert(id, handle);
        id
    }

    pub(crate) fn handle(&self, id: u64) -> Result<Handle, String> {
        self.handles.lock().unwrap().get(&id).cloned().ok_or_else(|| format!("no handle {id}"))
    }

    pub(crate) fn drop_handle(&self, id: u64) -> Option<Handle> {
        self.handles.lock().unwrap().remove(&id)
    }

    /// A job for the disk thread, answered when done.
    pub(crate) async fn disk<T: Send + 'static>(&self, job: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
        let (done, answer) = tokio::sync::oneshot::channel();
        self.disk.lock().unwrap().send(Box::new(move || {
            let _ = done.send(job());
        })).map_err(|_| "the disk thread is gone".to_string())?;
        answer.await.map_err(|_| "the disk thread is gone".to_string())?
    }

    pub(crate) async fn run(self: &Arc<Self>, op: &str, a: Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "stream.close" | "ws.close" | "tcp.close" | "zstd.close" | "listen.close" | "pack.close" => {
                // Dropping the response, the socket's sender (its task ends) or the halves closes it.
                self.drop_handle(id_of(&a)?);
                Ok(Answer::json(json!({})))
            }
            "db.read" => self.db_read(&a).await,
            "fetch"
            | "stream.open"
            | "stream.read"
            | "ws.open"
            | "ws.next"
            | "ws.send"
            | "ws.ping"
            | "tcp.open"
            | "adb.pair"
            | "adb.hold"
            | "adb.state"
            | "adb.open"
            | "tcp.listen"
            | "unix.listen"
            | "tcp.pipe"
            | "tcp.accept"
            | "tcp.read"
            | "tcp.write"
            | "tcp.end"
            | "unix.open"
            | "reset" => self.run_net(op, &a, bytes).await,
            "zstd.compress"
            | "zstd.unpack"
            | "zstd.stream"
            | "zstd.open"
            | "zstd.push"
            | "pack.open"
            | "zstd.pack"
            | "zstd.segments"
            | "zstd.check"
            | "tar.pack"
            | "tar.unpack"
            | "tar.file" => self.run_zstd(op, &a, bytes).await,
            "fs.put" | "fs.rotate" | "storage.get" | "storage.set" | "storage.delete" => self.run_fs_async(op, &a, bytes).await,
            "iroh.bind"
            | "iroh.meshSubscribe"
            | "iroh.meshUnsubscribe"
            | "iroh.meshAttachLeaf"
            | "iroh.meshUseLeaf"
            | "iroh.meshDetachLeaf"
            | "iroh.meshConfigure"
            | "iroh.meshRemove"
            | "iroh.connect"
            | "iroh.accept"
            | "iroh.setRelayEntries"
            | "iroh.networkChange"
            | "iroh.close"
            | "iroh.disabledRelays"
            | "iroh.online"
            | "iroh.insertRelay"
            | "iroh.removeRelay"
            | "iroh.publicRelays"
            | "iroh.keep"
            | "iroh.setCongestion"
            | "iroh.setAlpns"
            | "iroh.holdIncoming"
            | "iroh.probeRelay"
            | "conn.openBi"
            | "conn.openUni"
            | "conn.acceptBi"
            | "conn.closed"
            | "conn.close"
            | "conn.answers" => self.run_iroh(op, &a, bytes).await,
            "conn.hand"
            | "istream.tap"
            | "istream.mediaDatagrams"
            | "istream.receiveMediaDatagrams"
            | "istream.read"
            | "istream.write"
            | "istream.finish"
            | "istream.stopped"
            | "istream.reset"
            | "istream.pipe"
            | "istream.hand" => self.run_istream(op, &a, bytes).await,
            // The filesystem's and a program's run, asked without waiting (`shell`, not `shell_sync`): done off the caller's
            // thread, so a program that serves many (station/mb's sessions) is not held by a big file or a slow `git`.
            op if op.starts_with("fs.") || op == "proc.run" => {
                let (inner, op, a) = (self.clone(), op.to_string(), a);
                let value = tokio::task::spawn_blocking(move || inner.run_sync(&op, &a)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            other => Err(format!("no operation {other}")),
        }
    }

    pub(crate) fn run_sync(&self, op: &str, a: &Value) -> Result<Value, String> {
        // Whether a screen view's Opus sound is decoded here (ScreenTap): only where its tap says to the app, so the
        // core asks the station for Opus only then (client/core-ts hosts/bridge.ts `opus`), else PCM.
        if op == "tap.opus" {
            return Ok(json!(self.say.lock().unwrap().is_some()));
        }
        // Whether a view's frames may come as datagrams here (`istream.receiveMediaDatagrams`): a shell from before says
        // no such op (client/core-ts hosts/bridge.ts `mediaDatagrams`).
        if op == "istream.datagrams" {
            return Ok(json!(true));
        }
        if op == "fetch.cancel" {
            let pending = self.fetches.lock().unwrap().remove(&id_of(a)?);
            return Ok(json!(pending.is_some_and(|cancel| cancel.send(()).is_ok())));
        }
        if let Some(value) = self.run_fs_sync(op, a)? {
            return Ok(value);
        }
        if let Some(value) = crypto::run_sync(op, a)? {
            return Ok(value);
        }
        self.run_iroh_sync(op, a)
    }
}

impl Shell {
    pub fn start(dir: PathBuf, complete: Complete, ctx: *mut c_void) -> std::io::Result<Shell> {
        Shell::start_waiting(dir, complete, ctx, open_wait())
    }

    pub(crate) fn start_waiting(dir: PathBuf, complete: Complete, ctx: *mut c_void, open_wait: std::time::Duration) -> std::io::Result<Shell> {
        std::fs::create_dir_all(&dir)?;
        // Two threads in an app; a station's program says how many it is to have (STILLFAIL_SHELL_THREADS: the station's
        // front, whose threads carry every byte of the station's iroh, its addon's on as many as the machine has cores).
        let threads = std::env::var("STILLFAIL_SHELL_THREADS").ok().and_then(|n| n.parse::<usize>().ok()).filter(|n| *n > 0).unwrap_or(2);
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(threads).thread_name("stillfail-shell").enable_all().build()?;
        let (jobs, queue) = mpsc::channel::<Job>();
        std::thread::Builder::new().name("stillfail-disk".into()).spawn(move || {
            for job in queue {
                job();
            }
        })?;
        let tls = Arc::new(tls_config());
        let http = Mutex::new(http_client(&tls, false));
        let http_follow = Mutex::new(http_client(&tls, true));
        let db = Arc::new(Mutex::new(DbHandle { path: dir.join("core.db"), conn: None }));
        let adb = adb::Adb::new(dir.clone());
        let inner = Arc::new(Inner { complete, ctx: Ctx(ctx), dir, disk: Mutex::new(jobs), db, tls, http, http_follow, entries: Mutex::default(), fetches: Mutex::default(), handles: Mutex::default(), next: AtomicU64::new(1), sqls: Mutex::default(), texts: Mutex::default(), open_wait, say: Mutex::default(), media: Mutex::default(), adb, demuxes: Mutex::default(), inputs: Mutex::default() });
        STATS.lock().unwrap().shells.push(Arc::downgrade(&inner));
        Ok(Shell { runtime, inner })
    }

    pub fn call(&self, id: u64, op: String, json: &[u8], bytes: Option<Vec<u8>>) {
        let inner = self.inner.clone();
        let args: Value = serde_json::from_slice(json).unwrap_or(Value::Null);
        // A fetch, a dial's handshake (iroh.connect), a WebSocket's opening (ws.open) and a stream's head or next piece
        // (stream.open, stream.read): given up when the core cancels the call, its connection dropped, which closes it (a
        // dial left going retransmitted its Initial for the connection's whole idle timeout: the station addon's `dial`,
        // station/native/mesh/src/lib.rs; a WebSocket's handshake left going held its socket until the other side spoke).
        let cancelled = if matches!(op.as_str(), "fetch" | "iroh.connect" | "ws.open" | "stream.open" | "stream.read") {
            let (cancel, cancelled) = tokio::sync::oneshot::channel();
            inner.fetches.lock().unwrap().insert(id, cancel);
            Some(cancelled)
        } else {
            None
        };
        counted(&op, true);
        self.runtime.spawn(async move {
            let done = if let Some(cancelled) = cancelled {
                let done = tokio::select! {
                    biased;
                    _ = cancelled => Err("cancelled".into()),
                    done = inner.run(&op, args, bytes) => done,
                };
                inner.fetches.lock().unwrap().remove(&id);
                done
            } else {
                inner.run(&op, args, bytes).await
            };
            counted(&op, false);
            let (json, error, bytes) = match done {
                Ok(answer) => (serde_json::to_vec(&answer.json).unwrap_or_default(), Vec::new(), answer.bytes),
                Err(e) => (Vec::new(), if e.is_empty() { b"failed".to_vec() } else { e.into_bytes() }, None),
            };
            let (b, blen, has) = match &bytes {
                Some(b) => (b.as_ptr(), b.len(), 1),
                None => (std::ptr::null(), 0, 0),
            };
            (inner.complete)(inner.ctx.0, id, json.as_ptr(), json.len(), error.as_ptr(), error.len(), b, blen, has);
        });
    }

    pub fn call_sync(&self, op: &str, json: &[u8]) -> Vec<u8> {
        let args: Value = serde_json::from_slice(json).unwrap_or(Value::Null);
        counted(op, true);
        counted(op, false);
        let done = if op.starts_with("sql.") { self.inner.sql(op, &args) } else { self.inner.run_sync(op, &args) };
        let out = match done {
            Ok(value) => json!({ "value": value }),
            Err(error) => json!({ "error": error }),
        };
        serde_json::to_vec(&out).unwrap_or_default()
    }
}
