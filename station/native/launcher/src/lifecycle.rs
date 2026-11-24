//! The station's Node processes under the launcher, as one state machine for every platform: started, ready, crashed
//! and started again after a backoff that doubles (back to the first once a Node served `stable`), given up after
//! START_FAILURES starts in a row that never got ready, handed over to a new Node beside the old one (where the
//! platform can: Unix's SIGUSR2), drained, stopped (killed when it does not stop in time), stopped with the parent.
//!
//! run.rs (Unix) and run_windows.rs give it their processes (`Os`, `Process`) and tell it what happened (a line from a
//! Node, a Node's end, a stop, a handover asked for); they decide nothing of the lifecycle themselves, so a change to
//! restarts, timeouts or stopping is made here once and tested here once, on every platform.

use std::io::Result;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::data::{self, now_ms, write_whole};
use crate::log;

pub struct Options {
    pub data: PathBuf,
    pub app: PathBuf,
    pub port: u16,
    pub named: bool,
    pub with_parent: bool,
    /// Run by a launcher of this station becoming this one at a handover (`--resume`, run.rs `renew`): what it hands
    /// on, taken up instead of a start.
    pub resume: Option<String>,
}

/// How long things may take. Tests shorten them (STILLFAIL_LAUNCHER_TIMES: `ready=ms,exit=ms,…`).
#[derive(Clone, Copy, Debug)]
pub struct Times {
    /// A new Node's wait to say ready on a handover, before the handover is given up.
    pub ready: Duration,
    /// The old Node's to exit once told to hand over; a stopped one's. Then it is killed.
    pub exit: Duration,
    pub stop: Duration,
    /// Restarts after an unexpected exit: `backoff` doubled each time, up to `backoff_max`; back to `backoff` after a
    /// Node that ran `stable` since it was ready.
    pub backoff: Duration,
    pub backoff_max: Duration,
    pub stable: Duration,
    /// --with-parent: how often the parent is looked for.
    pub parent: Duration,
    /// How long run/drained stays when nobody stops the station (the Rust station's DRAINED_LIMIT).
    pub drained: Duration,
    /// A Node's, once it serves (ready, or handed over to), to take over: serve every entrance (TAKEN_OVER). The old one
    /// exiting (`exit`) and Node waiting for it (agents.ts PREVIOUS_LIMIT_MS, 40 s) fit in it. Counted again from each
    /// time it says it is still `taking`: one a loaded machine makes slow gets there, and ending it would only start
    /// the same work over (2026-11-06: six in a row on a station); one that hangs is ended.
    pub take: Duration,
    /// After a handover whose new Node did not take over, the wait before a Node is started again: the installer's to
    /// put the release from before back (the old Node is gone by then; this way the next one runs on it).
    pub rollback: Duration,
    /// A front (front.rs) that ends sooner than this after it started is not started again at once (it would only end
    /// again), but after `front_retry`.
    pub front: Duration,
    /// A Node that has taken over and says it is alive (`{"heartbeat":true}`, from its main thread's loop: main.ts) and
    /// then says nothing for this long is hung (its main thread held, a deadlock, a heap that will not end it): killed
    /// and started again. One that never said it (a release from before `--launcher-heartbeat`) is never held to it.
    pub heartbeat: Duration,
    /// After the front was given up (`front_gone`), the wait before one is started again: doubled each time it does not
    /// start, up to FRONT_RETRY_MOST. Started, the Node serving hands over to one linked to it.
    pub front_retry: Duration,
    /// How often the front is asked whether it answers (a line on its socket answered): FRONT_MISSES in a row that are
    /// not, and it is killed (then started again as after any end of it).
    pub front_probe: Duration,
}

/// What a Node serves once it has taken over the station: the agents' door (after the sessions are taken up) and the
/// loopback port. Until then it is not "up" for station.json (an installer's handover is not done).
const TAKEN_OVER: [&str; 2] = ["admin", "mcp"];

/// Starts in a row that end before Node says ready, after which the launcher gives up (the service starts it again).
pub const START_FAILURES: u32 = 5;

/// Asks of the front in a row that it did not answer, after which it is taken for hung.
pub const FRONT_MISSES: u32 = 3;

/// The longest wait between two tries at starting the front again.
const FRONT_RETRY_MOST: Duration = Duration::from_secs(3600);

/// What the launcher did to recover (a Node or front killed as hung, a crash, a handover given up), a JSON line each in
/// run/: the station that starts next takes the file and logs each as its own (station/src/ops/launcher-events.ts,
/// station/mb/src/station_main/launcher_events.mbt), so they reach the station's log upload; else they were only in
/// stderr. Written whole each time (`write_whole`: never half a line read), the newest EVENTS_KEPT kept.
const EVENTS: &str = "launcher-events.jsonl";
const EVENTS_KEPT: usize = 50;
/// The longest `reason` kept of a handover given up (its words are the launcher's own).
const REASON_MOST: usize = 240;

impl Times {
    pub fn of_env() -> Times {
        let s = Duration::from_secs;
        let mut times = Times { ready: s(60), exit: s(30), stop: s(30), backoff: s(1), backoff_max: s(60), stable: s(60), parent: s(2), drained: s(300), take: s(90), rollback: s(10), front: s(10), heartbeat: s(90), front_retry: s(300), front_probe: s(30) };
        for pair in std::env::var("STILLFAIL_LAUNCHER_TIMES").unwrap_or_default().split(',') {
            let Some((key, ms)) = pair.split_once('=') else { continue };
            let Ok(ms) = ms.trim().parse::<u64>() else { continue };
            let slot = match key.trim() {
                "ready" => &mut times.ready,
                "exit" => &mut times.exit,
                "stop" => &mut times.stop,
                "backoff" => &mut times.backoff,
                "backoff_max" => &mut times.backoff_max,
                "stable" => &mut times.stable,
                "parent" => &mut times.parent,
                "drained" => &mut times.drained,
                "take" => &mut times.take,
                "rollback" => &mut times.rollback,
                "front" => &mut times.front,
                "heartbeat" => &mut times.heartbeat,
                "front_retry" => &mut times.front_retry,
                "front_probe" => &mut times.front_probe,
                _ => continue,
            };
            *slot = Duration::from_millis(ms);
        }
        // (each also of its own, for a test or a machine to set alone)
        for (var, slot) in [("STILLFAIL_LAUNCHER_HEARTBEAT_MS", &mut times.heartbeat), ("STILLFAIL_LAUNCHER_FRONT_RETRY_MS", &mut times.front_retry), ("STILLFAIL_LAUNCHER_FRONT_PROBE_MS", &mut times.front_probe)] {
            if let Some(ms) = std::env::var(var).ok().and_then(|v| v.trim().parse::<u64>().ok()) {
                *slot = Duration::from_millis(ms);
            }
        }
        times
    }
}

/// One Node process as the platform has it: its pid, and the control channel the launcher tells it on.
pub trait Process {
    fn pid(&self) -> u32;
    /// A line on the control channel; what it says is not logged (it may carry secrets).
    fn send(&self, line: &Value);
    /// `{"op":<op>}` on the control channel.
    fn tell(&self, op: &str) {
        self.send(&serde_json::json!({ "op": op }));
    }
}

/// What the launcher does to processes, and its clock: the system's, or a test's.
pub trait Os {
    type Node: Process;
    fn now(&self) -> Instant;
    /// A new Node.
    fn spawn(&mut self) -> Result<Self::Node>;
    /// Ends a Node whose end has not been seen yet.
    fn kill(&mut self, node: &mut Self::Node);
    /// --with-parent: whether the launcher's parent is gone.
    fn parent_gone(&mut self) -> bool;
    /// What `spawn` starts, for what is said when it does not.
    fn program(&self) -> String;
    /// Connections to the launcher's entrance `name` (mcp, admin) go to `port` from now on (the Node serving's, on
    /// 127.0.0.1); none: none serves, they wait. Where the launcher keeps entrances (Windows: proxy.rs); where Node
    /// listens on sockets handed down to it (Unix), they are its already, and nothing is to be done.
    fn route(&mut self, _name: &str, _port: Option<u16>) {}
    /// Before a handover, with the Node serving (`version`, serving on `served`, saying it is alive: `heartbeats`) and
    /// nothing else running: where the release at --app has a launcher unlike this one, it takes this one's place,
    /// keeping its lock, ports and that Node, and goes on with the handover (`adopt`). Unix: this process becomes it
    /// (exec, its pid kept) and does not return. Windows, which has no exec: a process of its own is handed them, and
    /// this returns true: this launcher only lingers for what it still carries and ends (run_windows.rs). Else (none,
    /// the same, one that cannot take over from this) it returns false and this one hands over.
    fn renew(&mut self, _serving: &Self::Node, _version: &str, _served: &[(String, u16)], _heartbeats: bool) -> bool {
        false
    }
    /// Whether a front (front.rs) runs for the Nodes.
    fn has_front(&self) -> bool {
        false
    }
    /// Where none runs, one started: whether it listens now.
    fn front_again(&mut self) -> bool {
        false
    }
    /// The front asked whether it answers; the answer told later, `Lifecycle::front_probed(n, …)`.
    fn probe_front(&mut self, _n: u64) {}
    /// The front ended, as hung (its end is seen as any other's).
    fn kill_front(&mut self) {}
    /// The front there ended (its stdin closed, killed where it does not end by itself) and another started in its
    /// place: whether that one listens. None where the platform keeps no front (Windows).
    fn restart_front(&mut self) -> bool {
        false
    }
    /// The release's installer `script` started apart from the launcher, told `env` only, as the station's
    /// platform.startInstaller starts it (its copy in run/ replacing any there, its exit and log beside it): whether it
    /// started. Asked by a Node whose own start of it did not (`{"installer":…}`), so a station whose program cannot
    /// start one still updates. None where the platform does not here (Windows' scheduled task is the station's).
    fn run_installer(&mut self, _script: &str, _env: &[(String, String)]) -> bool {
        false
    }
    /// Best-effort bounded diagnostics of a hung Node before it is killed (process state, wait channel, memory/FDs,
    /// stack): numbers, state codes and symbol names only (no paths, no arguments, nothing a person wrote).
    fn diagnose_hung(&mut self, _node: &Self::Node) -> serde_json::Map<String, Value> {
        serde_json::Map::new()
    }
}

/// A Node and what the launcher knows of it.
pub struct Node<P> {
    pub process: P,
    ready: Option<Instant>,
    version: String,
    /// The ports it said it serves on (`{"serving":<name>,"port":<n>}`): once it has taken over, as its own.
    served: Vec<(String, u16)>,
    /// Serving, not taken over yet: by when it must have.
    take_by: Option<Instant>,
    /// Taken over: station.json says its start.
    taken: bool,
    /// It came in by a handover (a failure to take over is the handover's).
    handed: bool,
    /// Being ended for not taking over.
    given_up: bool,
    /// It says it is alive (`{"heartbeat":true}`): held to it once it has taken over.
    heartbeats: bool,
    /// When it last said so (or took over, or was taken up).
    heartbeat_at: Option<Instant>,
    /// Killed for saying nothing.
    hung: bool,
}

impl<P> Node<P> {
    fn serves_all(&self) -> bool {
        TAKEN_OVER.iter().all(|name| self.served.iter().any(|(n, _)| n == name))
    }
}

/// Which of the launcher's Nodes: the one serving, the one starting beside it (a handover), the one handing over.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Slot {
    Current,
    Next,
    Retiring,
}

pub struct Lifecycle<O: Os> {
    pub os: O,
    times: Times,
    run: PathBuf,
    current: Option<Node<O::Node>>,
    /// Starting for a handover: until when it may take to be ready, and whether it was given up (handoff-failed).
    next: Option<(Node<O::Node>, Instant, bool)>,
    /// Told to hand over: until when it may take to exit.
    retiring: Option<(Node<O::Node>, Instant)>,
    /// Stopping: until when the Nodes may take to exit.
    stopping: Option<Instant>,
    restart_at: Option<Instant>,
    failures: u32,
    backoff_step: u32,
    drained_at: Option<Instant>,
    /// No Node started before then (Times::rollback).
    restart_floor: Option<Instant>,
    /// --with-parent: when the parent is looked for next.
    parent_at: Option<Instant>,
    /// The launcher's exit once nothing runs.
    exit: i32,
    /// The front gone and none in its place (`front_gone`): the Nodes running are linked to it, so the one serving is
    /// replaced, by a handover once none is under way, with one that binds the station's endpoint itself.
    front_gone: bool,
    /// Gone so: when one is started again (Times::front_retry), and how many tries did not start one.
    front_retry_at: Option<Instant>,
    front_retries: u32,
    /// The front running: when it is asked next whether it answers, the ask out (its number, by when it is a miss),
    /// and the asks in a row it did not answer.
    front_probe_at: Option<Instant>,
    probing: Option<(u64, Instant)>,
    probes: u64,
    front_misses: u32,
    /// Its place taken by the release's launcher, a process of its own (Windows' `Os::renew`): nothing more is done here.
    renewed: bool,
    /// This launcher took the place of the one of this pid (Windows' renew): said in station.json (`renewedFrom`), so
    /// the installer takes the pid's change for a handover.
    renewed_from: Option<u32>,
}

impl<O: Os> Lifecycle<O> {
    pub fn new(os: O, times: Times, run: PathBuf, with_parent: bool) -> Lifecycle<O> {
        let parent_at = with_parent.then(|| os.now() + times.parent);
        let front_probe_at = os.has_front().then(|| os.now() + times.front_probe);
        Lifecycle {
            os,
            times,
            run,
            current: None,
            next: None,
            retiring: None,
            stopping: None,
            restart_at: None,
            failures: 0,
            backoff_step: 0,
            drained_at: None,
            restart_floor: None,
            parent_at,
            exit: 0,
            front_gone: false,
            front_retry_at: None,
            front_retries: 0,
            renewed: false,
            renewed_from: None,
            front_probe_at,
            probing: None,
            probes: 0,
            front_misses: 0,
        }
    }

    fn node(process: O::Node) -> Node<O::Node> {
        Node { process, ready: None, version: String::new(), served: vec![], take_by: None, taken: false, handed: false, given_up: false, heartbeats: false, heartbeat_at: None, hung: false }
    }

    /// The Node serving has taken over once it serves every entrance and the one before it is gone: station.json says
    /// its start then (not at ready: an installer takes that for a handover done).
    fn check_taken(&mut self) {
        if self.retiring.is_some() || self.stopping.is_some() {
            return;
        }
        let Some(node) = self.current.as_mut() else { return };
        if node.taken || node.ready.is_none() || !node.serves_all() {
            return;
        }
        node.taken = true;
        node.take_by = None;
        // Held to its word from now on (how long taking over took is `take`'s).
        if node.heartbeats {
            node.heartbeat_at = Some(self.os.now());
        }
        log::info(&format!("Node {} has taken over", node.process.pid()));
        self.failures = 0;
        self.say_started();
    }

    /// The Node serving did not take over (`why`): ended, and started again as after a crash; after a handover, once
    /// the installer has had the time to put the release before back.
    fn take_failed(&mut self, why: &str) {
        let Some(node) = self.current.as_mut() else { return };
        node.take_by = None;
        node.given_up = true;
        let pid = node.process.pid();
        log::warn(&format!("Node {pid} did not take over: {why}; ending it"));
        if node.handed {
            self.handoff_failed(&format!("the new station did not take over: {why}"));
            self.restart_floor = Some(self.os.now() + self.times.rollback);
        }
        let Lifecycle { os, current, .. } = self;
        if let Some(node) = current.as_mut() {
            os.kill(&mut node.process);
        }
    }

    /// The serving Node changed (from one that served on `before`): each entrance goes to the one serving now, where it
    /// serves on it; elsewhere connections wait for it to.
    fn reroute(&mut self, before: &[(String, u16)]) {
        let now: Vec<(String, u16)> = self.current.as_ref().map(|n| n.served.clone()).unwrap_or_default();
        let mut names: Vec<&str> = before.iter().chain(&now).map(|(name, _)| name.as_str()).collect();
        names.sort();
        names.dedup();
        for name in names {
            let port = now.iter().find(|(n, _)| n == name).map(|(_, p)| *p);
            self.os.route(name, port);
        }
    }

    /// The Node a launcher before this one in this process (`Os::renew`) left serving, taken over: it is up and serves
    /// on `served`, as it was there; station.json stays as it said. `heartbeats`: the launcher before heard it say it
    /// is alive (one from before that did not say: false, and it is held to it once it says it here).
    pub fn adopt(&mut self, process: O::Node, version: String, served: Vec<(String, u16)>, heartbeats: bool) {
        log::info(&format!("Node {} serving (version {version}) taken up from the launcher before", process.pid()));
        for (name, port) in &served {
            self.os.route(name, Some(*port));
        }
        let now = self.os.now();
        self.current = Some(Node { process, ready: Some(now), version, served, take_by: None, taken: true, handed: false, given_up: false, heartbeats, heartbeat_at: heartbeats.then_some(now), hung: false });
    }

    /// Whether the release's launcher took this one's place (Windows' `Os::renew`): it does nothing more.
    #[cfg_attr(unix, allow(dead_code))]
    pub fn renewed(&self) -> bool {
        self.renewed
    }

    /// This launcher took the place of the one of `pid` (Windows): station.json says so from the next Node's start.
    #[cfg_attr(unix, allow(dead_code))]
    pub fn renewed_from(&mut self, pid: u32) {
        self.renewed_from = Some(pid);
    }

    /// Starts the Node that serves (at first, after a crash).
    pub fn start(&mut self) {
        self.restart_at = None;
        match self.os.spawn() {
            Ok(process) => {
                log::info(&format!("Node started (pid {})", process.pid()));
                self.current = Some(Self::node(process));
            }
            Err(error) => {
                log::error(&format!("{} did not start: {error}", self.os.program()));
                self.failed_start();
            }
        }
    }

    /// A Node that ended before it was ready (or never started): again after the backoff, or, after START_FAILURES in
    /// a row, the launcher gives up.
    fn failed_start(&mut self) {
        self.failures += 1;
        if self.failures >= START_FAILURES {
            log::error(&format!("Node did not start {START_FAILURES} times in a row; giving up"));
            self.exit = 1;
            self.stop();
            return;
        }
        self.schedule_restart();
    }

    fn schedule_restart(&mut self) {
        let delay = self.times.backoff.saturating_mul(1 << self.backoff_step.min(16)).min(self.times.backoff_max);
        self.backoff_step += 1;
        let now = self.os.now();
        let at = (now + delay).max(self.restart_floor.take().unwrap_or(now));
        log::info(&format!("starting Node again in {} ms", at.saturating_duration_since(now).as_millis()));
        self.restart_at = Some(at);
    }

    /// station.json says this Node's start: the installer takes a new startedAt with the same pid for "handed over".
    fn say_started(&mut self) {
        let Some(node) = &self.current else { return };
        let text = data::station_json(std::process::id(), now_ms(), &node.version, self.renewed_from);
        if let Err(error) = write_whole(&self.run.join("station.json"), &text) {
            log::warn(&format!("station.json not written: {error}"));
        }
        let _ = std::fs::remove_file(self.run.join("drained"));
        self.drained_at = None;
    }

    fn handoff_failed(&self, why: &str) {
        log::warn(&format!("not handed over; going on as before: {why}"));
        let _ = write_whole(&self.run.join("handoff-failed"), &format!("{why}\n"));
        let mut end = why.len().min(REASON_MOST);
        while !why.is_char_boundary(end) {
            end -= 1;
        }
        self.record("handoff_failed", serde_json::json!({ "reason": &why[..end] }), false);
    }

    /// An event (`kind`, with `fields`) added to run/launcher-events.jsonl (EVENTS); `health`: with what the Node's last
    /// health.json said of it. Nothing that fails here stops the launcher.
    fn record(&self, kind: &str, fields: Value, health: bool) {
        let at = now_ms();
        let level = if matches!(kind, "node_hung_killed" | "node_crashed" | "front_hung_killed") { "error" } else { "warn" };
        let mut event = serde_json::json!({ "at": at, "kind": kind, "level": level });
        if let (Some(event), Value::Object(fields)) = (event.as_object_mut(), fields) {
            if health {
                event.extend(self.health_of(at));
            }
            event.extend(fields);
        }
        let path = self.run.join(EVENTS);
        let before = std::fs::read_to_string(&path).unwrap_or_default();
        let lines: Vec<&str> = before.lines().filter(|l| !l.trim().is_empty()).collect();
        let mut text = String::new();
        for line in &lines[lines.len().saturating_sub(EVENTS_KEPT - 1)..] {
            text.push_str(line);
            text.push('\n');
        }
        text.push_str(&event.to_string());
        text.push('\n');
        if let Err(error) = write_whole(&path, &text) {
            log::warn(&format!("{EVENTS} not written: {error}"));
        }
    }

    /// What the Node's health.json (station/src/ops/health.ts) said last, as of `at`: only its numbers and words of its
    /// own (no path, nothing a person wrote); none where there is none.
    fn health_of(&self, at: u64) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        let Some(health) = std::fs::read_to_string(self.run.join("health.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return out };
        if let Some(updated) = health["updatedAt"].as_f64().filter(|u| u.is_finite() && *u >= 0.0) {
            out.insert("healthAgeMs".into(), at.saturating_sub(updated as u64).into());
        }
        for name in ["rssBytes", "openFds", "heldMaxMs"] {
            if health[name].is_number() {
                out.insert(name.into(), health[name].clone());
            }
        }
        if let Some(front) = health["front"].as_str().filter(|f| matches!(*f, "ok" | "reconnecting" | "direct")) {
            out.insert("front".into(), front.into());
        }
        for name in ["presenceOnline", "relayConflict"] {
            if health[name].is_boolean() {
                out.insert(name.into(), health[name].clone());
            }
        }
        out
    }

    fn node_mut(&mut self, slot: Slot) -> Option<&mut Node<O::Node>> {
        match slot {
            Slot::Current => self.current.as_mut(),
            Slot::Next => self.next.as_mut().map(|n| &mut n.0),
            Slot::Retiring => self.retiring.as_mut().map(|n| &mut n.0),
        }
    }

    /// The Nodes there are, for the platform to read their control channels (Unix polls them; Windows' threads read).
    #[cfg_attr(windows, allow(dead_code))]
    pub fn processes_mut(&mut self) -> Vec<(Slot, &mut O::Node)> {
        let mut out = vec![];
        if let Some(n) = self.current.as_mut() {
            out.push((Slot::Current, &mut n.process));
        }
        if let Some(n) = self.next.as_mut() {
            out.push((Slot::Next, &mut n.0.process));
        }
        if let Some(n) = self.retiring.as_mut() {
            out.push((Slot::Retiring, &mut n.0.process));
        }
        out
    }

    /// Which Node `pid` is.
    pub fn slot_of(&self, pid: u32) -> Option<Slot> {
        if self.current.as_ref().is_some_and(|n| n.process.pid() == pid) {
            Some(Slot::Current)
        } else if self.next.as_ref().is_some_and(|n| n.0.process.pid() == pid) {
            Some(Slot::Next)
        } else if self.retiring.as_ref().is_some_and(|n| n.0.process.pid() == pid) {
            Some(Slot::Retiring)
        } else {
            None
        }
    }

    /// Lines from Node `pid`, read together: each one the word of the slot it is in by then. A Node starting beside that
    /// is ready serves from that line on, and the lines after it in the same read (where it serves) are the serving
    /// one's: taken with the slot they were read in, they went to no Node, and the new one never took over (CI,
    /// 2026-10-15).
    pub fn heard(&mut self, pid: u32, lines: Vec<Value>) {
        for message in lines {
            if let Some(slot) = self.slot_of(pid) {
                self.said(slot, message);
            }
        }
    }

    /// A line from the Node in `slot`.
    pub fn said(&mut self, slot: Slot, message: Value) {
        if message["ready"] == true {
            if slot == Slot::Next && self.next.as_ref().is_some_and(|n| n.2) {
                return;
            }
            let now = self.os.now();
            let take = self.times.take;
            let Some(node) = self.node_mut(slot) else { return };
            if node.ready.is_some() {
                return;
            }
            node.ready = Some(now);
            node.version = message["version"].as_str().unwrap_or_default().to_string();
            log::info(&format!("Node {} ready (version {})", node.process.pid(), node.version));
            match slot {
                Slot::Current => {
                    // Up; started fine once it has taken over (the backoff goes back only once it has served
                    // `stable`: crashed()).
                    node.take_by = Some(now + take);
                    self.check_taken();
                }
                Slot::Next => self.hand_over(),
                Slot::Retiring => {}
            }
        } else if let (Some(name), Some(port)) = (message["serving"].as_str(), message["port"].as_u64().and_then(|p| u16::try_from(p).ok())) {
            // Taken over and serving on `port`: the entrance goes there if it is the Node serving (else once it is).
            let Some(node) = self.node_mut(slot) else { return };
            node.served.retain(|(n, _)| n != name);
            node.served.push((name.to_string(), port));
            log::info(&format!("Node {} serves {name} on port {port}", node.process.pid()));
            if slot == Slot::Current {
                self.os.route(name, Some(port));
                self.check_taken();
            }
        } else if message["heartbeat"] == true {
            // Its main thread's loop runs (main.ts): said every 10 s.
            let now = self.os.now();
            if let Some(node) = self.node_mut(slot) {
                node.heartbeats = true;
                node.heartbeat_at = Some(now);
            }
        } else if message["taking"] == true {
            let by = self.os.now() + self.times.take;
            if let Some(node) = self.node_mut(slot)
                && let Some(take_by) = node.take_by.as_mut()
            {
                *take_by = by;
            }
        } else if let Some(why) = message["failed"].as_str() {
            // It could not take over (Node: the agents' side did not start).
            // Before or after ready; not one being ended already.
            if slot == Slot::Current && self.current.as_ref().is_some_and(|n| !n.taken && !n.given_up) {
                self.take_failed(why);
            } else {
                log::warn(&format!("Node failed: {why}"));
            }
        } else if message.get("carry").is_some() {
            // What the Node handing over holds only in memory (the vault's grants), to the one taking over: from memory
            // to memory, never logged or written down.
            let from = self.node_mut(slot).map_or(0, |n| n.process.pid());
            match (slot, &self.current) {
                (Slot::Retiring, Some(to)) => {
                    to.process.send(&serde_json::json!({ "op": "carried", "carried": message["carry"] }));
                    log::info(&format!("what Node {from} held in memory is carried over to Node {}", to.process.pid()));
                }
                _ => log::warn(&format!("Node {from} gave what it held with no Node to carry it to")),
            }
        } else if let Some(script) = message["installer"]["script"].as_str() {
            // The Node serving could not start the release's installer (updates.ts `startPlanned`): started here.
            if slot != Slot::Current {
                log::warn("a Node not serving asked for the installer to be started; not now");
                return;
            }
            let env: Vec<(String, String)> = message["installer"]["env"]
                .as_object()
                .map(|o| o.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string()))).collect())
                .unwrap_or_default();
            if self.os.run_installer(script, &env) {
                log::info("the station's installer started by the launcher");
            } else {
                log::warn("the station's installer not started by the launcher either");
            }
        } else if message["restartFront"] == true {
            if slot == Slot::Current {
                self.restart_front();
            } else {
                log::warn(&format!("a Node not serving (pid {}) asked for the front to start again; not now", self.node_mut(slot).map_or(0, |n| n.process.pid())));
            }
        } else if let Some(said) = message["drained"].as_str().filter(|_| slot == Slot::Current) {
            log::info(&format!("drained ({said})"));
            let _ = write_whole(&self.run.join("drained"), &format!("{said}\n"));
            self.drained_at = Some(self.os.now());
        } else {
            log::warn(&format!("Node said what the launcher does not know: {message}"));
        }
    }

    /// The new Node is ready: it serves, and the old one is told to hand over and go.
    fn hand_over(&mut self) {
        let Some((mut next, _, _)) = self.next.take() else { return };
        self.restart_at = None;
        next.handed = true;
        next.take_by = Some(self.os.now() + self.times.take);
        let old = self.current.replace(next);
        // The entrances leave the old one: they go to the new one where it serves already, else wait until it does
        // (it takes over once the old one has handed its sessions over).
        self.reroute(&old.as_ref().map(|n| n.served.clone()).unwrap_or_default());
        match old {
            Some(old) => {
                log::info(&format!("handing over from Node {} to Node {}", old.process.pid(), self.current.as_ref().map_or(0, |n| n.process.pid())));
                old.process.tell("handover");
                self.retiring = Some((old, self.os.now() + self.times.exit));
            }
            // The old one had crashed meanwhile: nothing to wait for.
            None => self.check_taken(),
        }
    }

    /// `op` (drain, hup) to the Node serving.
    pub fn ask(&mut self, op: &str) {
        match &self.current {
            Some(node) if self.stopping.is_none() => node.process.tell(op),
            _ => log::warn(&format!("asked to {op} with no Node serving; not now")),
        }
    }

    /// A handover: a new Node beside the one serving (the release at --app may be new), the one serving told to hand
    /// over once the new one is ready.
    pub fn start_next(&mut self) {
        if self.stopping.is_some() {
            return;
        }
        if self.next.is_some() || self.retiring.is_some() {
            log::warn("asked to hand over while a handover is under way; not again");
            return;
        }
        // An update brings a new launcher with the new release, and only a handover is the time to become it: else the
        // one started at the machine's start would run until its next start, and nothing it is changed in would come
        // (a handover's carrying the vault's grants did not: 2026-10-30).
        if let Some(node) = self.current.as_ref().filter(|n| n.taken)
            && self.os.renew(&node.process, &node.version, &node.served, node.heartbeats)
        {
            log::info("the release's launcher took this one's place and goes on with the handover");
            self.renewed = true;
            return;
        }
        match self.os.spawn() {
            Ok(process) => {
                log::info(&format!("handover: Node {} started beside the one serving", process.pid()));
                self.next = Some((Self::node(process), self.os.now() + self.times.ready, false));
            }
            Err(error) => self.handoff_failed(&format!("{} did not start: {error}", self.os.program())),
        }
    }

    /// The front (front.rs) ended and none runs in its place: a Node linked to it would try its socket for as long as it
    /// runs, and a station with one serving was out of reach until it was asked to hand over by hand (15 h on a Linux
    /// station, 2026-11-15). The Node started next binds the endpoint itself (spawn), so a handover to one mends it.
    /// One is started again after `front_retry` (it had ended as it started: a moment's failure, not for good), and the
    /// Node serving then hands over to one linked to it: given up once, a station stayed without one for good (each
    /// handover a new endpoint, its devices' connections lost) until it was started again by hand.
    pub fn front_gone(&mut self) {
        self.record("front_gone", serde_json::json!({ "retries": self.front_retries }), true);
        self.front_gone = true;
        self.probing = None;
        self.front_misses = 0;
        self.front_probe_at = None;
        self.schedule_front_retry();
        self.tick();
    }

    /// The Node serving asks for the front to be started anew (`{"restartFront":true}`: its page's restart, or the front
    /// held past its memory's limit, station/src/ops/self-memory.ts): one that answers its asks may still hold what went
    /// wrong (its endpoint's state, its memory), which only a new one lets go. The one there ended, another started, and
    /// the Node serving hands over to one linked to it (its own link went with the front). One that does not start is
    /// as one gone (`front_gone`): Nodes bind the endpoint themselves until one is started again. With none before, a
    /// handover alone.
    fn restart_front(&mut self) {
        if self.stopping.is_some() || self.next.is_some() || self.retiring.is_some() {
            log::warn("asked to start the front again while stopping or handing over; not now");
            return;
        }
        let had = self.os.has_front();
        let started = self.os.restart_front();
        self.probing = None;
        self.front_misses = 0;
        if started {
            log::info("the front started again: the Node serving hands over to one linked to it");
            self.front_gone = false;
            self.front_retry_at = None;
            self.front_retries = 0;
            self.front_probe_at = Some(self.os.now() + self.times.front_probe);
            self.start_next();
        } else if had {
            self.front_gone();
        } else {
            self.start_next();
        }
    }

    /// No front runs where the release has one (it did not start as the launcher did): one is started again after
    /// `front_retry`. No Node is linked to a front that is gone, so none hands over for it now (`front_gone` is for one
    /// that ended under the Nodes).
    pub fn schedule_front_retry(&mut self) {
        if self.front_retry_at.is_none() {
            let delay = self.front_retry_delay();
            log::info(&format!("the front is started again in {} s", delay.as_secs()));
            self.front_retry_at = Some(self.os.now() + delay);
        }
    }

    fn front_retry_delay(&self) -> Duration {
        self.times.front_retry.saturating_mul(1 << self.front_retries.min(16)).min(FRONT_RETRY_MOST.max(self.times.front_retry))
    }

    /// What the front answered ask `n` (`Os::probe_front`): whether it did, in time.
    #[cfg_attr(windows, allow(dead_code))]
    pub fn front_probed(&mut self, n: u64, answered: bool) {
        if self.probing.is_none_or(|(asked, _)| asked != n) {
            return;
        }
        self.probing = None;
        if answered {
            self.front_misses = 0;
            self.front_retries = 0;
        } else {
            self.front_missed();
        }
    }

    fn front_missed(&mut self) {
        self.front_misses += 1;
        if self.front_misses < FRONT_MISSES {
            log::warn(&format!("the front did not answer ({} in a row)", self.front_misses));
            return;
        }
        log::error(&format!("the front did not answer {FRONT_MISSES} times in a row ({} s apart): killed as hung", self.times.front_probe.as_secs()));
        self.record("front_hung_killed", serde_json::json!({ "misses": FRONT_MISSES, "probeMs": self.times.front_probe.as_millis() as u64 }), true);
        self.front_misses = 0;
        self.front_probe_at = None;
        self.os.kill_front();
    }

    /// Whether the Node serving is held to saying it is alive now, and by when it must have said it again.
    fn heartbeat_by(&self) -> Option<Instant> {
        if self.stopping.is_some() || self.next.is_some() {
            return None;
        }
        let node = self.current.as_ref().filter(|n| n.taken && !n.hung && !n.given_up)?;
        node.heartbeat_at.map(|at| at + self.times.heartbeat)
    }

    /// Whether a front may be started again now: none being started or stopped, no handover under way (it ends with a
    /// handover of its own), and the Node serving, if any, has taken over.
    fn front_retry_due(&self) -> Option<Instant> {
        let at = self.front_retry_at?;
        let calm = self.stopping.is_none() && self.next.is_none() && self.retiring.is_none() && !self.front_gone && self.current.as_ref().is_none_or(|n| n.taken);
        calm.then_some(at)
    }

    /// Asks every Node to stop; the launcher exits once none runs.
    pub fn stop(&mut self) {
        if self.stopping.is_some() {
            return;
        }
        self.restart_at = None;
        self.stopping = Some(self.os.now() + self.times.stop);
        if let Some(node) = &self.current {
            node.process.tell("stop");
        }
        if let Some((node, ..)) = &self.next {
            node.process.tell("stop");
        }
        // The one retiring is ending already (within its own limit).
    }

    /// Node `pid` ended (`how`: "exited with 1", "was ended by signal 9").
    pub fn ended(&mut self, pid: u32, how: &str) {
        match self.slot_of(pid) {
            Some(Slot::Current) => {
                let node = self.current.take().unwrap();
                // None serves now: connections wait for the next one (a restart, the one starting beside).
                self.reroute(&node.served);
                log::info(&format!("Node {pid} {how}"));
                if self.stopping.is_none() {
                    self.crashed(node, how);
                }
            }
            Some(Slot::Next) => {
                let (node, _, given_up) = self.next.take().unwrap();
                log::info(&format!("Node {pid} (starting beside) {how}"));
                if !given_up && self.stopping.is_none() {
                    self.handoff_failed(&format!("the new station {how} before it was ready"));
                }
                drop(node);
                if self.current.is_none() && self.stopping.is_none() && self.restart_at.is_none() {
                    self.schedule_restart();
                }
            }
            Some(Slot::Retiring) => {
                self.retiring = None;
                log::info(&format!("Node {pid} handed over and {how}"));
                self.check_taken();
            }
            None => {}
        }
    }

    /// Node `pid` ended as the OS logs off or shuts down (Windows): not a crash. Nothing is recorded or started again,
    /// and the launcher stops, the other Nodes too.
    #[cfg_attr(unix, allow(dead_code))]
    pub fn ended_on_shutdown(&mut self, pid: u32, how: &str) {
        match self.slot_of(pid) {
            Some(Slot::Current) => {
                let node = self.current.take().unwrap();
                self.reroute(&node.served);
                log::info(&format!("Node {pid} {how} (OS shutting down)"));
            }
            Some(Slot::Next) => {
                self.next = None;
                log::info(&format!("Node {pid} (starting beside) {how} (OS shutting down)"));
            }
            Some(Slot::Retiring) => {
                self.retiring = None;
                log::info(&format!("Node {pid} handed over and {how} (OS shutting down)"));
                self.check_taken();
            }
            None => {}
        }
        // (after the one ended is let go: it is not told to stop)
        self.stop();
    }

    /// The serving Node ended without being asked: started again after the backoff.
    fn crashed(&mut self, node: Node<O::Node>, how: &str) {
        log::warn(&format!("Node {} ended unexpectedly", node.process.pid()));
        // One killed as hung was recorded so already.
        if !node.hung {
            let mut fields = serde_json::json!({ "pid": node.process.pid(), "version": node.version, "how": how, "taken": node.taken, "failures": self.failures });
            if let Some(ready) = node.ready {
                fields["uptimeMs"] = (self.os.now().saturating_duration_since(ready).as_millis() as u64).into();
            }
            self.record("node_crashed", fields, true);
        }
        // A handover under way brings the next one up.
        if self.next.is_some() {
            return;
        }
        // One that never took over did not start (counted towards giving up), ready or not.
        match node.ready.filter(|_| node.taken) {
            Some(at) => {
                self.failures = 0;
                if self.os.now().saturating_duration_since(at) >= self.times.stable {
                    self.backoff_step = 0;
                }
                self.schedule_restart();
            }
            None => self.failed_start(),
        }
    }

    /// What is due by now: a handover given up, a Node killed, a restart, the parent gone.
    pub fn tick(&mut self) {
        let now = self.os.now();
        if let Some((node, by, given_up)) = &mut self.next
            && !*given_up
            && now >= *by
        {
            *given_up = true;
            let pid = node.process.pid();
            self.os.kill(&mut node.process);
            let why = format!("the new station (pid {pid}) was not ready within {} s", self.times.ready.as_secs_f32());
            self.handoff_failed(&why);
        }
        if self.stopping.is_none()
            && let Some(by) = self.current.as_ref().and_then(|n| n.take_by)
            && now >= by
        {
            self.take_failed(&format!("not within {} s", self.times.take.as_secs_f32()));
        }
        if let Some((node, by)) = &mut self.retiring
            && now >= *by
        {
            log::warn(&format!("Node {} did not exit within {} s of handing over; killed", node.process.pid(), self.times.exit.as_secs_f32()));
            *by = now + Duration::from_secs(3600);
            self.os.kill(&mut node.process);
            let fields = serde_json::json!({ "pid": node.process.pid(), "version": node.version, "exitTimeoutMs": self.times.exit.as_millis() as u64 });
            self.record("retiring_killed", fields, false);
        }
        if let Some(by) = self.stopping
            && now >= by
        {
            let stop = self.times.stop.as_secs_f32();
            let Lifecycle { os, current, next, retiring, .. } = self;
            for node in [current.as_mut(), next.as_mut().map(|n| &mut n.0), retiring.as_mut().map(|n| &mut n.0)].into_iter().flatten() {
                log::warn(&format!("Node {} did not stop within {stop} s; killed", node.process.pid()));
                os.kill(&mut node.process);
            }
            self.stopping = Some(now + Duration::from_secs(3600));
        }
        if self.restart_at.is_some_and(|at| now >= at) && self.stopping.is_none() {
            self.start();
        }
        if self.front_gone && self.stopping.is_none() && self.next.is_none() && self.retiring.is_none() {
            self.front_gone = false;
            // None serving: the one started next binds the endpoint itself.
            if self.current.is_some() {
                log::warn("the front is gone: the Node serving hands over to one that binds the station's endpoint itself");
                self.start_next();
            }
        }
        if let Some(by) = self.heartbeat_by()
            && now >= by
            && self.current.is_some()
        {
            let (pid, version, ready) = {
                let node = self.current.as_mut().unwrap();
                node.hung = true;
                (node.process.pid(), node.version.clone(), node.ready)
            };
            // Collect bounded diagnostics before SIGKILL (on macOS this runs up to ~3 s); `node.hung = true` is
            // already set above, so `heartbeat_by()` will not fire a second time.
            let diag = {
                let Lifecycle { os, current, .. } = self;
                os.diagnose_hung(&current.as_ref().unwrap().process)
            };
            let mut summary = String::new();
            if let Some(state) = diag.get("procState").and_then(Value::as_str) {
                summary.push_str(&format!(" state={state}"));
            }
            if let Some(wchan) = diag.get("wchan").and_then(Value::as_str) {
                summary.push_str(&format!(" wchan={wchan}"));
            }
            log::error(&format!("Node {pid} said nothing for {} s (its main thread held or hung){summary}; killed, and one started again", self.times.heartbeat.as_secs_f32()));
            let mut fields = serde_json::json!({ "pid": pid, "version": version, "heartbeatTimeoutMs": self.times.heartbeat.as_millis() as u64 });
            if let Some(ready) = ready {
                fields["uptimeMs"] = (now.saturating_duration_since(ready).as_millis() as u64).into();
            }
            if let Some(obj) = fields.as_object_mut() {
                obj.extend(diag);
            }
            self.record("node_hung_killed", fields, true);
            // Not asked to hand over: a thread that does not run would not hear it. Its end is a crash's (`crashed`).
            let Lifecycle { os, current, .. } = self;
            if let Some(node) = current.as_mut() {
                os.kill(&mut node.process);
            }
        }
        if self.front_retry_due().is_some_and(|at| now >= at) {
            self.front_retry_at = None;
            // (each try further apart, until one that started answers its asks: `front_probed`)
            self.front_retries += 1;
            if self.os.has_front() {
                // one there already (started with a Node's restart meanwhile)
            } else if self.os.front_again() {
                log::info("the front listens again");
                // The Node serving binds the endpoint itself: it hands over to one linked to the front (spawn).
                if self.current.is_some() {
                    log::info("the Node serving hands over to one linked to the front");
                    self.start_next();
                }
            } else {
                let delay = self.front_retry_delay();
                log::warn(&format!("the front did not start again; another try in {} s", delay.as_secs()));
                self.front_retry_at = Some(now + delay);
            }
        }
        if self.stopping.is_none() && self.os.has_front() {
            if let Some((_, by)) = self.probing
                && now >= by
            {
                self.probing = None;
                self.front_missed();
            }
            match self.front_probe_at {
                None => self.front_probe_at = Some(now + self.times.front_probe),
                Some(at) if now >= at && self.probing.is_none() => {
                    self.probes += 1;
                    self.probing = Some((self.probes, now + self.times.front_probe));
                    self.front_probe_at = Some(now + self.times.front_probe);
                    self.os.probe_front(self.probes);
                }
                _ => {}
            }
        } else if !self.os.has_front() {
            self.front_probe_at = None;
            self.probing = None;
            self.front_misses = 0;
        }
        if let Some(at) = self.drained_at
            && now >= at + self.times.drained
        {
            log::warn("drained but not stopped; run/drained taken back");
            let _ = std::fs::remove_file(self.run.join("drained"));
            self.drained_at = None;
        }
        if let Some(at) = self.parent_at
            && now >= at
        {
            self.parent_at = Some(now + self.times.parent);
            if self.os.parent_gone() {
                log::info("parent ended; stopping");
                self.parent_at = None;
                self.stop();
            }
        }
    }

    /// When something is due next (what tick does).
    pub fn next_due(&self) -> Option<Instant> {
        [
            self.next.as_ref().filter(|n| !n.2).map(|n| n.1),
            self.retiring.as_ref().map(|n| n.1),
            self.current.as_ref().and_then(|n| n.take_by).filter(|_| self.stopping.is_none()),
            self.stopping,
            self.restart_at,
            self.drained_at.map(|at| at + self.times.drained),
            self.parent_at,
            self.heartbeat_by(),
            self.front_retry_due(),
            self.front_probe_at.filter(|_| self.stopping.is_none() && self.probing.is_none()),
            self.probing.map(|(_, by)| by).filter(|_| self.stopping.is_none()),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    pub fn running(&self) -> bool {
        self.current.is_some() || self.next.is_some() || self.retiring.is_some()
    }

    /// The launcher's exit, once it has stopped and nothing runs.
    pub fn finished(&self) -> Option<i32> {
        (self.stopping.is_some() && !self.running()).then_some(self.exit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    use serde_json::json;

    /// A test's Node: a pid (from 101 on) and what it was told.
    struct FakeNode {
        pid: u32,
        told: Rc<RefCell<Vec<String>>>,
    }

    impl Process for FakeNode {
        fn pid(&self) -> u32 {
            self.pid
        }
        fn send(&self, line: &Value) {
            let op = line["op"].as_str().unwrap_or_default();
            let told = if op == "carried" { format!("carried {}", line["carried"]) } else { op.to_string() };
            self.told.borrow_mut().push(told);
        }
    }

    /// The test's processes and clock.
    struct Fake {
        dir: PathBuf,
        now: Instant,
        pid: u32,
        told: Vec<(u32, Rc<RefCell<Vec<String>>>)>,
        killed: Vec<u32>,
        parent_gone: bool,
        /// Where the entrances were told to go, in turn.
        routes: Vec<(String, Option<u16>)>,
        /// The Nodes serving when the launcher was asked to become the release's (with their versions and ports).
        renewed: Vec<(u32, String, Vec<(String, u16)>)>,
        takes_place: bool,
        /// Whether a front runs; whether the next ones started listen (none said: they do); the asks of it; its kills.
        front: bool,
        front_starts: Vec<bool>,
        started_fronts: u32,
        probed: Vec<u64>,
        front_killed: u32,
        /// The fronts ended and started anew as a Node asked (`restart_front`).
        restarted_fronts: u32,
        /// The installers started as a Node asked (`run_installer`): the script and what it was told.
        installers: Vec<(String, Vec<(String, String)>)>,
        /// Diagnostics returned by `diagnose_hung`, and `(pid, called_before_kill)` calls recorded.
        hung_diag: serde_json::Map<String, Value>,
        diagnosed_before_kill: Vec<(u32, bool)>,
    }

    impl Os for Fake {
        fn route(&mut self, name: &str, port: Option<u16>) {
            self.routes.push((name.to_string(), port));
        }
        type Node = FakeNode;
        fn now(&self) -> Instant {
            self.now
        }
        fn spawn(&mut self) -> Result<FakeNode> {
            self.pid += 1;
            let told = Rc::new(RefCell::new(vec![]));
            self.told.push((self.pid, told.clone()));
            Ok(FakeNode { pid: self.pid, told })
        }
        fn kill(&mut self, node: &mut FakeNode) {
            self.killed.push(node.pid);
        }
        fn parent_gone(&mut self) -> bool {
            self.parent_gone
        }
        fn program(&self) -> String {
            "node".into()
        }
        fn renew(&mut self, serving: &FakeNode, version: &str, served: &[(String, u16)], _heartbeats: bool) -> bool {
            self.renewed.push((serving.pid, version.to_string(), served.to_vec()));
            // (Windows': the release's launcher took this one's place)
            self.takes_place
        }
        fn has_front(&self) -> bool {
            self.front
        }
        fn front_again(&mut self) -> bool {
            self.started_fronts += 1;
            self.front = if self.front_starts.is_empty() { true } else { self.front_starts.remove(0) };
            self.front
        }
        fn probe_front(&mut self, n: u64) {
            self.probed.push(n);
        }
        fn kill_front(&mut self) {
            self.front_killed += 1;
        }
        fn restart_front(&mut self) -> bool {
            self.restarted_fronts += 1;
            self.front = if self.front_starts.is_empty() { true } else { self.front_starts.remove(0) };
            self.front
        }
        fn run_installer(&mut self, script: &str, env: &[(String, String)]) -> bool {
            self.installers.push((script.to_string(), env.to_vec()));
            true
        }
        fn diagnose_hung(&mut self, node: &FakeNode) -> serde_json::Map<String, Value> {
            self.diagnosed_before_kill.push((node.pid, !self.killed.contains(&node.pid)));
            self.hung_diag.clone()
        }
    }

    impl Drop for Fake {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    const MS: Duration = Duration::from_millis(1);
    const EXITED_1: &str = "exited with 1";
    const EXITED_0: &str = "exited with 0";
    const KILLED: &str = "was ended by signal 9";

    fn s(secs: u64) -> Duration {
        Duration::from_secs(secs)
    }

    /// A launcher with its first Node started.
    fn station(name: &str, with_parent: bool) -> Lifecycle<Fake> {
        let data = std::env::temp_dir().join(format!("launcher-lifecycle-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&data);
        let run = data.join("run");
        std::fs::create_dir_all(&run).unwrap();
        let fake = Fake { dir: data, now: Instant::now(), pid: 100, told: vec![], killed: vec![], parent_gone: false, routes: vec![], renewed: vec![], takes_place: false, front: false, front_starts: vec![], started_fronts: 0, probed: vec![], front_killed: 0, restarted_fronts: 0, installers: vec![], hung_diag: serde_json::Map::new(), diagnosed_before_kill: vec![] };
        let times = Times { ready: s(60), exit: s(30), stop: s(30), backoff: s(1), backoff_max: s(4), stable: s(60), parent: s(2), drained: s(300), take: s(90), rollback: s(10), front: s(10), heartbeat: s(90), front_retry: s(300), front_probe: s(30) };
        let mut station = Lifecycle::new(fake, times, run, with_parent);
        station.start();
        station
    }

    fn ready(version: &str) -> Value {
        json!({"ready": true, "version": version})
    }

    impl Lifecycle<Fake> {
        /// The clock moved on by `by`, and what is due by then done.
        fn pass(&mut self, by: Duration) {
            self.os.now += by;
            self.tick();
        }

        /// The Node in `slot` ready and serving both entrances (mcp on `base` + 1, admin on `base` + 2).
        fn up(&mut self, slot: Slot, version: &str, base: u16) {
            self.said(slot, ready(version));
            self.serves(slot, base);
        }

        fn serves(&mut self, slot: Slot, base: u16) {
            self.said(slot, json!({"serving": "admin", "port": base + 2}));
            self.said(slot, json!({"serving": "mcp", "port": base + 1}));
        }

        /// The Node started last.
        fn last(&self) -> u32 {
            self.os.pid
        }

        fn serving(&self) -> u32 {
            self.current.as_ref().unwrap().process.pid
        }

        /// The ops told to Node `pid` since last asked.
        fn told(&mut self, pid: u32) -> Vec<String> {
            let (_, told) = self.os.told.iter().find(|(p, _)| *p == pid).unwrap();
            std::mem::take(&mut *told.borrow_mut())
        }

        fn file(&self, name: &str) -> Option<String> {
            std::fs::read_to_string(self.run.join(name)).ok()
        }

        fn station_json(&self) -> Value {
            serde_json::from_str(&self.file("station.json").unwrap()).unwrap()
        }
    }

    #[test]
    fn a_handover_lets_the_old_node_go_once_the_new_one_is_ready() {
        let mut station = station("handover", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        assert_eq!(station.station_json()["version"], "0.1.0");
        assert_eq!(station.station_json()["pid"], std::process::id());
        station.start_next();
        let new = station.last();
        assert_ne!(new, old);
        // Asked again meanwhile: not a second one.
        station.start_next();
        assert_eq!(station.last(), new);
        assert!(station.told(old).is_empty(), "the old one serves until the new one is ready");
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(old), ["handover"]);
        assert_eq!(station.serving(), new);
        // The old one not gone within its time: killed. station.json says the new start once it is gone.
        station.pass(s(30) - MS);
        assert!(station.os.killed.is_empty());
        assert_eq!(station.station_json()["version"], "0.1.0");
        station.pass(MS);
        assert_eq!(station.os.killed, [old]);
        station.ended(old, KILLED);
        // Gone; the new one is ready, not yet serving: not handed over yet (an installer reads station.json for it).
        assert_eq!(station.station_json()["version"], "0.1.0");
        station.said(Slot::Current, serving("admin", 6002));
        assert_eq!(station.station_json()["version"], "0.1.0", "the agents' door not open yet");
        station.said(Slot::Current, serving("mcp", 6001));
        assert_eq!(station.station_json()["version"], "0.2.0");
        assert_eq!(station.station_json()["pid"], std::process::id());
        assert!(station.file("handoff-failed").is_none());
        assert!(station.told(new).is_empty() && station.stopping.is_none());
        // Taken over: no deadline is left.
        station.pass(s(3600));
        assert_eq!(station.os.killed, [old]);
        assert_eq!(station.serving(), new);
    }

    #[test]
    fn the_front_gone_the_node_serving_hands_over_once_no_handover_is_under_way() {
        let mut station = station("frontgone", false);
        let first = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.front_gone();
        let second = station.last();
        assert_ne!(second, first, "a handover at once");
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(first), ["handover"]);
        station.ended(first, EXITED_0);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.serving(), second);
        // Gone again during a handover (its next Node started linked to it): the one that took over hands over too,
        // once the one before it is gone.
        station.front_gone();
        let third = station.last();
        assert_ne!(third, second);
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(second), ["handover"]);
        station.front_gone();
        assert_eq!(station.last(), third, "not while the one before is retiring");
        station.ended(second, EXITED_0);
        station.tick();
        let fourth = station.last();
        assert_ne!(fourth, third, "then the one serving hands over");
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(third), ["handover"]);
        station.ended(third, EXITED_0);
        station.pass(s(3600));
        assert_eq!(station.last(), fourth, "once");
    }

    #[test]
    fn the_node_serving_that_could_not_start_the_installer_has_the_launcher_start_it_and_no_other_node_does() {
        let mut station = station("installer", false);
        station.up(Slot::Current, "0.1.0", 5000);
        station.said(Slot::Current, json!({"installer": {"script": "/app/bin/install.zh.sh", "env": {"STILLFAIL_DATA": "/d", "N": 1}}}));
        assert_eq!(station.os.installers, [("/app/bin/install.zh.sh".to_string(), vec![("STILLFAIL_DATA".to_string(), "/d".to_string())])]);
        station.said(Slot::Next, json!({"installer": {"script": "/x", "env": {}}}));
        assert_eq!(station.os.installers.len(), 1, "only the Node serving updates the station");
    }

    #[test]
    fn the_node_serving_asking_for_the_front_anew_has_it_ended_another_started_and_hands_over_to_one_linked_to_it() {
        let mut station = station("restartfront", false);
        station.os.front = true;
        let first = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        // an ask of the old front missed, another out: counted afresh for the new one
        station.tick();
        station.pass(s(30));
        assert_eq!(station.os.probed, [1]);
        station.front_probed(1, false);
        assert_eq!(station.front_misses, 1);
        station.pass(s(30));
        assert!(station.probing.is_some());
        station.said(Slot::Current, json!({"restartFront": true}));
        assert_eq!(station.os.restarted_fronts, 1);
        assert!(station.probing.is_none() && station.front_misses == 0);
        let second = station.last();
        assert_ne!(second, first, "a handover at once, to a Node linked to the new front");
        // asked again while it hands over: not now
        station.said(Slot::Current, json!({"restartFront": true}));
        assert_eq!(station.os.restarted_fronts, 1);
        assert_eq!(station.last(), second);
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(first), ["handover"]);
        station.ended(first, EXITED_0);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.serving(), second);
        assert!(station.file("handoff-failed").is_none());
        // the new front asked on as the old one was, from its start
        station.pass(s(30));
        assert_eq!(station.os.probed, [1, 2, 3]);
        // not from a Node that is not the one serving
        station.start_next();
        let third = station.last();
        station.said(Slot::Next, json!({"restartFront": true}));
        assert_eq!(station.os.restarted_fronts, 1);
        station.said(Slot::Next, ready("0.1.0"));
        station.ended(second, EXITED_0);
        station.serves(Slot::Current, 7000);
        // one that does not start is as one gone: the one serving hands over to one that binds the endpoint itself, and
        // one is started again later
        station.os.front_starts = vec![false];
        station.said(Slot::Current, json!({"restartFront": true}));
        assert_eq!(station.os.restarted_fronts, 2);
        assert!(!station.os.front);
        let fourth = station.last();
        assert_ne!(fourth, third);
        assert!(station.front_retry_at.is_some());
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(third), ["handover"]);
        station.ended(third, EXITED_0);
        station.serves(Slot::Current, 8000);
        station.pass(s(300));
        assert_eq!(station.os.started_fronts, 1, "started again after front_retry");
        let fifth = station.last();
        assert_ne!(fifth, fourth, "and the one serving hands over to one linked to it");
    }

    #[test]
    fn asked_for_the_front_anew_where_none_runs_the_node_serving_hands_over() {
        let mut station = station("restartnofront", false);
        let first = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        // none starts either (a release without the program): a handover alone, no front tried again later
        station.os.front_starts = vec![false];
        station.said(Slot::Current, json!({"restartFront": true}));
        assert_eq!(station.os.restarted_fronts, 1);
        let second = station.last();
        assert_ne!(second, first);
        assert!(station.front_retry_at.is_none() && !station.front_gone);
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(first), ["handover"]);
        // stopping: not now
        station.ended(first, EXITED_0);
        station.serves(Slot::Current, 6000);
        station.stop();
        station.said(Slot::Current, json!({"restartFront": true}));
        assert_eq!(station.os.restarted_fronts, 1);
    }

    #[test]
    fn what_the_old_node_holds_in_memory_goes_to_the_new_one() {
        let mut station = station("carry", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        // Not handing over: given to nobody.
        station.said(Slot::Current, json!({"carry": {"vault": 1}}));
        assert!(station.told(old).is_empty());
        station.start_next();
        let new = station.last();
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(old), ["handover"]);
        // Told to hand over, the old one gives what it holds, and it ends: the new one has it.
        station.heard(old, vec![json!({"carry": {"vault": {"held": [1]}}})]);
        station.ended(old, EXITED_0);
        assert_eq!(station.told(new), [r#"carried {"vault":{"held":[1]}}"#]);
    }

    #[test]
    fn a_handover_first_lets_the_launcher_become_the_release_s_with_the_node_serving() {
        let mut station = station("renew", false);
        let node = station.last();
        // Not taken over yet: there is nothing a launcher after this one could go on with.
        station.said(Slot::Current, ready("0.1.0"));
        station.start_next();
        assert!(station.os.renewed.is_empty());
        station.ended(station.last(), EXITED_1);
        station.serves(Slot::Current, 5000);
        station.start_next();
        assert_eq!(station.os.renewed, [(node, "0.1.0".to_string(), vec![("admin".to_string(), 5002), ("mcp".to_string(), 5001)])]);
        // Not renewed (none new in the release): the handover goes on here.
        assert_ne!(station.last(), node);
    }

    #[test]
    fn a_launcher_whose_place_the_release_s_takes_in_a_process_of_its_own_starts_nothing_more() {
        let mut station = station("renewed", false);
        let node = station.last();
        station.said(Slot::Current, ready("0.1.0"));
        station.serves(Slot::Current, 5000);
        station.os.takes_place = true;
        station.start_next();
        // (Windows: the release's launcher goes on with the handover; this one starts no Node beside the one serving)
        assert!(station.renewed());
        assert_eq!(station.last(), node);
        assert!(station.next.is_none());
    }

    #[test]
    fn a_launcher_that_took_another_s_place_says_so_in_station_json() {
        let mut station = station("renewedfrom", false);
        station.renewed_from(4242);
        station.up(Slot::Current, "0.1.0", 5000);
        assert_eq!(station.station_json()["renewedFrom"], 4242);
        assert_eq!(station.station_json()["pid"], std::process::id());
    }

    #[test]
    fn a_node_taken_up_from_the_launcher_before_serves_and_hands_over_as_one_started_here() {
        let mut station = station("adopt", false);
        // This launcher's own first Node aside: the one a launcher before it in this process left serving.
        let own = station.last();
        station.current = None;
        station.os.killed.clear();
        let told = Rc::new(RefCell::new(vec![]));
        station.os.told.push((50, told.clone()));
        std::fs::write(station.run.join("station.json"), "before").unwrap();
        station.adopt(FakeNode { pid: 50, told }, "0.1.0".into(), vec![("admin".into(), 5002), ("mcp".into(), 5001)], false);
        assert_eq!(routes(&mut station), [to("admin", Some(5002)), to("mcp", Some(5001))]);
        assert_eq!(station.file("station.json").as_deref(), Some("before"), "said by the launcher before");
        assert_eq!(station.serving(), 50);
        station.start_next();
        let new = station.last();
        assert_ne!(new, own);
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(50), ["handover"]);
        station.heard(50, vec![json!({"carry": {"vault": 1}})]);
        station.ended(50, EXITED_0);
        assert_eq!(station.told(new), [r#"carried {"vault":1}"#]);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.station_json()["version"], "0.2.0");
        // Taken over by then: no deadline of its own ran out meanwhile.
        station.pass(s(3600));
        assert!(station.os.killed.is_empty());
    }

    #[test]
    fn a_new_node_ready_and_serving_in_one_read_takes_over() {
        let mut station = station("oneread", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        // Its ready and where it serves come in one read: the lines after ready are the serving one's.
        station.heard(new, vec![ready("0.2.0"), serving("admin", 6002), serving("mcp", 6001)]);
        assert_eq!(station.told(old), ["handover"]);
        station.ended(old, EXITED_0);
        assert_eq!(station.station_json()["version"], "0.2.0");
        assert_eq!(station.serving(), new);
        station.pass(s(3600));
        assert!(station.os.killed.is_empty());
    }

    #[test]
    fn a_new_node_that_does_not_take_over_is_ended_and_one_started_again_after_the_rollback_wait() {
        let mut station = station("nottaken", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        let first = station.file("station.json");
        station.start_next();
        let new = station.last();
        // Ready, the old one hands over and goes, the new one says its loopback port; its agents' side never comes up.
        station.said(Slot::Next, ready("0.2.0"));
        station.said(Slot::Current, serving("admin", 6002));
        station.ended(old, EXITED_0);
        station.pass(s(90) - MS);
        assert!(station.os.killed.is_empty() && station.file("handoff-failed").is_none());
        assert_eq!(station.file("station.json"), first, "not said handed over");
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("did not take over"));
        station.ended(new, KILLED);
        // Started again (on whatever release is at --app then), not before the installer could put the old one back.
        station.pass(s(10) - MS);
        assert_eq!(station.last(), new);
        station.pass(MS);
        let again = station.last();
        assert_ne!(again, new);
        // Said afresh once it is up (startedAt is the wall clock's, the same millisecond as `first` on a fast machine:
        // what was there is told apart by what is put there now, not by the time).
        std::fs::write(station.run.join("station.json"), "before").unwrap();
        station.up(Slot::Current, "0.1.0", 7000);
        assert_ne!(station.file("station.json").as_deref(), Some("before"));
        assert_eq!(station.station_json()["version"], "0.1.0");
        assert_eq!(station.serving(), again);
    }

    #[test]
    fn a_node_that_says_it_is_still_taking_over_gets_its_time_again_until_it_goes_silent() {
        let mut station = station("taking", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        station.said(Slot::Next, ready("0.2.0"));
        station.ended(old, EXITED_0);
        for _ in 0..3 {
            station.pass(s(90) - MS);
            station.said(Slot::Current, json!({"taking": true}));
        }
        assert!(station.os.killed.is_empty() && station.file("handoff-failed").is_none());
        // Silent for the whole of it: hung.
        station.pass(s(90) - MS);
        assert!(station.os.killed.is_empty());
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("did not take over"));
        // Late, as it goes: it does not bring back a limit.
        station.said(Slot::Current, json!({"taking": true}));
        station.pass(s(90));
        assert_eq!(station.os.killed, [new]);
    }

    #[test]
    fn a_new_node_that_says_it_failed_to_take_over_is_ended_at_once() {
        let mut station = station("failedtake", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        station.said(Slot::Next, ready("0.2.0"));
        station.ended(old, EXITED_0);
        station.said(Slot::Current, json!({"failed": "the agents' side did not start: boom"}));
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("boom"));
        // Said once more as it goes: nothing more.
        station.said(Slot::Current, json!({"failed": "again"}));
        assert_eq!(station.os.killed, [new]);
    }

    #[test]
    fn a_node_that_never_takes_over_after_a_plain_start_is_started_again_and_counts_towards_giving_up() {
        let mut station = station("nottaken-start", false);
        for start in 1..=5 {
            let node = station.last();
            station.said(Slot::Current, ready("0.1.0"));
            station.pass(s(90));
            assert_eq!(station.os.killed.last(), Some(&node));
            station.ended(node, KILLED);
            if start < 5 {
                station.pass(s(4));
            }
        }
        assert!(station.file("handoff-failed").is_none(), "no handover's");
        assert_eq!(station.finished(), Some(1));
    }

    #[test]
    fn a_new_node_never_ready_is_given_up_and_the_old_one_serves_on() {
        let mut station = station("handfail", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        let first = station.file("station.json");
        station.start_next();
        let new = station.last();
        station.pass(s(60) - MS);
        assert!(station.os.killed.is_empty() && station.file("handoff-failed").is_none());
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("not ready"));
        // Ready too late: not taken.
        station.said(Slot::Next, ready("0.2.0"));
        station.ended(new, KILLED);
        assert_eq!(station.serving(), old);
        assert!(station.told(old).is_empty());
        assert_eq!(station.file("station.json"), first);
        assert!(station.restart_at.is_none());
        // A later handover works.
        station.start_next();
        let again = station.last();
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(old), ["handover"]);
        station.ended(old, EXITED_0);
        assert_eq!(station.serving(), again);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.station_json()["version"], "0.2.0");
    }

    #[test]
    fn a_new_node_that_ends_before_it_is_ready_fails_the_handover() {
        let mut station = station("handend", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        station.ended(station.last(), EXITED_1);
        assert!(station.file("handoff-failed").unwrap().contains("exited with 1 before it was ready"));
        assert_eq!(station.serving(), old);
        assert!(station.told(old).is_empty() && station.os.killed.is_empty());
    }

    #[test]
    fn a_stop_during_a_handover_stops_both_and_kills_what_does_not_stop_in_time() {
        let mut station = station("stopboth", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        station.stop();
        assert_eq!(station.told(old), ["stop"]);
        assert_eq!(station.told(new), ["stop"]);
        station.pass(s(30) - MS);
        assert!(station.os.killed.is_empty());
        station.ended(old, EXITED_0);
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        station.ended(new, KILLED);
        assert_eq!(station.finished(), Some(0));
        // Nothing is started again.
        station.pass(s(3600));
        assert_eq!(station.last(), new);
    }

    #[test]
    fn a_crashed_node_is_started_again_after_a_backoff_that_doubles() {
        let mut station = station("crash", false);
        // Each one crashing as soon as it is ready: again after 1, 2, 4, then 4 s (backoff_max). Being ready does not
        // take the backoff back to the first: only serving `stable` does.
        for expected in [1000, 2000, 4000, 4000] {
            let node = station.last();
            station.up(Slot::Current, "0.1.0", 5000);
            station.ended(node, EXITED_1);
            station.pass(Duration::from_millis(expected) - MS);
            assert_eq!(station.last(), node, "not again before {expected} ms");
            station.pass(MS);
            assert_ne!(station.last(), node, "again after {expected} ms");
        }
        // One that served for `stable` before it crashed: back to the first backoff.
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.pass(s(60));
        station.ended(node, EXITED_1);
        station.pass(s(1) - MS);
        assert_eq!(station.last(), node);
        station.pass(MS);
        assert_ne!(station.last(), node);
        assert!(station.stopping.is_none());
    }

    #[test]
    fn five_starts_in_a_row_that_end_before_ready_and_it_gives_up() {
        let mut station = station("giveup", false);
        for start in 1..=5 {
            station.ended(station.last(), EXITED_1);
            if start < 5 {
                station.pass(s(4));
            }
        }
        assert_eq!(station.os.told.len(), 5);
        assert_eq!(station.finished(), Some(1));
        station.pass(s(3600));
        assert_eq!(station.os.told.len(), 5);
    }

    #[test]
    fn with_parent_it_stops_once_the_parent_is_gone() {
        let mut station = station("parent", true);
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        for _ in 0..30 {
            station.pass(s(2));
        }
        assert!(station.stopping.is_none() && station.told(node).is_empty(), "still there while the parent is");
        // Gone: seen at the next look.
        station.os.parent_gone = true;
        station.pass(s(2) - MS);
        assert!(station.stopping.is_none());
        station.pass(MS);
        assert!(station.stopping.is_some());
        assert_eq!(station.told(node), ["stop"]);
        station.ended(node, EXITED_0);
        assert_eq!(station.finished(), Some(0));
    }

    fn serving(name: &str, port: u16) -> Value {
        json!({"serving": name, "port": port})
    }

    fn routes(station: &mut Lifecycle<Fake>) -> Vec<(String, Option<u16>)> {
        std::mem::take(&mut station.os.routes)
    }

    fn to(name: &str, port: Option<u16>) -> (String, Option<u16>) {
        (name.to_string(), port)
    }

    #[test]
    fn the_entrances_go_to_a_node_only_once_it_has_taken_over() {
        let mut station = station("entrances", false);
        station.said(Slot::Current, serving("admin", 5002));
        station.said(Slot::Current, ready("0.1.0"));
        station.said(Slot::Current, serving("mcp", 5001));
        assert_eq!(routes(&mut station), [to("admin", Some(5002)), to("mcp", Some(5001))]);
        // A handover: the new one says where it listens before it has taken over (its loopback port is up at once).
        station.start_next();
        let new = station.last();
        station.said(Slot::Next, serving("admin", 6002));
        assert!(routes(&mut station).is_empty(), "not the one serving yet");
        // Ready: it serves, the old one hands over; the agents' door is the new one's once it has taken the sessions
        // up, so until then connections to it wait (none goes to a Node that has not taken over).
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(routes(&mut station), [to("admin", Some(6002)), to("mcp", None)]);
        station.said(Slot::Retiring, serving("mcp", 5001));
        assert!(routes(&mut station).is_empty(), "the one handing over is not served to again");
        station.said(Slot::Current, serving("mcp", 6001));
        assert_eq!(routes(&mut station), [to("mcp", Some(6001))]);
        // It crashes: connections wait for the one started again, which serves where it says.
        station.ended(new, EXITED_1);
        assert_eq!(routes(&mut station), [to("admin", None), to("mcp", None)]);
        station.pass(s(1));
        station.said(Slot::Current, serving("mcp", 7001));
        assert_eq!(routes(&mut station), [to("mcp", Some(7001))]);
    }

    #[test]
    fn a_handover_given_up_leaves_the_entrances_with_the_old_node() {
        let mut station = station("entrances-kept", false);
        station.said(Slot::Current, ready("0.1.0"));
        station.said(Slot::Current, serving("mcp", 5001));
        routes(&mut station);
        station.start_next();
        station.said(Slot::Next, serving("mcp", 6001));
        station.pass(s(60));
        assert!(station.file("handoff-failed").is_some());
        assert!(routes(&mut station).is_empty(), "the old one serves on, its entrances its");
    }

    #[test]
    fn drain_and_hup_go_to_node_and_drained_is_taken_back_when_nobody_stops_it() {
        let mut station = station("drain", false);
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.ask("drain");
        station.ask("hup");
        assert_eq!(station.told(node), ["drain", "hup"]);
        station.said(Slot::Current, json!({"drained": "idle"}));
        assert_eq!(station.file("drained").as_deref(), Some("idle\n"));
        station.pass(s(300) - MS);
        assert!(station.file("drained").is_some());
        station.pass(MS);
        assert!(station.file("drained").is_none());
        assert!(station.stopping.is_none() && station.told(node).is_empty());
    }
    fn heartbeat() -> Value {
        json!({"heartbeat": true})
    }

    #[test]
    fn a_node_that_says_it_is_alive_and_then_says_nothing_is_killed_and_started_again() {
        let mut station = station("hung", false);
        let node = station.last();
        // It says it is alive before it has taken over (its loop runs from its start): that time is `take`'s.
        station.said(Slot::Current, heartbeat());
        station.said(Slot::Current, ready("0.1.0"));
        station.pass(s(80));
        station.serves(Slot::Current, 5000);
        // Held to it from taking over: each word gives it its time again.
        for _ in 0..5 {
            station.pass(s(90) - MS);
            station.said(Slot::Current, heartbeat());
        }
        assert!(station.os.killed.is_empty());
        // Silent for the whole of it: hung (its thread held: it would not hear a handover), killed.
        station.pass(s(90) - MS);
        assert!(station.os.killed.is_empty());
        assert_eq!(station.next_due(), Some(station.os.now + MS), "woken for it");
        station.pass(MS);
        assert_eq!(station.os.killed, [node]);
        assert!(station.told(node).is_empty(), "not asked anything");
        // Killed once, however long its end takes to be seen.
        station.pass(s(3600));
        assert_eq!(station.os.killed, [node]);
        station.ended(node, KILLED);
        // Started again as after a crash of one that served: no handover's failure, the first backoff.
        assert!(station.file("handoff-failed").is_none());
        station.pass(s(1));
        let again = station.last();
        assert_ne!(again, node);
        station.said(Slot::Current, heartbeat());
        station.up(Slot::Current, "0.1.0", 6000);
        assert_eq!(station.serving(), again);
        assert!(station.stopping.is_none());
    }

    #[test]
    fn a_node_that_never_says_it_is_alive_is_never_held_to_it() {
        // A release from before `--launcher-heartbeat` (an older one rolled back to, one taken up from the launcher
        // before): nothing to go by.
        let mut station = station("noheartbeat", false);
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.pass(s(3600 * 24));
        assert!(station.os.killed.is_empty());
        assert_eq!(station.serving(), node);
        assert_eq!(station.next_due(), None, "nothing to wake for");
    }

    #[test]
    fn a_node_taken_up_is_held_to_its_word_as_the_launcher_before_heard_it() {
        for heartbeats in [false, true] {
            let mut station = station(&format!("adoptbeat-{heartbeats}"), false);
            station.current = None;
            let told = Rc::new(RefCell::new(vec![]));
            station.os.told.push((50, told.clone()));
            station.adopt(FakeNode { pid: 50, told }, "0.1.0".into(), vec![("admin".into(), 5002), ("mcp".into(), 5001)], heartbeats);
            station.pass(s(90));
            assert_eq!(station.os.killed, if heartbeats { vec![50] } else { vec![] }, "heartbeats: {heartbeats}");
            if !heartbeats {
                // It says it here: held to it from now on.
                station.said(Slot::Current, heartbeat());
                station.pass(s(90));
                assert_eq!(station.os.killed, [50]);
            }
        }
    }

    #[test]
    fn a_handover_under_way_holds_neither_node_to_its_heartbeat() {
        let mut station = station("beathandover", false);
        let old = station.last();
        station.said(Slot::Current, heartbeat());
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        // The new one slow to be ready: the old one serves on, and its word is not asked for meanwhile.
        station.pass(s(59));
        assert!(station.os.killed.is_empty());
        station.said(Slot::Next, heartbeat());
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(old), ["handover"]);
        station.ended(old, EXITED_0);
        // The new one takes over: held to it from then on.
        station.pass(s(80));
        station.serves(Slot::Current, 6000);
        station.pass(s(90) - MS);
        assert!(station.os.killed.is_empty());
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
    }

    #[test]
    fn a_front_given_up_is_started_again_later_and_the_node_serving_hands_over_to_one_linked_to_it() {
        let mut station = station("frontagain", false);
        station.os.front = true;
        let first = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        // It ended as it started: not again at once; the Node serving hands over to one that binds the endpoint itself.
        station.os.front = false;
        station.front_gone();
        let direct = station.last();
        assert_ne!(direct, first);
        station.said(Slot::Next, ready("0.1.0"));
        station.ended(first, EXITED_0);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.serving(), direct);
        assert_eq!(station.os.started_fronts, 0);
        // Not before front_retry; then one that does not start: again after twice the wait, the Node serving on.
        station.os.front_starts = vec![false, true];
        station.pass(s(300) - MS);
        assert_eq!(station.os.started_fronts, 0);
        station.pass(MS);
        assert_eq!(station.os.started_fronts, 1);
        assert_eq!(station.last(), direct, "none listens: nothing handed over");
        station.pass(s(600) - MS);
        assert_eq!(station.os.started_fronts, 1);
        station.pass(MS);
        assert_eq!(station.os.started_fronts, 2);
        // It listens: the Node serving hands over to one linked to it.
        let linked = station.last();
        assert_ne!(linked, direct);
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(direct), ["handover"]);
        station.ended(direct, EXITED_0);
        station.serves(Slot::Current, 7000);
        assert_eq!(station.serving(), linked);
        // Once, as long as it runs.
        station.pass(s(3600));
        assert_eq!(station.os.started_fronts, 2);
        assert_eq!(station.last(), linked);
    }

    #[test]
    fn a_front_is_not_started_again_during_a_handover_or_a_stop() {
        let mut station = station("frontcalm", false);
        station.os.front = true;
        let first = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.os.front = false;
        station.front_gone();
        // its handover never ready meanwhile: not while it is under way
        station.pass(s(59));
        station.pass(s(300));
        assert_eq!(station.os.started_fronts, 0);
        assert!(station.file("handoff-failed").is_some());
        let given_up = station.last();
        station.ended(given_up, KILLED);
        // Once it is over, at once (its time came meanwhile): the one serving, still linked to the front that went, hands
        // over to one linked to the one started.
        station.tick();
        assert_eq!(station.os.started_fronts, 1);
        assert_ne!(station.last(), given_up);
        station.said(Slot::Next, ready("0.1.0"));
        assert_eq!(station.told(first), ["handover"]);
        // stopping: none
        let mut station = station_stopping();
        station.pass(s(3600));
        assert_eq!(station.os.started_fronts, 0);
    }

    fn station_stopping() -> Lifecycle<Fake> {
        let mut station = station("frontstop", false);
        station.up(Slot::Current, "0.1.0", 5000);
        station.os.front = false;
        station.front_retry_at = Some(station.os.now + s(1));
        station.stop();
        station
    }

    #[test]
    fn a_front_that_does_not_answer_three_asks_in_a_row_is_killed() {
        let mut station = station("frontprobe", false);
        station.os.front = true;
        station.up(Slot::Current, "0.1.0", 5000);
        // (the launcher's first look: the asks from then on)
        station.tick();
        station.pass(s(30));
        assert_eq!(station.os.probed, [1]);
        station.front_probed(1, false);
        station.pass(s(30));
        station.front_probed(2, false);
        // One answered: counted from none again.
        station.pass(s(30));
        station.front_probed(3, true);
        station.pass(s(30));
        station.front_probed(4, false);
        station.pass(s(30));
        station.front_probed(5, false);
        assert_eq!(station.os.front_killed, 0);
        // An answer that never comes is a miss by the next ask's time; a late one is not counted.
        station.pass(s(30));
        assert_eq!(station.os.probed, [1, 2, 3, 4, 5, 6]);
        station.pass(s(30));
        assert_eq!(station.os.front_killed, 1);
        station.front_probed(6, true);
        assert_eq!(station.front_misses, 0);
        // killed: its end is seen as any other's (run.rs reap), and asks go on with the one in its place
        assert_eq!(station.os.probed.len(), 6);
        station.pass(s(30));
        assert_eq!(station.os.probed.len(), 7);
    }
    #[test]
    fn a_front_that_did_not_start_with_a_launcher_taking_up_a_node_is_tried_later_with_one_handover_now() {
        let mut station = station("frontabsent", false);
        station.current = None;
        let told = Rc::new(RefCell::new(vec![]));
        station.os.told.push((50, told.clone()));
        station.adopt(FakeNode { pid: 50, told }, "0.1.0".into(), vec![("admin".into(), 5002), ("mcp".into(), 5001)], true);
        // resume(): its front did not start; the handover it was asked for goes on, once.
        station.schedule_front_retry();
        let before = station.last();
        station.start_next();
        let next = station.last();
        assert_eq!(next, before + 1, "one Node started beside");
        assert!(station.file("handoff-failed").is_none());
        station.said(Slot::Next, heartbeat());
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(50), ["handover"]);
        station.ended(50, EXITED_0);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.serving(), next);
        assert_eq!(station.last(), next, "no other handover meanwhile");
        // At its time the front starts, and the Node serving hands over to one linked to it.
        station.pass(s(300) - MS);
        station.said(Slot::Current, heartbeat());
        assert_eq!(station.os.started_fronts, 0);
        station.pass(MS);
        assert_eq!(station.os.started_fronts, 1);
        let linked = station.last();
        assert_eq!(linked, next + 1);
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(next), ["handover"]);
    }

    impl Lifecycle<Fake> {
        /// What run/launcher-events.jsonl holds, a value a line.
        fn events(&self) -> Vec<Value> {
            self.file(EVENTS).unwrap_or_default().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
        }
    }

    fn health() -> String {
        json!({"pid": 101, "updatedAt": now_ms() - 5000, "heldMaxMs": 1200, "front": "ok", "presenceOnline": true, "relayConflict": false, "openFds": 812, "rssBytes": 734003200u64, "home": "/Users/someone"}).to_string()
    }

    #[test]
    fn a_node_killed_as_hung_is_recorded_once_with_what_its_health_said() {
        let mut station = station("eventshung", false);
        let node = station.last();
        std::fs::write(station.run.join("health.json"), health()).unwrap();
        station.said(Slot::Current, heartbeat());
        station.up(Slot::Current, "0.1.0", 5000);
        station.pass(s(90));
        assert_eq!(station.os.killed, [node]);
        station.ended(node, KILLED);
        let events = station.events();
        assert_eq!(events.len(), 1, "its end is not a crash of its own: {events:?}");
        let e = &events[0];
        assert_eq!((e["kind"].as_str(), e["level"].as_str()), (Some("node_hung_killed"), Some("error")));
        assert_eq!((e["pid"].as_u64(), e["version"].as_str(), e["heartbeatTimeoutMs"].as_u64(), e["uptimeMs"].as_u64()), (Some(node as u64), Some("0.1.0"), Some(90_000), Some(90_000)));
        assert_eq!((e["rssBytes"].as_u64(), e["openFds"].as_u64(), e["heldMaxMs"].as_u64()), (Some(734003200), Some(812), Some(1200)));
        assert_eq!((e["front"].as_str(), e["presenceOnline"].as_bool(), e["relayConflict"].as_bool()), (Some("ok"), Some(true), Some(false)));
        assert!(e["healthAgeMs"].as_u64().is_some_and(|age| age >= 5000));
        assert!(e.get("home").is_none() && e.get("updatedAt").is_none(), "only the summary's fields");
        assert!(e["at"].as_u64().is_some());
    }

    #[test]
    fn a_node_killed_as_hung_collects_diagnostics_before_kill_and_overrides_stale_health() {
        let mut station = station("eventshungdiag", false);
        let node = station.last();
        std::fs::write(station.run.join("health.json"), health()).unwrap();
        let mut diag = serde_json::Map::new();
        diag.insert("procState".into(), "S".into());
        diag.insert("wchan".into(), "futex_wait_queue".into());
        diag.insert("rssBytes".into(), 999_000_000u64.into());
        diag.insert("openFds".into(), 950u64.into());
        diag.insert("threads".into(), 16u64.into());
        diag.insert("kernelStack".into(), "futex_wait_queue+0x60/0x90".into());
        station.os.hung_diag = diag;
        station.said(Slot::Current, heartbeat());
        station.up(Slot::Current, "0.1.0", 5000);
        station.pass(s(90));
        assert_eq!(station.os.diagnosed_before_kill, [(node, true)], "diagnose_hung must run before kill");
        assert_eq!(station.os.killed, [node]);
        let events = station.events();
        assert_eq!(events.len(), 1);
        let e = &events[0];
        assert_eq!((e["rssBytes"].as_u64(), e["openFds"].as_u64()), (Some(999_000_000), Some(950)), "live diagnostics override stale health.json");
        assert_eq!((e["heldMaxMs"].as_u64(), e["front"].as_str(), e["presenceOnline"].as_bool(), e["relayConflict"].as_bool()), (Some(1200), Some("ok"), Some(true), Some(false)));
        assert!(e["healthAgeMs"].as_u64().is_some_and(|age| age >= 5000));
        assert_eq!((e["procState"].as_str(), e["wchan"].as_str(), e["threads"].as_u64(), e["kernelStack"].as_str()), (Some("S"), Some("futex_wait_queue"), Some(16), Some("futex_wait_queue+0x60/0x90")));
    }

    #[test]
    fn a_node_that_crashes_is_recorded_with_how_it_ended() {
        let mut station = station("eventscrash", false);
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.pass(s(5));
        station.ended(node, EXITED_1);
        let events = station.events();
        assert_eq!(events.len(), 1);
        let e = &events[0];
        assert_eq!((e["kind"].as_str(), e["level"].as_str(), e["how"].as_str()), (Some("node_crashed"), Some("error"), Some(EXITED_1)));
        assert_eq!((e["pid"].as_u64(), e["version"].as_str(), e["taken"].as_bool(), e["uptimeMs"].as_u64(), e["failures"].as_u64()), (Some(node as u64), Some("0.1.0"), Some(true), Some(5000), Some(0)));
        assert!(e.get("rssBytes").is_none(), "no health.json, no summary");
        // Stopped as asked: no crash.
        station.pass(s(1));
        station.stop();
        station.ended(station.last(), EXITED_0);
        assert_eq!(station.events().len(), 1);
    }

    #[test]
    fn the_front_killed_as_hung_and_gone_are_recorded() {
        let mut station = station("eventsfront", false);
        station.os.front = true;
        station.up(Slot::Current, "0.1.0", 5000);
        std::fs::write(station.run.join("health.json"), health()).unwrap();
        station.tick();
        for n in 1..=3 {
            station.pass(s(30));
            station.front_probed(n, false);
        }
        assert_eq!(station.os.front_killed, 1);
        station.os.front = false;
        station.front_gone();
        let events = station.events();
        let kinds: Vec<_> = events.iter().map(|e| e["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["front_hung_killed", "front_gone"]);
        assert_eq!((events[0]["level"].as_str(), events[0]["misses"].as_u64(), events[0]["probeMs"].as_u64(), events[0]["openFds"].as_u64()), (Some("error"), Some(3), Some(30_000), Some(812)));
        assert_eq!((events[1]["level"].as_str(), events[1]["retries"].as_u64(), events[1]["front"].as_str()), (Some("warn"), Some(0), Some("ok")));
    }

    #[test]
    fn a_node_ended_by_the_os_shutting_down_is_no_crash() {
        let mut station = station("shutdowncurrent", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let next = station.last();
        station.told(old);
        station.ended_on_shutdown(old, "exited with 1073807364");
        assert_eq!(station.told(next), ["stop"], "the one starting beside is stopped");
        assert!(station.told(old).is_empty(), "the one ended is not told");
        assert_eq!(station.restart_at, None);
        assert_eq!(station.finished(), None);
        station.ended(next, EXITED_0);
        assert_eq!(station.finished(), Some(0));
        station.pass(s(10));
        assert_eq!(station.last(), next, "none started again");
        assert!(station.events().is_empty(), "nothing recorded: {:?}", station.events());
    }

    #[test]
    fn a_node_starting_beside_ended_by_the_os_shutting_down_is_no_failed_handover() {
        let mut station = station("shutdownnext", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let next = station.last();
        station.told(old);
        station.ended_on_shutdown(next, "exited with -1073741205");
        assert_eq!(station.told(old), ["stop"]);
        assert!(station.told(next).is_empty());
        assert_eq!(station.restart_at, None);
        assert_eq!(station.file("handoff-failed"), None);
        assert!(station.events().is_empty(), "nothing recorded: {:?}", station.events());
        station.ended(old, EXITED_0);
        assert_eq!(station.finished(), Some(0));
    }

    #[test]
    fn a_handover_given_up_and_an_old_node_killed_are_recorded() {
        let mut station = station("eventshandover", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        station.pass(s(60));
        let e = station.events().pop().unwrap();
        assert_eq!((e["kind"].as_str(), e["level"].as_str()), (Some("handoff_failed"), Some("warn")));
        assert_eq!(e["reason"].as_str(), Some(format!("the new station (pid {}) was not ready within 60 s", old + 1).as_str()));
        assert!(e.get("rssBytes").is_none());
        station.ended(old + 1, KILLED);
        assert_eq!(station.events().len(), 1, "a Node given up is no crash");
        // A handover whose old Node does not go.
        station.start_next();
        station.said(Slot::Next, ready("0.2.0"));
        station.pass(s(30));
        assert_eq!(station.os.killed, [old + 1, old]);
        let e = station.events().pop().unwrap();
        assert_eq!((e["kind"].as_str(), e["level"].as_str(), e["pid"].as_u64(), e["version"].as_str(), e["exitTimeoutMs"].as_u64()), (Some("retiring_killed"), Some("warn"), Some(old as u64), Some("0.1.0"), Some(30_000)));
        // A reason is cut to its most, on a character's boundary.
        station.handoff_failed(&"é".repeat(200));
        let reason = station.events().pop().unwrap()["reason"].as_str().unwrap().to_string();
        assert_eq!(reason.len(), REASON_MOST);
    }

    #[test]
    fn only_the_newest_events_are_kept() {
        let station = station("eventskept", false);
        std::fs::write(station.run.join(EVENTS), "not json at all\n\n").unwrap();
        for n in 0..(EVENTS_KEPT + 7) {
            station.handoff_failed(&format!("try {n}"));
        }
        let events = station.events();
        assert_eq!(events.len(), EVENTS_KEPT);
        assert_eq!(events[0]["reason"].as_str(), Some("try 7"));
        assert_eq!(events[EVENTS_KEPT - 1]["reason"].as_str(), Some(format!("try {}", EVENTS_KEPT + 6).as_str()));
    }
}
