//! stillfail-station: the native launcher of the TypeScript station (docs/station-ts-native.md §2), with the Rust
//! station's command line (bin/stillfail, the desktop app and the installer call it).
//!
//! `run` is the launcher's own: it holds the data directory's lock, the two listening ports and the pid that
//! run/station.json names, and runs the station's process under it (run.rs), starting a new one beside it on
//! SIGUSR2 and letting the old one go once the new one is ready. Every other command is the station's: exec'd with the
//! same arguments. The station's process is the MoonBit station (`<app>/station/stillfail-reader`) where the release
//! has no `station/main.js`; where it has one (a release from before, rolled back to) Node running that script, as
//! before (`station`). `handoff-version` says 4: a Rust station asked to hand over to this binary does not exec it (it does only
//! for 1); a launcher before this one does, to take its place at a handover (from 3: run.rs `renew`; on Windows from 4:
//! run_windows.rs `renew`).

mod data;
#[cfg_attr(windows, allow(dead_code))]
mod diagnose;
#[cfg(unix)]
mod front;
mod lifecycle;
mod log;
mod ports;
/// The entrances Windows' launcher keeps for Node (built and tested everywhere; run where Node cannot be handed sockets).
#[cfg_attr(unix, allow(dead_code))]
mod proxy;
#[cfg_attr(windows, path = "run_windows.rs")]
mod run;

use std::ffi::OsString;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

/// Where Node and the station's script are in the release (`--app`).
#[cfg(unix)]
const NODE_IN_APP: &str = "node/bin/node";
/// Node's own Windows layout: node.exe at the top of its directory.
#[cfg(windows)]
const NODE_IN_APP: &str = "node/node.exe";
const MAIN_IN_APP: &str = "station/main.js";
/// The MoonBit station in the release: the whole station where there is no `MAIN_IN_APP` (and its front either way,
/// front.rs).
#[cfg(unix)]
const READER_IN_APP: &str = "station/stillfail-reader";
#[cfg(windows)]
const READER_IN_APP: &str = "station/stillfail-reader.exe";
/// Node to run instead of the release's (tests, development).
const NODE_VAR: &str = "STILLFAIL_NODE";
/// The handoff this binary reads: none of the Rust station's (which is 1); from 3, a running launcher's (`--resume`) on
/// Unix; from 4 on Windows too (run_windows.rs `renew`: a pipe's name, which a Windows launcher from before cannot read).
const HANDOFF_VERSION: u32 = 4;
/// `run`'s exit when another station runs the data directory (the desktop app reads it: apps/desktop/src/station.ts).
const HELD: i32 = 3;

pub fn node(app: &Path) -> PathBuf {
    std::env::var_os(NODE_VAR).filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| app.join(NODE_IN_APP))
}

pub fn main_js(app: &Path) -> PathBuf {
    app.join(MAIN_IN_APP)
}

/// What runs the station of the release at `app`: its program and, for Node, the script it is given first.
pub struct Station {
    pub program: PathBuf,
    pub script: Option<PathBuf>,
}

impl Station {
    /// The command that runs it, the station's own arguments to follow.
    pub fn command(&self) -> std::process::Command {
        let mut command = std::process::Command::new(&self.program);
        if let Some(script) = &self.script {
            command.arg(script);
        }
        command
    }
}

/// What runs the station of the data directory `data` from the release at `app`: `"engine": "moonbit"` is retired,
/// so when the release has `station/main.js` we log and start Node directly (while `stillfail-reader`'s `station_shim`
/// handles older un-renewed launchers during live upgrades). Fallback to `stillfail-reader` applies only to legacy
/// Node-less rollback releases or `stillfail-reader-harness` test layouts that omit `station/main.js`.
pub fn station_of(app: &Path, data: &Path) -> Station {
    let script = main_js(app);
    if data::Config::read(data).is_ok_and(|c| c.moonbit) {
        if script.is_file() {
            log::info(r#"config.json sets "engine": "moonbit", which is retired; starting Node instead"#);
            return Station { program: node(app), script: Some(script) };
        }
        let reader = app.join(READER_IN_APP);
        if reader.is_file() {
            return Station { program: reader, script: None };
        }
    }
    station(app)
}

/// The MoonBit station where the release has it and no Node script; else Node and the script (a release from
/// before the MoonBit station, rolled back to, and the tests' stand-in), which needs Node in the release.
pub fn station(app: &Path) -> Station {
    let script = main_js(app);
    let reader = app.join(READER_IN_APP);
    if !script.is_file() && reader.is_file() {
        Station { program: reader, script: None }
    } else {
        Station { program: node(app), script: Some(script) }
    }
}

fn usage() -> ! {
    eprintln!("usage:\n  stillfail-station run --app DIR [--port N] [--data DIR] [--with-parent]\n  stillfail-station enroll <cloud-origin> <token> [--data DIR]\n  stillfail-station status [--data DIR]\n  stillfail-station id [--data DIR]\n  stillfail-station lock status|reset [--data DIR]\n  stillfail-station channel [stable|beta] [--app DIR] [--data DIR]\n  stillfail-station update [--beta|--stable] [--app DIR] [--data DIR]\n  stillfail-station heap [--data DIR]\n  stillfail-station handoff-version\n\n--data: default ~/.stillfail ($STILLFAIL_DATA).\nrun: --app is the release; --port the loopback port's (default 4760, a free one when it is taken); --with-parent: end when the parent does.\n${NODE_VAR}: the Node to run instead of <app>/{NODE_IN_APP}, for a release with {MAIN_IN_APP}.");
    std::process::exit(2);
}

fn main() {
    let given: Vec<OsString> = std::env::args_os().skip(1).collect();
    let mut args: Vec<String> = given.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    let mut take = |flag: &str| -> Option<String> {
        let i = args.iter().position(|a| a == flag)?;
        let value = args.get(i + 1).cloned();
        args.drain(i..(i + 2).min(args.len()));
        value
    };
    let data = take("--data");
    let app = take("--app");
    // What the Node part ran on, from launchers written before it went (older desktop apps): taken and let be.
    let _ = take("--node");
    let port = take("--port");
    let handoff = take("--handoff");
    let resume = take("--resume");
    let with_parent = args.iter().position(|a| a == "--with-parent").map(|i| args.remove(i)).is_some();
    match args.first().map(String::as_str) {
        Some("run") => {
            let Some(app) = app else { usage() };
            let named = port.is_some();
            let port = match port.map(|p| p.parse::<u16>()).transpose() {
                Ok(port) => port.unwrap_or(4760),
                Err(error) => {
                    eprintln!("--port: {error}");
                    std::process::exit(1);
                }
            };
            // A Rust station's handoff (its descriptors) is never ours to take: it asks handoff-version first.
            if let Some(file) = handoff {
                log::warn(&format!("a handoff file was given ({file}); this launcher reads none, starting afresh"));
                let _ = std::fs::remove_file(file);
            }
            let data = data::data_dir(&data::home(), data.or_else(|| data::var("DATA")).map(PathBuf::from));
            std::process::exit(run::run(run::Options { data, app: PathBuf::from(app), port, named, with_parent, resume }));
        }
        Some("handoff-version") => println!("{HANDOFF_VERSION}"),
        Some("enroll" | "status" | "id" | "channel" | "update" | "lock" | "heap") => {
            let app = app.map(PathBuf::from).or_else(app_of_this_binary).unwrap_or_else(|| {
                eprintln!("the release this binary belongs to (with {READER_IN_APP} or {MAIN_IN_APP}) was not found; give it as --app DIR");
                std::process::exit(1);
            });
            let station = station(&app);
            let mut command = station.command();
            command.args(&given);
            #[cfg(unix)]
            let error = command.exec();
            // No exec on Windows: the station runs as a child, its code this process's.
            #[cfg(windows)]
            let error = match command.status() {
                Ok(status) => std::process::exit(status.code().unwrap_or(1)),
                Err(error) => error,
            };
            eprintln!("{} did not run: {error}", station.program.display());
            std::process::exit(1);
        }
        _ => usage(),
    }
}

/// The release this binary is in, when not given (`stillfail status` gives none): the nearest directory above it that
/// has the station (the MoonBit station's program or, a release from before, Node's script).
fn app_of_this_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    app_above(&exe)
}

fn app_above(exe: &Path) -> Option<PathBuf> {
    exe.ancestors().skip(1).find(|dir| main_js(dir).is_file() || dir.join(READER_IN_APP).is_file()).map(Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_release_is_found_above_the_binary() {
        let dir = std::env::temp_dir().join(format!("launcher-app-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("station")).unwrap();
        std::fs::create_dir_all(dir.join("mesh/target/release")).unwrap();
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        assert_eq!(super::app_above(&dir.join("mesh/target/release/stillfail-station")), Some(dir.clone()));
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(super::app_above(std::path::Path::new("/nowhere/at/all/x")), None);
    }

    #[test]
    fn a_release_with_the_moonbit_station_alone_is_found_and_runs_it() {
        let dir = std::env::temp_dir().join(format!("launcher-app-mb-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("station")).unwrap();
        std::fs::create_dir_all(dir.join("mesh/target/release")).unwrap();
        std::fs::write(dir.join(super::READER_IN_APP), "").unwrap();
        assert_eq!(super::app_above(&dir.join("mesh/target/release/stillfail-station")), Some(dir.clone()));
        let station = super::station(&dir);
        assert_eq!((station.program, station.script), (dir.join(super::READER_IN_APP), None));
        // A release from before (rolled back to) has Node's script: Node runs it, as before.
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let station = super::station(&dir);
        assert_eq!(station.script, Some(dir.join("station/main.js")));
        assert_ne!(station.program, dir.join(super::READER_IN_APP));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_station_with_retired_moonbit_engine_starts_node_when_main_js_exists() {
        let dir = std::env::temp_dir().join(format!("launcher-app-switch-{}", std::process::id()));
        let data = dir.join("data");
        std::fs::create_dir_all(dir.join("station")).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        std::fs::write(dir.join(super::READER_IN_APP), "").unwrap();
        // not switched: Node, as the release says
        assert_eq!(super::station_of(&dir, &data).script, Some(dir.join("station/main.js")));
        // retired "engine": "moonbit" with main.js present: starts Node directly
        std::fs::write(data.join("config.json"), r#"{"engine":"moonbit"}"#).unwrap();
        assert_eq!(super::station_of(&dir, &data).script, Some(dir.join("station/main.js")));
        // without main.js (moonbit-only test layout): falls back to stillfail-reader
        std::fs::remove_file(dir.join("station/main.js")).unwrap();
        let station = super::station_of(&dir, &data);
        assert_eq!((station.program, station.script), (dir.join(super::READER_IN_APP), None));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
