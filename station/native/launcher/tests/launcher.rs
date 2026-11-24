#![cfg(unix)]

//! The launcher run as launchd runs it, with a stand-in for the station's Node side (fixtures/main.js) on a real Node
//! ($STILLFAIL_NODE, else the build machine's). Each test has its own data directory; the launcher binds its ports
//! where it finds them free (port 0), so no other program can take them first.
//!
//! What these tests decide is the code's, not the machine's speed's: they wait for what the processes do, with no
//! limit of time. The ones whose point is real timing (no gap on the ports, the backoff's gaps) are the side run's
//! (`cargo test -- --ignored`); run.rs's tests have the same logic on a test's clock.

use std::io::{BufRead, BufReader, Read};
use std::net::{TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;

const BUILT: &str = env!("CARGO_BIN_EXE_stillfail-station");

/// The launcher, run once before any test starts it. macOS looks at each new executable the first time it runs, and
/// the tests that start it at once all wait for that look.
fn launcher() -> &'static str {
    static LOOKED_AT: std::sync::Once = std::sync::Once::new();
    LOOKED_AT.call_once(|| assert!(output(Command::new(BUILT).arg("handoff-version")).status.success()));
    BUILT
}

/// The Node the station runs on (.node-version), where scripts/node-here.sh puts it, unless STILLFAIL_NODE says another.
fn node() -> String {
    let version = include_str!("../../../../.node-version").trim();
    let platform = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "darwin-arm64",
        ("linux", "x86_64") => "linux-x64",
        ("linux", "aarch64") => "linux-arm64",
        _ => return std::env::var("STILLFAIL_NODE").unwrap_or_else(|_| "node".to_string()),
    };
    std::env::var("STILLFAIL_NODE").unwrap_or_else(|_| {
        let here = format!("{}/.local/node-v{version}-{platform}/bin/node", std::env::var("HOME").unwrap());
        if Path::new(&here).is_file() { here } else { "node".to_string() }
    })
}

/// Held while a socket is made or a process started. On macOS a socket is made close-on-exec only after it is made: a
/// fork from another test thread in between would hand the child (a launcher) a copy of a test's listening socket.
static FORKS: Mutex<()> = Mutex::new(());

fn spawn(command: &mut Command) -> Child {
    let _forks = FORKS.lock().unwrap_or_else(|e| e.into_inner());
    command.spawn().unwrap()
}

fn output(command: &mut Command) -> std::process::Output {
    let _forks = FORKS.lock().unwrap_or_else(|e| e.into_inner());
    command.output().unwrap()
}

fn bind(port: u16) -> std::io::Result<TcpListener> {
    let _forks = FORKS.lock().unwrap_or_else(|e| e.into_inner());
    TcpListener::bind(("127.0.0.1", port))
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

/// A test's directory: data (with config.json naming the MCP port), app (with the stand-in as station/main.js).
struct Station {
    dir: PathBuf,
    data: PathBuf,
    app: PathBuf,
    /// The loopback port the launcher is given (--port): 0 for one free.
    port: u16,
    launcher: Option<Child>,
}

impl Station {
    fn new(name: &str) -> Station {
        let dir = std::env::temp_dir().join(format!("launcher-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (data, app) = (dir.join("data"), dir.join("app"));
        std::fs::create_dir_all(app.join("station")).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        std::fs::copy(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/main.js"), app.join("station/main.js")).unwrap();
        std::fs::write(data.join("config.json"), r#"{"http":{"port":0}}"#).unwrap();
        Station { dir, data, app, port: 0, launcher: None }
    }

    fn command(&self, times: &str) -> Command {
        let mut command = Command::new(launcher());
        command
            .env("STILLFAIL_NODE", node())
            .env("STILLFAIL_LAUNCHER_TIMES", times)
            .env_remove("STILLFAIL_DATA")
            .env_remove("STILLFAIL_MB_READER")
            .env_remove("STILLFAIL_CONFIG")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(std::fs::OpenOptions::new().create(true).append(true).open(self.dir.join("launcher.log")).unwrap());
        command
    }

    fn run_args(&self) -> Vec<String> {
        ["run", "--app", self.app.to_str().unwrap(), "--data", self.data.to_str().unwrap(), "--port", &self.port.to_string()].map(String::from).to_vec()
    }

    fn start(&mut self, times: &str) {
        let child = spawn(self.command(times).args(self.run_args()));
        self.launcher = Some(child);
    }

    fn pid(&self) -> i32 {
        self.launcher.as_ref().unwrap().id() as i32
    }

    fn signal(&self, signal: i32) {
        // SAFETY: a signal to the launcher this test started.
        assert_eq!(unsafe { libc::kill(self.pid(), signal) }, 0);
    }

    fn wait(&mut self) -> ExitStatus {
        self.launcher.as_mut().unwrap().wait().unwrap()
    }

    fn conf(&self, text: &str) {
        std::fs::write(self.data.join("fake.conf"), text).unwrap();
    }

    fn file(&self, name: &str) -> Option<String> {
        std::fs::read_to_string(self.data.join("run").join(name)).ok()
    }

    fn station_json(&self) -> Option<Value> {
        self.file("station.json").and_then(|t| serde_json::from_str(&t).ok())
    }

    /// The stand-in's log: (ms, pid, what).
    fn log(&self) -> Vec<(u64, i32, String)> {
        let text = std::fs::read_to_string(self.data.join("fake.log")).unwrap_or_default();
        text.lines()
            .filter_map(|l| {
                let mut parts = l.splitn(3, ' ');
                Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.to_string()))
            })
            .collect()
    }

    fn said(&self, pid: i32, what: &str) -> bool {
        self.log().iter().any(|(_, p, w)| *p == pid && w.starts_with(what))
    }

    /// Where in the log `pid` first said `what`: the log is appended to in the order things happened.
    fn said_at(&self, pid: i32, what: &str) -> usize {
        self.log().iter().position(|(_, p, w)| *p == pid && w.starts_with(what)).unwrap()
    }

    fn started(&self) -> Vec<i32> {
        self.log().into_iter().filter(|(_, _, w)| w.starts_with("start")).map(|(_, p, _)| p).collect()
    }

    /// The ports the launcher bound, (MCP, loopback), once a Node serves them.
    fn ports(&self) -> (u16, u16) {
        until("a Node serving the ports", || {
            let log = self.log();
            let (_, _, ports) = log.iter().find(|(_, _, w)| w.starts_with("ports "))?;
            let mut ports = ports.split(' ').skip(1).map(|p| p.parse().unwrap());
            Some((ports.next()?, ports.next()?))
        })
    }

    fn mcp(&self) -> u16 {
        self.ports().0
    }

    fn admin(&self) -> u16 {
        self.ports().1
    }

    /// Waits for the station to be up: station.json written.
    fn up(&mut self) -> Value {
        let up = until("station.json or an exit", || match self.station_json() {
            Some(said) => Some(Ok(said)),
            None => self.launcher.as_mut().unwrap().try_wait().unwrap().map(Err),
        });
        up.unwrap_or_else(|status| panic!("the launcher exited ({status})"))
    }
}

impl Drop for Station {
    fn drop(&mut self) {
        if std::thread::panicking() {
            eprintln!("--- launcher.log\n{}", std::fs::read_to_string(self.dir.join("launcher.log")).unwrap_or_default());
            eprintln!("--- fake.log\n{}", std::fs::read_to_string(self.data.join("fake.log")).unwrap_or_default());
        }
        // Only the launcher is killed: its Nodes end when their control socket closes.
        if let Some(child) = &mut self.launcher
            && child.try_wait().ok().flatten().is_none()
        {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Waits for what another process does (a file it writes, its end), looking again every 20 ms. No limit of time: the
/// outcome must not depend on how fast the machine is.
fn until<T>(_what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    loop {
        if let Some(v) = f() {
            return v;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only asks whether the process is there.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// What the station answers on `port`: "<pid> mcp|admin". The launcher holds the listening socket: a connection waits
/// in its backlog until a Node takes it.
fn ask(port: u16) -> std::io::Result<String> {
    let mut stream = TcpStream::connect(("127.0.0.1", port))?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    if text.is_empty() {
        return Err(std::io::Error::other("closed without an answer"));
    }
    Ok(text.trim().to_string())
}

fn answered_by(port: u16) -> i32 {
    ask(port).unwrap().split(' ').next().unwrap().parse().unwrap()
}

#[test]
fn handoff_version_is_4() {
    // (3: takes a running launcher's place on Unix; 4: on Windows too, run_windows.rs `renew`)
    let out = output(Command::new(launcher()).arg("handoff-version"));
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "4\n");
}

#[test]
fn other_commands_are_node_s_with_the_same_arguments() {
    let station = Station::new("exec");
    let mut command = station.command("");
    let args = ["channel", "beta", "--app", station.app.to_str().unwrap(), "--data", station.data.to_str().unwrap()];
    let child = spawn(command.args(args).stdout(Stdio::piped()));
    let pid = child.id();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(7));
    let said: Value = serde_json::from_slice(&out.stdout).unwrap();
    // Exec'd: the same process.
    assert_eq!(said["pid"], pid);
    assert_eq!(said["args"], serde_json::json!(args));
}

#[test]
fn a_held_lock_exits_3() {
    let mut station = Station::new("held");
    std::fs::create_dir_all(station.data.join("run")).unwrap();
    let lock = std::fs::File::create(station.data.join("run/station.lock")).unwrap();
    // SAFETY: flock on a file this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    station.start("");
    assert_eq!(station.wait().code(), Some(3));
    assert!(std::fs::read_to_string(station.dir.join("launcher.log")).unwrap().contains("另一个 still.fail station 正在运行这个数据目录"));
    assert!(station.log().is_empty(), "no Node started");
}

#[test]
fn a_named_port_taken_fails_the_start() {
    let mut station = Station::new("taken");
    // Held by the test all along: taken for sure.
    let taken = bind(0).unwrap();
    station.port = taken.local_addr().unwrap().port();
    station.start("");
    assert_eq!(station.wait().code(), Some(1));
    assert!(std::fs::read_to_string(station.dir.join("launcher.log")).unwrap().contains(&format!("端口 127.0.0.1:{} 已被别的程序占用", station.port)));
    assert!(station.log().is_empty(), "no Node started");
}

#[test]
fn node_serves_the_launchers_ports_and_station_json_names_the_launcher() {
    let mut station = Station::new("ports");
    let before = now_ms();
    station.start("");
    let said = station.up();
    let after = now_ms();
    let text = station.file("station.json").unwrap();
    assert!(text.ends_with('\n') && text.trim_end().lines().count() == 1, "{text:?}");
    assert!(text.starts_with(&format!("{{\"pid\":{},\"startedAt\":", station.pid())), "{text}");
    assert_eq!(said["pid"], station.pid());
    assert_eq!(said["version"], "0.1.0");
    assert_eq!((said["handoff"].as_u64(), said["drain"].as_u64(), said["channel"].as_u64(), said["renew"].as_u64()), (Some(1), Some(1), Some(1), Some(1)));
    let started_at = said["startedAt"].as_u64().unwrap();
    assert!(before <= started_at && started_at <= after, "{before} <= {started_at} <= {after}");
    let (mcp, admin) = station.ports();
    assert_eq!(station.file("ports.json").unwrap(), format!("{{\"admin\":{admin}}}\n"));
    // The launcher bound them; Node accepts on them.
    let node = station.started()[0];
    assert_ne!(node, station.pid());
    assert_eq!(ask(mcp).unwrap(), format!("{node} mcp"));
    assert_eq!(ask(admin).unwrap(), format!("{node} admin"));
    let start = &station.log()[0].2;
    let app = station.app.display();
    let data = station.data.display();
    assert_eq!(start, &format!("start run --app {app} --data {data} --launcher-fds 3,4,5 --launcher-carries --launcher-heartbeat --launcher-installer"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    assert!(station.said(node, "got stop") && station.said(node, "exit"));
}

#[test]
fn node_runs_with_malloc_set_for_space_on_macos() {
    let mut station = Station::new("malloc");
    station.start("");
    station.up();
    let node = station.started()[0];
    until("node to say its malloc", || station.log().into_iter().any(|(_, p, w)| p == node && w.starts_with("malloc ")).then_some(()));
    let set = if cfg!(target_os = "macos") { "malloc 1" } else { "malloc as it is" };
    assert!(station.said(node, set), "{:?}", station.log());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn sigusr2_hands_over_to_a_new_node() {
    let mut station = Station::new("handover");
    station.start("");
    station.up();
    let old = answered_by(station.mcp());
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    // Written again once the old one is gone.
    let after = until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_eq!(after["pid"], station.pid(), "the pid stays");
    let new = *station.started().last().unwrap();
    assert_ne!(new, old);
    assert_eq!(answered_by(station.mcp()), new);
    assert_eq!(answered_by(station.admin()), new);
    assert!(station.said(old, "got handover") && station.said(old, "exit"));
    assert!(!alive(old));
    // The old one was told only once the new one was ready.
    assert!(station.said_at(new, "ready") < station.said_at(old, "got handover"));
    // What the old one held in memory, given as it handed over, went to the new one.
    until("what the old Node held carried over", || station.said(new, &format!(r#"got carried {{"from":{old}}}"#)).then_some(()));
    assert!(station.file("handoff-failed").is_none());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

/// Puts a launcher into the release at `--app`, as an update does: `script` is a shell script's body, `$BUILT` the
/// launcher built here.
fn release_launcher(station: &Station, script: &str) {
    let dir = station.app.join("mesh/target/release");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("stillfail-station");
    std::fs::write(&path, format!("#!/bin/sh\nBUILT='{BUILT}'\n{script}")).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
}

#[test]
fn a_handover_first_makes_the_launcher_the_one_the_release_has_now() {
    let mut station = Station::new("renew");
    station.start("");
    station.up();
    let pid = station.pid();
    let old = answered_by(station.mcp());
    // An update brought a launcher unlike the one running (here one that says where it ran `run`, then is this one).
    let renewed = station.dir.join("renewed");
    release_launcher(&station, &format!("[ \"$1\" = run ] && echo $$ >> '{}'\nexec \"$BUILT\" \"$@\"\n", renewed.display()));
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    let after = until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    // The same process (its pid, its lock, its ports) runs the release's launcher now, and handed over from there.
    assert_eq!(std::fs::read_to_string(&renewed).unwrap(), format!("{pid}\n"));
    assert_eq!(after["pid"], pid);
    let new = *station.started().last().unwrap();
    assert_ne!(new, old);
    assert_eq!(station.started().len(), 2, "the Node serving was kept through it");
    assert_eq!(answered_by(station.mcp()), new);
    assert_eq!(answered_by(station.admin()), new);
    assert!(station.said(old, "got handover") && !alive(old));
    until("what the old Node held carried over", || station.said(new, &format!(r#"got carried {{"from":{old}}}"#)).then_some(()));
    assert!(station.file("handoff-failed").is_none());
    // The release's launcher it is now: the next handover does not make it that again.
    station.conf("version=0.3.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the next version", || station.station_json().filter(|s| s["version"] == "0.3.0"));
    assert_eq!(std::fs::read_to_string(&renewed).unwrap(), format!("{pid}\n"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_launcher_in_the_release_that_cannot_take_a_running_one_over_is_not_run() {
    let mut station = Station::new("norenew");
    station.start("");
    station.up();
    // One from before this could be done (a release rolled back to): it would not find its lock its own.
    let ran = station.dir.join("ran");
    release_launcher(&station, &format!("[ \"$1\" = handoff-version ] && {{ echo 2; exit 0; }}\necho \"$@\" >> '{}'\nexit 1\n", ran.display()));
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    let after = until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_eq!(after["pid"], station.pid());
    assert!(!ran.exists());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
#[ignore = "side: no gap on real ports while real processes hand over is a matter of real timing"]
fn sigusr2_hands_over_to_a_new_node_with_no_gap_on_the_ports() {
    let mut station = Station::new("nogap");
    station.start("");
    station.up();
    let (mcp, admin) = station.ports();
    let old = answered_by(mcp);
    // Asking both ports all along: every connection is answered, by the old Node, then the new.
    let (stop, failed, asked) = (Arc::new(AtomicBool::new(false)), Arc::new(Mutex::new(vec![])), Arc::new(AtomicUsize::new(0)));
    let who = Arc::new(Mutex::new(std::collections::BTreeSet::new()));
    let askers: Vec<_> = [mcp, admin]
        .into_iter()
        .map(|port| {
            let (stop, failed, asked, who) = (stop.clone(), failed.clone(), asked.clone(), who.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    match ask(port) {
                        Ok(said) => {
                            who.lock().unwrap().insert(said.split(' ').next().unwrap().to_string());
                        }
                        Err(e) => failed.lock().unwrap().push(e.to_string()),
                    }
                    asked.fetch_add(1, Ordering::SeqCst);
                    std::thread::sleep(Duration::from_millis(2));
                }
            })
        })
        .collect();
    station.conf("version=0.2.0\nready_after=400\n");
    std::thread::sleep(Duration::from_millis(100));
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    std::thread::sleep(Duration::from_millis(200));
    stop.store(true, Ordering::SeqCst);
    askers.into_iter().for_each(|t| t.join().unwrap());
    let new = answered_by(mcp);
    assert_ne!(new, old);
    assert!(failed.lock().unwrap().is_empty(), "connections not answered: {:?}", failed.lock().unwrap());
    assert!(asked.load(Ordering::SeqCst) > 50);
    let who = who.lock().unwrap();
    assert!(who.contains(&old.to_string()) && who.contains(&new.to_string()), "{who:?}");
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_handover_whose_new_node_is_never_ready_fails_and_the_old_one_serves_on() {
    let mut station = Station::new("handfail");
    station.start("ready=1500");
    let first = station.up();
    let (mcp, admin) = station.ports();
    let old = answered_by(mcp);
    station.conf("ready=no\n");
    station.signal(libc::SIGUSR2);
    let why = until("handoff-failed", || station.file("handoff-failed"));
    assert!(why.contains("not ready"), "{why}");
    let new = *station.started().last().unwrap();
    assert_ne!(new, old);
    until("the new Node killed", || (!alive(new)).then_some(()));
    assert_eq!(station.station_json().unwrap(), first);
    assert_eq!(answered_by(mcp), old);
    assert_eq!(answered_by(admin), old);
    assert!(!station.said(old, "got handover"));
    // A later handover works.
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_ne!(answered_by(mcp), old);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_handover_whose_new_node_does_not_take_over_fails_and_a_node_is_started_again_after_the_rollback_wait() {
    let mut station = Station::new("nottaken");
    station.start("rollback=500");
    let first = station.up();
    let (mcp, _) = station.ports();
    let old = answered_by(mcp);
    // Ready, so the old one hands over and goes; then its agents' side does not start.
    station.conf("version=0.2.0\ntake=failed\n");
    station.signal(libc::SIGUSR2);
    let why = until("handoff-failed", || station.file("handoff-failed"));
    assert!(why.contains("did not take over") && why.contains("a test's"), "{why}");
    let new = *station.started().last().unwrap();
    assert!(station.said(new, "take failed"));
    // (the old one is told over its pipe and says so once it reads it, which can be after the new one failed: 39621137177)
    until("the old Node told to hand over", || station.said(old, "got handover").then_some(()));
    until("the new Node ended", || (!alive(new)).then_some(()));
    assert_eq!(station.station_json().unwrap(), first, "not said handed over");
    // The installer puts the release before back meanwhile; the Node started again is that one, and serves.
    station.conf("version=0.1.0\n");
    let again = until("station.json of a new start", || station.station_json().filter(|s| *s != first));
    assert_eq!(again["version"], "0.1.0");
    let node = *station.started().last().unwrap();
    assert!(node != new && node != old);
    assert_eq!(answered_by(mcp), node);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn sigusr1_and_sighup_go_to_node_and_drained_is_written() {
    let mut station = Station::new("forward");
    station.start("");
    station.up();
    let node = station.started()[0];
    station.signal(libc::SIGUSR1);
    until("run/drained", || station.file("drained").filter(|d| d == "idle\n"));
    assert!(station.said(node, "got drain"));
    station.signal(libc::SIGHUP);
    until("hup", || station.said(node, "got hup").then_some(()));
    assert!(station.launcher.as_mut().unwrap().try_wait().unwrap().is_none());
    assert_eq!(answered_by(station.admin()), node);
    station.signal(libc::SIGINT);
    assert!(station.wait().success());
    assert!(station.said(node, "got stop"));
}

#[test]
fn sigterm_during_a_handover_stops_both() {
    let mut station = Station::new("stopboth");
    station.start("");
    station.up();
    station.conf("ready=no\n");
    station.signal(libc::SIGUSR2);
    let both = until("the second Node", || Some(station.started()).filter(|s| s.len() == 2));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    for pid in both {
        // Stopped when told, not killed when late.
        assert!(station.said(pid, "got stop") && station.said(pid, "exit"), "{pid}");
        assert!(!alive(pid));
    }
}

#[test]
#[ignore = "side: measures the gaps between real restarts"]
fn a_crashed_node_is_started_again_with_backoff() {
    let mut station = Station::new("crash");
    station.conf("crash_after=100\n");
    station.start("backoff=300");
    station.up();
    // Started, crashed, again after 300, 600, 1200 ms.
    let log = until("four starts", || Some(station.log()).filter(|l| l.iter().filter(|e| e.2.starts_with("start")).count() >= 4));
    station.conf("");
    let crashes: Vec<u64> = log.iter().filter(|e| e.2 == "crash").map(|e| e.0).collect();
    let starts: Vec<u64> = log.iter().filter(|e| e.2.starts_with("start")).map(|e| e.0).collect();
    for (i, expected) in [300u64, 600, 1200].into_iter().enumerate() {
        let gap = starts[i + 1] - crashes[i];
        // Wall-clock times (the log's) may be slewed against the launcher's monotonic clock: some leeway below.
        assert!(gap * 100 >= expected * 85 && gap < expected + 700, "restart {i}: {gap} ms, expected about {expected}");
    }
    // The launcher stays; a Node that does not crash serves again.
    let pid = station.pid();
    let mcp = station.mcp();
    until("a Node that stays", || {
        let node = *station.started().last()?;
        (station.said(node, "ready") && !station.said(node, "crash") && ask(mcp).ok()? == format!("{node} mcp")).then_some(())
    });
    assert_eq!(station.station_json().unwrap()["pid"], pid);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_crashed_node_is_started_again() {
    let mut station = Station::new("restart");
    station.conf("crash=once\n");
    station.start("backoff=100");
    station.up();
    let first = station.started()[0];
    until("the first Node's crash", || station.said(first, "crash").then_some(()));
    let again = until("a Node that stays", || Some(*station.started().last()?).filter(|n| *n != first && station.said(*n, "ready")));
    assert_eq!(answered_by(station.mcp()), again);
    assert_eq!(station.station_json().unwrap()["pid"], station.pid());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn five_starts_in_a_row_that_fail_and_the_launcher_gives_up() {
    let mut station = Station::new("giveup");
    station.conf("start=crash\n");
    station.start("backoff=100");
    assert_eq!(station.wait().code(), Some(1));
    assert_eq!(station.started().len(), 5);
    assert!(station.station_json().is_none());
}

/// Kills the shell of with_parent's test when it panics (the launcher then sees its parent gone).
struct Shell(Child);

impl Drop for Shell {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn with_parent_it_stops_once_the_parent_is_gone() {
    let station = Station::new("parent");
    // A shell starts the launcher in the background, says its pid, then waits (as sleep, the same process).
    let log = station.dir.join("launcher.log");
    let args = station.run_args().iter().map(|a| format!("'{a}'")).collect::<Vec<_>>().join(" ");
    let script = format!("\"$0\" {args} --with-parent >/dev/null 2>>'{}' & echo $!; exec sleep 600", log.display());
    let mut shell = spawn(
        Command::new("/bin/sh")
            .args(["-c", &script, launcher()])
            .env("STILLFAIL_NODE", node())
            .env("STILLFAIL_LAUNCHER_TIMES", "parent=200")
            .env_remove("STILLFAIL_DATA")
            .env_remove("STILLFAIL_CONFIG")
            .stdout(Stdio::piped()),
    );
    let mut line = String::new();
    BufReader::new(shell.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let (shell, launcher) = (Shell(shell), line.trim().parse::<i32>().unwrap());
    let said = until("station.json", || station.station_json());
    assert_eq!(said["pid"], launcher);
    let node = station.started()[0];
    drop(shell);
    until("the launcher to end", || (!alive(launcher)).then_some(()));
    assert!(station.said(node, "got stop"));
    until("Node to end", || (!alive(node)).then_some(()));
}

/// A stand-in for the front (front.rs) in the release: it says where it listens and how it hands streams (this
/// release's way), appends its pid to <data>/fronts and runs until its stdin (the launcher's) ends.
fn release_front(station: &Station) {
    release_front_saying(station, ",\"streams\":8");
}

/// One that says `more` after where it listens (nothing: a front from before `streams`).
fn release_front_saying(station: &Station, more: &str) {
    let path = station.app.join("station/stillfail-reader");
    let fronts = station.data.join("fronts");
    std::fs::write(&path, format!("#!/bin/sh\n# --builder mesh --socket S --shell-dir D\necho $$ >> '{}'\nprintf '{{\"listening\":\"%s\"{}}}\\n' \"$4\"\nexec cat > /dev/null\n", fronts.display(), more)).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
}

impl Station {
    /// The fronts started so far.
    fn fronts(&self) -> Vec<i32> {
        std::fs::read_to_string(self.data.join("fronts")).unwrap_or_default().lines().map(|l| l.parse().unwrap()).collect()
    }
}

#[test]
fn one_front_serves_every_node_across_handovers_and_ends_with_the_launcher() {
    let mut station = Station::new("front");
    release_front(&station);
    station.start("");
    station.up();
    let socket = station.data.join("run/front.sock");
    let first = station.started()[0];
    until("the Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == first && w.starts_with("front ")).then_some(()));
    assert!(station.said(first, &format!("front {}", socket.display())), "{:?}", station.log());
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 1);
    // a handover: the same front, told to the new Node
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    let new = *station.started().last().unwrap();
    assert!(station.said(new, &format!("front {}", socket.display())));
    assert_eq!(station.fronts(), fronts);
    assert!(alive(fronts[0]));
    // the launcher becoming the release's (renew): the same front still
    release_launcher(&station, "exec \"$BUILT\" \"$@\"\n");
    station.conf("version=0.3.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the next version", || station.station_json().filter(|s| s["version"] == "0.3.0"));
    let next = *station.started().last().unwrap();
    assert!(station.said(next, &format!("front {}", socket.display())));
    assert_eq!(station.fronts(), fronts);
    assert!(alive(fronts[0]));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(fronts[0])).then_some(()));
}

#[test]
fn a_launcher_from_before_the_front_renewed_starts_one_for_the_next_node() {
    let mut station = Station::new("frontrenew");
    // a release without the program: no front, the Node binds the endpoint itself
    station.start("");
    station.up();
    let first = station.started()[0];
    until("the Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == first && w.starts_with("front ")).then_some(()));
    assert!(station.said(first, "front none"));
    // an update that brings the program and a new launcher (renew): the new launcher starts the front for the next Node
    release_front(&station);
    release_launcher(&station, "exec \"$BUILT\" \"$@\"\n");
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    let new = *station.started().last().unwrap();
    let socket = station.data.join("run/front.sock");
    until("the new Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == new && w.starts_with("front ")).then_some(()));
    assert!(station.said(new, &format!("front {}", socket.display())), "{:?}", station.log());
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 1);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(fronts[0])).then_some(()));
}

#[test]
fn a_front_handing_streams_as_a_release_before_is_replaced_by_the_launcher_that_takes_it_up() {
    // the front of a release before `streams` (it hands a connection's streams as they come, in any order)
    a_front_saying_is_replaced("frontold", "");
}

#[test]
fn a_front_from_before_the_mesh_operations_is_replaced_by_the_launcher_that_takes_it_up() {
    // `streams` 4: a front that answers Node's meshConfigure "no operation meshConfigure"
    a_front_saying_is_replaced("frontfour", ",\"streams\":4");
}

#[test]
fn a_front_from_before_the_shell_and_path_fixes_is_replaced_by_the_launcher_that_takes_it_up() {
    // `streams` 5: a front without iroh.probeRelay and the shell's stream and noq path fixes
    a_front_saying_is_replaced("frontfive", ",\"streams\":5");
}

#[test]
fn a_front_from_before_the_bbr3_and_window_fixes_is_replaced_by_the_launcher_that_takes_it_up() {
    // `streams` 6: a front without the noq-proto BBRv3 fixes and 4 MiB stream_receive_window (#8093)
    a_front_saying_is_replaced("frontsix", ",\"streams\":6");
}

#[test]
fn a_front_from_before_the_bbr3_loss_thresh_fix_is_replaced_by_the_launcher_that_takes_it_up() {
    // `streams` 7: a front without BBRv3 loss_thresh(0.30) and gated lower-bound adaptation
    a_front_saying_is_replaced("frontseven", ",\"streams\":7");
}

fn a_front_saying_is_replaced(name: &str, more: &str) {
    let mut station = Station::new(name);
    release_front_saying(&station, more);
    station.start("");
    station.up();
    let old = station.fronts();
    assert_eq!(old.len(), 1);
    // an update that brings this release's front and launcher (renew): the old front ended, the release's started
    // before the next Node, which is told it
    release_front(&station);
    release_launcher(&station, "exec \"$BUILT\" \"$@\"\n");
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    let new = *station.started().last().unwrap();
    let socket = station.data.join("run/front.sock");
    until("the new Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == new && w.starts_with("front ")).then_some(()));
    assert!(station.said(new, &format!("front {}", socket.display())), "{:?}", station.log());
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 2, "{fronts:?}");
    assert!(!alive(old[0]));
    assert!(alive(fronts[1]));
    // and kept from then on: a renew again leaves it
    station.conf("version=0.3.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the next version", || station.station_json().filter(|s| s["version"] == "0.3.0"));
    assert_eq!(station.fronts(), fronts);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(fronts[1])).then_some(()));
}

#[cfg(target_os = "macos")]
#[test]
fn a_changed_launcher_identity_replaces_the_front_but_the_same_identity_keeps_it() {
    let mut station = Station::new("front-uuid");
    release_front(&station);
    station.start("");
    station.up();
    let original = station.fronts();
    assert_eq!(original.len(), 1);

    // The same Mach-O identity, even reached through a different launcher file, retains the front.
    release_launcher(&station, "exec \"$BUILT\" \"$@\"\n");
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("same-identity handover", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_eq!(station.fronts(), original);

    // Give a copy a different Mach-O UUID and sign it afresh so macOS will run it.
    let changed = station.dir.join("different-launcher");
    let mut image = std::fs::read(BUILT).unwrap();
    assert_eq!(u32::from_ne_bytes(image[0..4].try_into().unwrap()), 0xfeedfacf);
    let end = 32 + u32::from_ne_bytes(image[20..24].try_into().unwrap()) as usize;
    let mut offset = 32;
    while offset < end {
        let kind = u32::from_ne_bytes(image[offset..offset + 4].try_into().unwrap());
        let size = u32::from_ne_bytes(image[offset + 4..offset + 8].try_into().unwrap()) as usize;
        assert!(size >= 8 && offset + size <= end);
        if kind == 0x1b {
            image[offset + 8] ^= 1;
            break;
        }
        offset += size;
    }
    assert!(offset < end, "the launcher has an LC_UUID");
    std::fs::write(&changed, image).unwrap();
    std::fs::set_permissions(&changed, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    assert!(output(Command::new("codesign").args(["--force", "--sign", "-"]).arg(&changed)).status.success());
    release_launcher(&station, &format!("exec '{}' \"$@\"\n", changed.display()));
    station.conf("version=0.3.0\n");
    station.signal(libc::SIGUSR2);
    until("different-identity handover", || station.station_json().filter(|s| s["version"] == "0.3.0"));
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 2, "{fronts:?}");
    assert!(!alive(original[0]));
    assert!(alive(fronts[1]));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the replacement front to end", || (!alive(fronts[1])).then_some(()));
}

#[test]
fn a_front_that_ends_is_started_again_unless_it_ended_as_it_started() {
    let mut station = Station::new("frontends");
    release_front(&station);
    station.start("front=0");
    station.up();
    let first = station.fronts()[0];
    // SAFETY: a signal to the stand-in this test's launcher started.
    unsafe { libc::kill(first, libc::SIGKILL) };
    let second = until("another front", || station.fronts().get(1).copied());
    assert!(alive(second));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(second)).then_some(()));

    // one that ends as soon as it started: not again, and the Nodes from then on bind the endpoint themselves
    let mut station = Station::new("frontquits");
    release_front(&station);
    station.start("front=3600000");
    station.up();
    let first = station.fronts()[0];
    // SAFETY: as above.
    unsafe { libc::kill(first, libc::SIGKILL) };
    until("the front's end said", || std::fs::read_to_string(station.dir.join("launcher.log")).ok().filter(|l| l.contains("not started again")));
    assert_eq!(station.fronts().len(), 1);
    // and the Node serving, linked to the front that is gone, hands over by itself to one that binds it (it waited for
    // a SIGUSR2 by hand before, 2026-11-15)
    let new = until("the Node handed over to", || station.started().get(1).copied());
    until("the new Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == new && w.starts_with("front ")).then_some(()));
    assert!(station.said(new, "front none"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn the_node_serving_asking_for_the_front_anew_has_it_ended_and_hands_over_to_one_linked_to_a_new_one() {
    let mut station = Station::new("frontrestart");
    release_front(&station);
    station.conf("restart_front=once\n");
    station.start("");
    station.up();
    let socket = station.data.join("run/front.sock");
    let first = station.started()[0];
    until("the first Node to ask", || station.said(first, "restart front").then_some(()));
    // the front there ended (its stdin closed), another started in its place
    let fronts = until("another front", || Some(station.fronts()).filter(|f| f.len() >= 2));
    assert_eq!(fronts.len(), 2, "{fronts:?}");
    until("the first front gone", || (!alive(fronts[0])).then_some(()));
    assert!(alive(fronts[1]));
    // and the Node serving handed over to one linked to it
    let new = until("the Node handed over to", || station.started().get(1).copied());
    until("the new Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == new && w.starts_with("front ")).then_some(()));
    assert!(station.said(new, &format!("front {}", socket.display())), "{:?}", station.log());
    until("the first Node handed over", || station.said(first, "got handover").then_some(()));
    let mcp = station.mcp();
    until("the new one serving", || (ask(mcp).ok()? == format!("{new} mcp")).then_some(()));
    assert!(station.file("handoff-failed").is_none());
    assert_eq!(station.file("front.pid").map(|p| p.trim().to_string()), Some(fronts[1].to_string()));
    assert_eq!(station.started().len(), 2, "one handover: {:?}", station.log());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(fronts[1])).then_some(()));
}

/// A station with a front rolled back to a release from before it (0.1.8755: no program, and the launcher `script`):
/// its front is ended before the handover's Node starts, which binds the endpoint itself, and none is started again.
fn rolled_back_to_a_release_without_the_front(name: &str, script: &str) {
    let mut station = Station::new(name);
    release_front(&station);
    station.start("front_retry=100");
    station.up();
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 1);
    std::fs::remove_file(station.app.join("station/stillfail-reader")).unwrap();
    release_launcher(&station, script);
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    let new = *station.started().last().unwrap();
    until("the new Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == new && w.starts_with("front ")).then_some(()));
    assert!(station.said(new, "front none"), "{:?}", station.log());
    // gone before it started (ended, and waited for), and no other in its place
    assert!(!alive(fronts[0]), "the front left beside a Node that binds the station's endpoint itself: {}", station.launcher_log());
    assert!(station.launcher_log().contains("has no front"), "{}", station.launcher_log());
    assert_eq!(station.fronts(), fronts);
    assert_eq!(station.file("front.pid"), None);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_release_rolled_back_to_one_without_the_front_and_a_launcher_that_cannot_take_over_has_the_front_ended() {
    rolled_back_to_a_release_without_the_front("frontback2", "[ \"$1\" = handoff-version ] && { echo 2; exit 0; }\nexit 1\n");
}

#[test]
fn a_release_rolled_back_to_one_without_the_front_whose_launcher_takes_over_has_the_front_ended_before_it_runs() {
    rolled_back_to_a_release_without_the_front("frontback3", "exec \"$BUILT\" \"$@\"\n");
}

/// A front of `station`'s data directory left from before (2026-11-16: a launcher killed, or one from before front.pid,
/// left its front running beside the next one's, both on the station's key): a process of this user with a front's
/// arguments for its socket, no launcher's child (its parent gone), with no front.pid naming it, that does not end
/// with its stdin. Its pid.
fn orphan_front(station: &Station) -> i32 {
    let socket = station.data.join("run/front.sock");
    let script = "sh -c 'trap \"\" HUP TERM; while :; do sleep 1; done' stillfail-reader --builder mesh --socket \"$1\" --shell-dir \"$1.d\" </dev/null >/dev/null 2>&1 & echo $!";
    let out = output(Command::new("/bin/sh").arg("-c").arg(script).arg("sh").arg(&socket).stdin(Stdio::null()));
    let pid: i32 = String::from_utf8(out.stdout).unwrap().trim().parse().unwrap();
    assert!(alive(pid));
    pid
}

/// Ended by the test, if the launcher did not end it.
fn ended_by_test(pid: i32) -> bool {
    let was = alive(pid);
    // SAFETY: a signal to a process this test started.
    unsafe { libc::kill(pid, libc::SIGKILL) };
    was
}

#[test]
fn a_front_left_from_before_is_ended_as_the_launcher_starts() {
    let mut station = Station::new("orphanstart");
    release_front(&station);
    let orphan = orphan_front(&station);
    station.start("");
    station.up();
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 1);
    let left = ended_by_test(orphan);
    assert!(!left, "the front left from before still runs beside the launcher's: {}", station.launcher_log());
    assert!(station.launcher_log().contains(&format!("left from before (pid {orphan})")), "{}", station.launcher_log());
    assert!(alive(fronts[0]));
    assert_eq!(station.file("front.pid").map(|p| p.trim().to_string()), Some(fronts[0].to_string()));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    assert!(!alive(fronts[0]));
    assert_eq!(station.file("front.pid"), None);
}

#[test]
fn a_front_left_from_before_is_ended_by_the_launcher_that_takes_over_and_the_one_kept_lives() {
    let mut station = Station::new("orphanrenew");
    release_front(&station);
    station.start("");
    station.up();
    let fronts = station.fronts();
    assert_eq!(fronts.len(), 1);
    // one left by a launcher from before front.pid (an update taken up from 0.1.9230), found as the release's launcher
    // takes this one's place
    let orphan = orphan_front(&station);
    release_launcher(&station, "exec \"$BUILT\" \"$@\"\n");
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    let left = ended_by_test(orphan);
    assert!(!left, "the front left from before still runs beside the one kept: {}", station.launcher_log());
    assert_eq!(station.fronts(), fronts, "the front kept is the one serving");
    assert!(alive(fronts[0]));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    assert!(!alive(fronts[0]));
}

#[test]
fn a_front_that_does_not_end_with_its_stdin_is_killed_as_the_launcher_stops() {
    let mut station = Station::new("frontstuck");
    // a front whose thread reading stdin is held: its end of the pipe is never read
    let path = station.app.join("station/stillfail-reader");
    let fronts = station.data.join("fronts");
    std::fs::write(&path, format!("#!/bin/sh\necho $$ >> '{}'\nprintf '{{\"listening\":\"%s\",\"streams\":8}}\\n' \"$4\"\nexec sleep 1000000\n", fronts.display())).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    station.start("");
    station.up();
    let front = station.fronts()[0];
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    let left = ended_by_test(front);
    assert!(!left, "the front outlived the launcher: {}", station.launcher_log());
    assert!(station.launcher_log().contains("did not end with its stdin"), "{}", station.launcher_log());
}

impl Station {
    fn launcher_log(&self) -> String {
        std::fs::read_to_string(self.dir.join("launcher.log")).unwrap_or_default()
    }
}

#[test]
fn a_node_whose_main_thread_hangs_after_taking_over_is_killed_and_another_serves() {
    let mut station = Station::new("hang");
    station.conf("hang=once\n");
    station.start("heartbeat=500,backoff=100");
    station.up();
    let first = station.started()[0];
    assert!(station.said(first, "heartbeat asked"), "{:?}", station.log());
    until("the first Node to hang", || station.said(first, "hang").then_some(()));
    // Not asked to hand over (it would not hear it): killed, and one started again that serves.
    let again = until("a Node that serves after it", || Some(*station.started().last()?).filter(|n| *n != first && station.said(*n, "ready")));
    until("the hung one gone", || (!alive(first)).then_some(()));
    let mcp = station.mcp();
    until("the new one answering", || (ask(mcp).ok()? == format!("{again} mcp")).then_some(()));
    assert!(station.launcher_log().contains(&format!("Node {first} said nothing for 0.5 s")), "{}", station.launcher_log());
    assert!(!station.said(first, "got handover"));
    assert!(station.file("handoff-failed").is_none());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
#[ignore = "side: waits real time for what does not happen"]
fn a_node_that_does_not_say_it_is_alive_is_left_serving() {
    // A release from before (heartbeat=no): it never says it, so it is never held to it. What it would take for it to be
    // killed (500 ms of silence after taking over) is long past once another Node, which does say it, has been
    // handed over to and has said it a while.
    let mut station = Station::new("noheartbeat");
    station.conf("heartbeat=no\n");
    station.start("heartbeat=500");
    station.up();
    let old = station.started()[0];
    let mcp = station.mcp();
    // Its silence is long by the time the next one, started at a SIGUSR2, is up.
    until("10 heartbeat-times of the old one's silence", || (now_ms() >= station.log()[0].0 + 5000).then_some(()));
    assert!(alive(old));
    assert_eq!(answered_by(mcp), old);
    assert!(!station.launcher_log().contains("said nothing"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_front_given_up_is_started_again_and_the_node_serving_hands_over_to_one_linked_to_it() {
    let mut station = Station::new("frontretry");
    release_front(&station);
    station.start("front=3600000,front_retry=300");
    station.up();
    let socket = station.data.join("run/front.sock");
    let first_front = station.fronts()[0];
    // SAFETY: a signal to the stand-in this test's launcher started.
    unsafe { libc::kill(first_front, libc::SIGKILL) };
    // It ended as it started: Nodes bind the endpoint themselves meanwhile (the one serving handed over to one) ...
    let direct = until("the Node handed over to", || station.started().get(1).copied());
    until("the new Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == direct && w.starts_with("front ")).then_some(()));
    assert!(station.said(direct, "front none"));
    // ... until a front is started again: the one serving then hands over to one linked to it.
    let second_front = until("another front", || station.fronts().get(1).copied());
    assert!(alive(second_front));
    let linked = until("the Node linked to it", || station.started().get(2).copied());
    until("the linked Node to say its front", || station.log().into_iter().any(|(_, p, w)| p == linked && w.starts_with("front ")).then_some(()));
    assert!(station.said(linked, &format!("front {}", socket.display())), "{:?}", station.log());
    until("the direct one gone", || (!alive(direct)).then_some(()));
    let mcp = station.mcp();
    until("the linked one serving", || (ask(mcp).ok()? == format!("{linked} mcp")).then_some(()));
    assert!(station.launcher_log().contains("the front listens again"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(second_front)).then_some(()));
}

/// A front in the release that answers on its socket (fixtures/front.cjs, on the tests' Node).
fn release_answering_front(station: &Station) {
    let path = station.app.join("station/stillfail-reader");
    let js = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/front.cjs");
    std::fs::write(&path, format!("#!/bin/sh\nexec '{}' '{}' \"$@\"\n", node(), js.display())).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
}

impl Station {
    fn front_asks(&self) -> usize {
        std::fs::read_to_string(self.data.join("front-asks")).unwrap_or_default().lines().count()
    }
}

#[test]
fn a_front_that_answers_is_left_and_one_that_stops_answering_is_killed_and_started_again() {
    let mut station = Station::new("frontprobe");
    release_answering_front(&station);
    station.start("front=0,front_probe=100");
    station.up();
    let first = until("the front", || station.fronts().first().copied());
    // Asked again and again, answering each: left alone.
    until("five asks answered", || (station.front_asks() >= 5).then_some(()));
    assert!(!station.launcher_log().contains("did not answer"), "{}", station.launcher_log());
    assert_eq!(station.fronts(), [first]);
    // Stopped (it holds its socket and the system takes connections into its backlog, but nothing answers): killed after
    // three asks, and another started in its place.
    // SAFETY: a signal to the stand-in this test's launcher started.
    unsafe { libc::kill(first, libc::SIGSTOP) };
    let second = until("another front", || station.fronts().get(1).copied());
    until("the stopped one gone", || (!alive(first)).then_some(()));
    assert!(alive(second));
    assert!(station.launcher_log().contains("killed as hung"), "{}", station.launcher_log());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(second)).then_some(()));
}

/// The signals `pid` ignores, where the system says (Linux: /proc; macOS lists none for a process).
fn ignored_signals(pid: i32) -> Option<u64> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let line = status.lines().find(|l| l.starts_with("SigIgn:"))?;
    u64::from_str_radix(line.trim_start_matches("SigIgn:").trim(), 16).ok()
}

const SIGPIPE_BIT: u64 = 1 << (libc::SIGPIPE - 1);

#[test]
fn the_launcher_lives_through_telling_a_node_whose_end_of_the_control_socket_closed() {
    let mut station = Station::new("sigpipe");
    station.conf("control=close\n");
    station.start("stop=200");
    station.up();
    let node = station.started()[0];
    until("the Node to close its end", || station.said(node, "control closed by itself").then_some(()));
    if let Some(ignored) = ignored_signals(station.pid()) {
        assert_ne!(ignored & SIGPIPE_BIT, 0, "SigIgn {ignored:x}");
    }
    // Told something on a socket whose other end is gone: EPIPE, said, not a SIGPIPE that would end it.
    station.signal(libc::SIGHUP);
    until("the launcher to say it could not tell it", || station.launcher_log().contains(&format!("could not tell Node {node}")).then_some(()));
    assert!(station.launcher.as_mut().unwrap().try_wait().unwrap().is_none(), "the launcher is still there");
    station.signal(libc::SIGTERM);
    // (the Node hears no stop: killed when it does not stop in time)
    let _ = station.wait();
    until("the Node gone", || (!alive(node)).then_some(()));
}

/// The front program the release has (station/mb's reader), where the test is given one (STILLFAIL_TEST_READER: `node
/// scripts/native.ts file reader`); else the test says it skips.
fn reader() -> Option<PathBuf> {
    let given = std::env::var_os("STILLFAIL_TEST_READER").map(PathBuf::from).filter(|p| p.is_file());
    if given.is_none() {
        eprintln!("skipped: no STILLFAIL_TEST_READER (the reader program to run as the front)");
    }
    given
}

/// One ask of the front at `socket`, its answer's line.
fn ask_front(socket: &Path, line: &str) -> String {
    use std::io::Write;
    let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
    stream.write_all(line.as_bytes()).unwrap();
    let mut answer = String::new();
    BufReader::new(&stream).read_line(&mut answer).unwrap();
    answer
}

#[test]
fn the_release_s_front_answers_an_ask_it_has_no_operation_for_and_lives_through_writing_to_a_closed_socket() {
    let Some(program) = reader() else { return };
    let mut station = Station::new("realfront");
    std::os::unix::fs::symlink(&program, station.app.join("station/stillfail-reader")).unwrap();
    station.start("");
    station.up();
    let socket = station.data.join("run/front.sock");
    let front = until("the front listening", || {
        let log = station.launcher_log();
        let at = log.find("the front listens (pid ")?;
        log[at + 23..].split(')').next()?.parse::<i32>().ok()
    });
    // What the launcher asks it (front.rs `answers`): an answer of the same id, an error.
    let said: Value = serde_json::from_str(&ask_front(&socket, "{\"id\":1,\"op\":\"answers\"}\n")).unwrap();
    assert_eq!(said["id"], 1);
    assert!(said["error"].is_string(), "{said}");
    if let Some(ignored) = ignored_signals(front) {
        assert_ne!(ignored & SIGPIPE_BIT, 0, "SigIgn {ignored:x}");
    }
    // Asks whose asker is gone before the answer is written: written to a closed socket (EPIPE), many times over.
    for _ in 0..50 {
        use std::io::Write;
        let mut stream = std::os::unix::net::UnixStream::connect(&socket).unwrap();
        stream.write_all(b"{\"id\":2,\"op\":\"answers\"}\n").unwrap();
        drop(stream);
    }
    let said: Value = serde_json::from_str(&ask_front(&socket, "{\"id\":3,\"op\":\"answers\"}\n")).unwrap();
    assert_eq!(said["id"], 3);
    assert!(alive(front));
    assert!(!station.launcher_log().contains("did not answer"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    until("the front to end with the launcher", || (!alive(front)).then_some(()));
}

impl Station {
    /// A release of the MoonBit station alone (scripts/station-bundle.sh): no `node/`, no `station/main.js`, only
    /// `station/stillfail-reader`, here a stand-in program that is both the front (`--builder mesh …`: fixtures/front.cjs)
    /// and the station (`run …` and every other command: fixtures/main.js, copied outside the release as a CommonJS
    /// script, beside no package.json that says otherwise). The launcher is
    /// given a Node that is not there, so nothing it starts can be run on Node.
    fn moonbit(name: &str) -> Station {
        let station = Station::new(name);
        std::fs::remove_file(station.app.join("station/main.js")).unwrap();
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
        let program = station.app.join("station/stillfail-reader");
        let main = station.dir.join("stand-in.cjs");
        std::fs::copy(fixtures.join("main.js"), &main).unwrap();
        std::fs::write(
            &program,
            format!(
                "#!/bin/sh\ncase \"$1\" in --builder) exec '{node}' '{front}' \"$@\" ;; esac\nexec '{node}' '{main}' \"$@\"\n",
                node = node(),
                front = fixtures.join("front.cjs").display(),
                main = main.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&program, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        assert!(!station.app.join("node").exists() && !station.app.join("station/main.js").exists());
        station
    }

    fn moonbit_command(&self, times: &str) -> Command {
        let mut command = self.command(times);
        command.env("STILLFAIL_NODE", self.dir.join("no-node-here"));
        command
    }

    fn start_moonbit(&mut self, times: &str) {
        let child = spawn(self.moonbit_command(times).args(self.run_args()));
        self.launcher = Some(child);
    }
}

#[test]
fn a_release_of_the_moonbit_station_alone_runs_it_with_the_same_arguments_and_its_front() {
    let mut station = Station::moonbit("mb-ports");
    station.start_moonbit("");
    let said = station.up();
    assert_eq!(said["pid"], station.pid());
    assert_eq!(said["version"], "0.1.0");
    let (mcp, admin) = station.ports();
    let first = station.started()[0];
    assert_ne!(first, station.pid());
    // The release's program itself (exec'd by the stand-in: the same process), told what Node was told.
    let (app, data) = (station.app.display(), station.data.display());
    assert_eq!(station.log()[0].2, format!("start run --app {app} --data {data} --launcher-fds 3,4,5 --launcher-carries --launcher-heartbeat --launcher-installer"));
    assert!(station.said(first, "heartbeat asked"));
    assert_eq!(ask(mcp).unwrap(), format!("{first} mcp"));
    assert_eq!(ask(admin).unwrap(), format!("{first} admin"));
    // The same program as its front, the station told it.
    let socket = station.data.join("run/front.sock");
    until("the station to say its front", || station.log().into_iter().any(|(_, p, w)| p == first && w.starts_with("front ")).then_some(()));
    assert!(station.said(first, &format!("front {}", socket.display())), "{:?}", station.log());
    assert_eq!(station.fronts().len(), 1);
    assert!(!station.launcher_log().contains("no-node-here"), "{}", station.launcher_log());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    assert!(station.said(first, "got stop") && station.said(first, "exit"));
}

#[test]
fn the_moonbit_station_is_handed_over_on_sigusr2_carrying_what_it_held_and_drains_and_stops_as_node_did() {
    let mut station = Station::moonbit("mb-handover");
    station.start_moonbit("");
    station.up();
    let old = answered_by(station.mcp());
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    let after = until("station.json of the new version", || station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_eq!(after["pid"], station.pid(), "the pid stays");
    let new = *station.started().last().unwrap();
    assert_ne!(new, old);
    assert_eq!(answered_by(station.mcp()), new);
    assert_eq!(answered_by(station.admin()), new);
    assert!(station.said_at(new, "ready") < station.said_at(old, "got handover"));
    assert!(station.said(old, "exit") && !alive(old));
    until("what the old one held carried over", || station.said(new, &format!(r#"got carried {{"from":{old}}}"#)).then_some(()));
    assert!(station.file("handoff-failed").is_none());
    // One front all along, told to the new one.
    assert_eq!(station.fronts().len(), 1);
    assert!(station.said(new, &format!("front {}", station.data.join("run/front.sock").display())));
    // SIGUSR1: drained; SIGHUP: passed on; SIGTERM: stopped.
    station.signal(libc::SIGUSR1);
    until("run/drained", || station.file("drained").filter(|d| d == "idle\n"));
    assert!(station.said(new, "got drain"));
    station.signal(libc::SIGHUP);
    until("hup", || station.said(new, "got hup").then_some(()));
    assert_eq!(answered_by(station.admin()), new);
    let fronts = station.fronts();
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    assert!(station.said(new, "got stop"));
    until("the front to end with the launcher", || (!alive(fronts[0])).then_some(()));
}

#[test]
fn the_moonbit_station_s_commands_are_its_own_with_the_same_arguments_and_its_release_is_found_above_the_launcher() {
    let station = Station::moonbit("mb-exec");
    let (app, data) = (station.app.to_str().unwrap(), station.data.to_str().unwrap());
    let run = |command: &mut Command, args: &[&str]| {
        let child = spawn(command.args(args).stdout(Stdio::piped()));
        let pid = child.id();
        let out = child.wait_with_output().unwrap();
        assert_eq!(out.status.code(), Some(7), "{args:?}");
        let said: Value = serde_json::from_slice(&out.stdout).unwrap();
        // Exec'd: the same process.
        assert_eq!(said["pid"], pid, "{args:?}");
        said
    };
    for args in [vec!["status", "--app", app, "--data", data], vec!["update", "--beta", "--app", app, "--data", data], vec!["heap", "--app", app, "--data", data], vec!["id", "--app", app, "--data", data]] {
        let said = run(&mut station.moonbit_command(""), &args);
        assert_eq!(said["args"], serde_json::json!(args));
    }
    // With no --app (bin/stillfail gives none to `status`): the release above the launcher, as an update lays it out.
    let dir = station.app.join("mesh/target/release");
    std::fs::create_dir_all(&dir).unwrap();
    let launcher = dir.join("stillfail-station");
    std::fs::copy(BUILT, &launcher).unwrap();
    let mut command = Command::new(&launcher);
    command.env_remove("STILLFAIL_DATA").env_remove("STILLFAIL_NODE").env_remove("STILLFAIL_MB_READER").stdin(Stdio::null());
    let said = run(&mut command, &["heap", "--data", data]);
    assert_eq!(said["args"], serde_json::json!(["heap", "--data", data]));
}
