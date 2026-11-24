#![cfg(windows)]

//! The launcher run as Windows' scheduled task runs it (stillfail-station-w, its child stillfail-station), with the
//! stand-in for the station's Node side (fixtures/main.js) on a real Node ($STILLFAIL_NODE, else `node` on PATH): an
//! update whose release has another launcher, handed over to it (run_windows.rs `renew`) as the installer does it
//! (install-windows.ts: the release moved aside, the new one put in its place, `handover` asked on the launcher's
//! pipe). What these tests decide is the code's, not the machine's speed's: they wait for what the processes do.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

const BUILT: &str = env!("CARGO_BIN_EXE_stillfail-station");
const BUILT_W: &str = env!("CARGO_BIN_EXE_stillfail-station-w");
const IN_APP: &str = "mesh/target/release";

fn node() -> String {
    std::env::var("STILLFAIL_NODE").unwrap_or_else(|_| "node".to_string())
}

/// A test's directory: data, and a release (app) with the stand-in and the launchers built, `extra` bytes after the
/// launcher's (another launcher to the one before it, as an update's).
struct Station {
    dir: PathBuf,
    data: PathBuf,
    app: PathBuf,
    wrapper: Option<Child>,
}

fn release(app: &Path, extra: &[u8]) {
    std::fs::create_dir_all(app.join("station")).unwrap();
    std::fs::create_dir_all(app.join(IN_APP)).unwrap();
    std::fs::copy(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/main.js"), app.join("station/main.js")).unwrap();
    let mut launcher = std::fs::read(BUILT).unwrap();
    // (bytes past a program's end are its own: another program to a hash, the same to Windows)
    launcher.extend_from_slice(extra);
    std::fs::write(app.join(IN_APP).join("stillfail-station.exe"), launcher).unwrap();
    std::fs::copy(BUILT_W, app.join(IN_APP).join("stillfail-station-w.exe")).unwrap();
}

impl Station {
    fn new(name: &str) -> Station {
        let dir = std::env::temp_dir().join(format!("launcher-win-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (data, app) = (dir.join("data"), dir.join("app"));
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(data.join("config.json"), r#"{"http":{"port":0}}"#).unwrap();
        release(&app, b"");
        Station { dir, data, app, wrapper: None }
    }

    /// stillfail-station-w, as the scheduled task starts it.
    fn start(&mut self) {
        let child = Command::new(self.app.join(IN_APP).join("stillfail-station-w.exe"))
            .args(["run", "--app", self.app.to_str().unwrap(), "--data", self.data.to_str().unwrap(), "--port", "0"])
            .env("STILLFAIL_NODE", node())
            .env_remove("STILLFAIL_DATA")
            .env_remove("STILLFAIL_MB_READER")
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        self.wrapper = Some(child);
    }

    fn file(&self, rel: &str) -> String {
        std::fs::read_to_string(self.data.join(rel)).unwrap_or_default()
    }

    fn said(&self) -> Option<Value> {
        serde_json::from_str(&self.file("run/station.json")).ok()
    }

    /// Done once `what` holds; says what the station said and logged when it does not within long (a test's limit).
    fn until(&self, what: &str, mut f: impl FnMut(&Station) -> bool) {
        let started = Instant::now();
        while !f(self) {
            if started.elapsed() > Duration::from_secs(120) {
                panic!("{what}: not so\nstillfail.log:\n{}\nfake.log:\n{}", self.file("stillfail.log"), self.file("fake.log"));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// `{"op": op}` on the launcher's own pipe (the installer's way).
    fn ask(&self, pid: u64, op: &str) {
        let mut pipe = std::fs::OpenOptions::new().write(true).open(format!(r"\\.\pipe\stillfail-launcher-{pid}")).unwrap();
        writeln!(pipe, "{{\"op\":\"{op}\"}}").unwrap();
    }

    /// The launcher's own ports (`--launcher-ports` as Node was given them): the MCP endpoint's, the loopback port's.
    fn ports(&self) -> (u16, u16) {
        let log = self.file("fake.log");
        let given = log.split_whitespace().skip_while(|w| *w != "--launcher-ports").nth(1).unwrap().to_string();
        let mut ports = given.split(',').map(|p| p.parse::<u16>().unwrap());
        (ports.next().unwrap(), ports.next().unwrap())
    }
}

impl Drop for Station {
    fn drop(&mut self) {
        if let Some(mut wrapper) = self.wrapper.take() {
            let _ = wrapper.kill();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// What a connection to `port` is answered: "<pid of the Node serving> <mcp|admin>".
fn answer(port: u16) -> String {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut said = String::new();
    stream.read_to_string(&mut said).unwrap();
    said.trim().to_string()
}

fn alive(pid: u64) -> bool {
    let out = Command::new("tasklist").args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).contains(&format!("\"{pid}\""))
}

#[test]
fn an_update_with_another_launcher_hands_it_the_ports_the_node_and_the_lock_and_the_task_s_process_follows_it() {
    let mut station = Station::new("renew");
    station.start();
    station.until("the station serving", |s| s.said().is_some_and(|j| j["version"] == "0.1.0"));
    let first = station.said().unwrap()["pid"].as_u64().unwrap();
    let (mcp, admin) = station.ports();
    let node_before = answer(admin);
    assert!(node_before.ends_with(" admin"), "{node_before}");

    // The update, as install-windows.ts does it: the release moved aside (its launcher runs on from there), the new
    // one in its place, with another launcher, and a Node that says another version.
    std::fs::rename(&station.app, station.dir.join("app.old-1")).unwrap();
    release(&station.app, b"another launcher");
    std::fs::write(station.data.join("fake.conf"), "version=0.2.0\n").unwrap();
    station.ask(first, "handover");

    station.until("handed over through the release's launcher", |s| s.said().is_some_and(|j| j["version"] == "0.2.0"));
    let said = station.said().unwrap();
    let second = said["pid"].as_u64().unwrap();
    assert_ne!(second, first, "another launcher: {said}");
    assert_eq!(said["renewedFrom"].as_u64(), Some(first), "{said}");
    // The same ports, now carried by the new launcher to the new Node.
    let node_after = answer(admin);
    assert_ne!(node_after, node_before);
    assert!(answer(mcp).ends_with(" mcp"));
    // The launcher before ended (RENEWED), the task's process following the new one.
    station.until("the launcher before gone", |_| !alive(first));
    let wrapper = station.wrapper.as_mut().unwrap();
    assert!(wrapper.try_wait().unwrap().is_none(), "the task's process follows the new launcher");
    // The data directory's lock is the new one's: another launcher on it is refused.
    let held = Command::new(BUILT)
        .args(["run", "--app", station.app.to_str().unwrap(), "--data", station.data.to_str().unwrap(), "--port", "0"])
        .env("STILLFAIL_NODE", node())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert_eq!(held.code(), Some(3), "held by the new launcher");

    // A stop asked of the new launcher: it ends 0, and the task's process with it.
    station.ask(second, "stop");
    let wrapper = station.wrapper.as_mut().unwrap();
    let started = Instant::now();
    let status = loop {
        if let Some(status) = wrapper.try_wait().unwrap() {
            break status;
        }
        assert!(started.elapsed() < Duration::from_secs(120), "the task's process did not end\n{}", station.file("stillfail.log"));
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(status.code(), Some(0), "{}", station.file("stillfail.log"));
    let lines: Vec<String> = BufReader::new(station.file("stillfail.log").as_bytes()).lines().map_while(Result::ok).collect();
    assert!(lines.iter().any(|l| l.contains("takes the place of launcher")), "{lines:?}");
}

#[test]
fn under_a_task_s_process_that_does_not_follow_a_launcher_hands_over_as_before() {
    let mut station = Station::new("norenew");
    // (stillfail-station alone, as a stillfail-station-w from before runs it: not FOLLOWED)
    let child = Command::new(station.app.join(IN_APP).join("stillfail-station.exe"))
        .args(["run", "--app", station.app.to_str().unwrap(), "--data", station.data.to_str().unwrap(), "--port", "0"])
        .env("STILLFAIL_NODE", node())
        .env_remove("STILLFAIL_LAUNCHER_FOLLOWED")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(std::fs::OpenOptions::new().create(true).append(true).open(station.data.join("stillfail.log")).unwrap())
        .spawn()
        .unwrap();
    station.wrapper = Some(child);
    station.until("the station serving", |s| s.said().is_some_and(|j| j["version"] == "0.1.0"));
    let first = station.said().unwrap()["pid"].as_u64().unwrap();
    std::fs::rename(&station.app, station.dir.join("app.old-1")).unwrap();
    release(&station.app, b"another launcher");
    std::fs::write(station.data.join("fake.conf"), "version=0.2.0\n").unwrap();
    station.ask(first, "handover");
    station.until("handed over", |s| s.said().is_some_and(|j| j["version"] == "0.2.0"));
    let said = station.said().unwrap();
    assert_eq!(said["pid"].as_u64(), Some(first), "the same launcher: {said}");
    assert!(said.get("renewedFrom").is_none(), "{said}");
    station.ask(first, "stop");
}
