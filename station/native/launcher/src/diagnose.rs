//! Best-effort bounded diagnostics of a hung Node process collected right before SIGKILL.
//!
//! Privacy boundary: only numeric metrics, process state codes, kernel wait channels, and binary/kernel symbol names
//! are kept. No filesystem paths, command-line arguments, or user text ever leave this module.

#[cfg(unix)]
use serde_json::{Map, Value};

#[cfg(unix)]
use std::io::Read;
#[cfg(unix)]
use std::process::{Command, Stdio};
#[cfg(unix)]
use std::sync::mpsc;
#[cfg(unix)]
use std::time::{Duration, Instant};

const WCHAN_MAX_BYTES: usize = 64;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const KERNEL_STACK_MAX_FRAMES: usize = 16;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const KERNEL_STACK_MAX_BYTES: usize = 800;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const MAIN_STACK_MAX_FRAMES: usize = 25;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const MAIN_STACK_MAX_BYTES: usize = 1600;
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const STACK_ELLIPSIS: &str = "… -> ";
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SAMPLE_STDOUT_MAX_BYTES: usize = 512 * 1024;
#[cfg(target_os = "macos")]
const MACOS_TOTAL_BUDGET: Duration = Duration::from_secs(3);
#[cfg(target_os = "macos")]
const MACOS_PS_TIMEOUT: Duration = Duration::from_secs(1);

/// Truncates `s` to at most `max_bytes` on a UTF-8 character boundary.
pub fn truncate_utf8(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Parses the single-letter process state from `/proc/<pid>/stat`.
///
/// The second field `(comm)` may contain spaces and `)`, so the state always follows the last `')'`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_linux_stat(text: &str) -> Option<String> {
    let close = text.rfind(')')?;
    let after = text.get(close + 1..)?;
    let state = after.split_whitespace().next()?;
    if state.len() == 1 && state.as_bytes()[0].is_ascii_alphabetic() {
        Some(state.to_string())
    } else {
        None
    }
}

/// Parses `VmRSS` (converted to bytes) and `Threads` from `/proc/<pid>/status`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_linux_status(text: &str) -> (Option<u64>, Option<u64>) {
    let mut rss_bytes = None;
    let mut threads = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            if let Some(kb) = rest.split_whitespace().next().and_then(|s| s.parse::<u64>().ok()) {
                rss_bytes = Some(kb.saturating_mul(1024));
            }
        } else if let Some(rest) = line.strip_prefix("Threads:") {
            if let Some(count) = rest.split_whitespace().next().and_then(|s| s.parse::<u64>().ok()) {
                threads = Some(count);
            }
        }
    }
    (rss_bytes, threads)
}

/// Parses kernel stack symbols from `/proc/<pid>/stack`, stripping `[<addr>]` prefixes and bounding length.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_linux_stack(text: &str) -> Option<String> {
    let mut frames = Vec::with_capacity(KERNEL_STACK_MAX_FRAMES);
    for raw in text.lines() {
        let mut line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("[<") {
            if let Some(end) = rest.find(">]") {
                line = rest[end + 2..].trim_start();
            }
        }
        let Some(sym) = line.split_whitespace().next() else { continue };
        if sym.is_empty() {
            continue;
        }
        frames.push(sym);
        if frames.len() >= KERNEL_STACK_MAX_FRAMES {
            break;
        }
    }
    if frames.is_empty() {
        return None;
    }
    let joined = frames.join(" <- ");
    Some(truncate_utf8(&joined, KERNEL_STACK_MAX_BYTES).to_string())
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Debug, Default, PartialEq)]
pub struct MacosPs {
    pub proc_state: Option<String>,
    pub pcpu: Option<f64>,
    pub rss_bytes: Option<u64>,
    pub wchan: Option<String>,
}

/// Parses `ps -o state=,pcpu=,rss=,wchan= -p <pid>` output on macOS.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn parse_macos_ps(text: &str) -> MacosPs {
    let mut out = MacosPs::default();
    let Some(line) = text.lines().map(str::trim).find(|l| !l.is_empty()) else {
        return out;
    };
    let mut parts = line.split_whitespace();
    if let Some(state) = parts.next() {
        if !state.is_empty() {
            out.proc_state = Some(truncate_utf8(state, 16).to_string());
        }
    }
    if let Some(cpu) = parts.next().and_then(|s| s.parse::<f64>().ok()).filter(|v| v.is_finite() && *v >= 0.0) {
        out.pcpu = Some(cpu);
    }
    if let Some(kb) = parts.next().and_then(|s| s.parse::<u64>().ok()) {
        out.rss_bytes = Some(kb.saturating_mul(1024));
    }
    let wchan = parts.collect::<Vec<_>>().join(" ");
    let wchan = wchan.trim();
    if !wchan.is_empty() && wchan != "-" {
        out.wchan = Some(truncate_utf8(wchan, WCHAN_MAX_BYTES).to_string());
    }
    out
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn is_hex_address(tok: &str) -> bool {
    let Some(hex) = tok.strip_prefix("0x").or_else(|| tok.strip_prefix("0X")) else {
        return false;
    };
    !hex.is_empty() && hex.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Sanitizes the body of a macOS `sample` call-graph frame (after tree prefix and sample count):
/// strips `[0x...]`, `+ offset`, directory paths inside `(in ...)` (even when directories contain `)`),
/// stray path tokens, and unsymbolicated `0x...` addresses.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn sanitize_sample_frame_body(body: &str) -> Option<String> {
    let mut frame = body.trim();
    if frame.is_empty() {
        return None;
    }
    // Strip trailing address block `[0x...]` (and anything after it, such as load address annotations).
    if let Some(idx) = frame.find("[0x") {
        frame = frame[..idx].trim_end();
    }
    // Strip trailing `+ <offset>` (decimal or hex).
    if let Some(idx) = frame.rfind(" + ") {
        let offset = frame[idx + 3..].trim();
        let is_offset = !offset.is_empty()
            && (offset.bytes().all(|b| b.is_ascii_digit()) || is_hex_address(offset));
        if is_offset {
            frame = frame[..idx].trim_end();
        }
    }
    if frame.is_empty() {
        return None;
    }
    // After stripping `[0x...]` and `+ offset`, `(in ...)` sits at the end: match `rfind("(in ")` with the final `)`
    // so directory names containing `)` (e.g. `/Users/a (work)/lib/x.node`) never truncate early or leak paths.
    let stripped_in = if let Some(in_start) = frame.rfind("(in ") {
        let after_in = &frame[in_start + 4..];
        if let Some(close) = after_in.rfind(')') {
            let module = &after_in[..close];
            let base = if module.contains('/') || module.contains('\\') {
                module.rsplit(['/', '\\']).next().unwrap_or(module)
            } else {
                module
            };
            format!("{}(in {}){}", &frame[..in_start], base, &after_in[close + 1..])
        } else {
            frame.to_string()
        }
    } else {
        frame.to_string()
    };

    let mut tokens = Vec::new();
    for tok in stripped_in.split_whitespace() {
        if is_hex_address(tok) {
            tokens.push("???".to_string());
        } else if tok.starts_with('/') || tok.contains('\\') {
            let base = tok.rsplit(['/', '\\']).next().unwrap_or(tok);
            if !base.is_empty() {
                tokens.push(base.to_string());
            }
        } else {
            tokens.push(tok.to_string());
        }
    }
    let collapsed = tokens.join(" ");
    if collapsed.is_empty() { None } else { Some(collapsed) }
}

/// Parses `(indent_width, sample_count, sanitized_frame)` from one frame line in a `sample` Call graph block.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn parse_sample_frame_line(line: &str) -> Option<(usize, u64, String)> {
    let prefix_len = line
        .bytes()
        .take_while(|b| b.is_ascii_whitespace() || matches!(b, b'+' | b'!' | b':' | b'|'))
        .count();
    let rest = &line[prefix_len..];
    if rest.is_empty() {
        return None;
    }
    let digits_len = rest.bytes().take_while(u8::is_ascii_digit).count();
    let (count, body) = if digits_len > 0 {
        let count = rest[..digits_len].parse::<u64>().unwrap_or(0);
        (count, rest[digits_len..].trim_start())
    } else {
        (0, rest)
    };
    let frame = sanitize_sample_frame_body(body)?;
    Some((prefix_len, count, frame))
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn is_sample_thread_header(trimmed: &str) -> bool {
    let after_digits = trimmed.trim_start_matches(|c: char| c.is_ascii_digit());
    after_digits.len() < trimmed.len() && after_digits.trim_start().starts_with("Thread_")
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
struct SampleNode {
    indent: usize,
    count: u64,
    frame: String,
    children: Vec<usize>,
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn pick_heaviest(indices: &[usize], nodes: &[SampleNode]) -> Option<usize> {
    let mut best: Option<usize> = None;
    for &idx in indices {
        if best.is_none_or(|b| nodes[idx].count > nodes[b].count) {
            best = Some(idx);
        }
    }
    best
}

/// Extracts and sanitizes the heaviest single root-to-leaf path of the main thread from macOS `sample` output.
///
/// Preserves the leaf end (up to `MAIN_STACK_MAX_FRAMES` frames and `MAIN_STACK_MAX_BYTES` bytes), dropping outer
/// root frames and prefixing `"… -> "` when truncated so the blocking leaf frame stays intact.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn parse_macos_sample_main_stack(text: &str) -> Option<String> {
    let mut in_graph = false;
    let mut blocks: Vec<(bool, Vec<&str>)> = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if !in_graph {
            if trimmed == "Call graph:" {
                in_graph = true;
            }
            continue;
        }
        if trimmed.is_empty() || trimmed.starts_with("Total number in stack") || trimmed.starts_with("Binary Images:") {
            if !blocks.is_empty() {
                break;
            }
            continue;
        }
        if is_sample_thread_header(trimmed) {
            blocks.push((trimmed.contains("com.apple.main-thread"), Vec::new()));
        } else if let Some((_, frames)) = blocks.last_mut() {
            frames.push(line);
        }
    }
    let (_, raw_frames) = blocks.iter().find(|(is_main, _)| *is_main).or_else(|| blocks.first())?;

    // Reconstruct the call tree by indentation width so sibling branches are never concatenated.
    let mut nodes: Vec<SampleNode> = Vec::new();
    let mut roots: Vec<usize> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    for raw in raw_frames {
        let Some((indent, count, frame)) = parse_sample_frame_line(raw) else { continue };
        while stack.last().is_some_and(|&top| nodes[top].indent >= indent) {
            stack.pop();
        }
        let idx = nodes.len();
        nodes.push(SampleNode { indent, count, frame, children: Vec::new() });
        if let Some(&parent) = stack.last() {
            nodes[parent].children.push(idx);
        } else {
            roots.push(idx);
        }
        stack.push(idx);
    }

    // Walk the single heaviest root-to-leaf path (tie-break: first seen).
    let mut path: Vec<&str> = Vec::new();
    let mut cur = pick_heaviest(&roots, &nodes);
    while let Some(idx) = cur {
        path.push(&nodes[idx].frame);
        cur = pick_heaviest(&nodes[idx].children, &nodes);
    }
    if path.is_empty() {
        return None;
    }

    // Keep the leaf tail up to MAIN_STACK_MAX_FRAMES and MAIN_STACK_MAX_BYTES.
    let dropped_root = path.len() > MAIN_STACK_MAX_FRAMES;
    let tail = if dropped_root { &path[path.len() - MAIN_STACK_MAX_FRAMES..] } else { &path[..] };

    if !dropped_root {
        let full = tail.join(" -> ");
        if full.len() <= MAIN_STACK_MAX_BYTES {
            return Some(full);
        }
    }

    // Drop outermost root frames until `"… -> "` + tail fits within MAIN_STACK_MAX_BYTES.
    for start in 0..tail.len() {
        let candidate = format!("{STACK_ELLIPSIS}{}", tail[start..].join(" -> "));
        if candidate.len() <= MAIN_STACK_MAX_BYTES {
            return Some(candidate);
        }
    }

    // Only when the single leaf frame itself exceeds MAIN_STACK_MAX_BYTES do we truncate that frame.
    let leaf = tail.last().copied().unwrap_or_default();
    let budget = MAIN_STACK_MAX_BYTES.saturating_sub(STACK_ELLIPSIS.len());
    Some(format!("{STACK_ELLIPSIS}{}", truncate_utf8(leaf, budget)))
}

/// Collects `/proc/<pid>` diagnostics on Linux (<1 ms, no subprocesses).
#[cfg(target_os = "linux")]
pub fn collect(pid: i32) -> Map<String, Value> {
    let mut out = Map::new();
    if pid <= 0 {
        return out;
    }
    let base = format!("/proc/{pid}");
    if let Ok(stat) = std::fs::read_to_string(format!("{base}/stat")) {
        if let Some(state) = parse_linux_stat(&stat) {
            out.insert("procState".into(), state.into());
        }
    }
    if let Ok(wchan) = std::fs::read_to_string(format!("{base}/wchan")) {
        let wchan = wchan.trim_matches(|c: char| c.is_whitespace() || c == '\0');
        if !wchan.is_empty() {
            out.insert("wchan".into(), truncate_utf8(wchan, WCHAN_MAX_BYTES).into());
        }
    }
    if let Ok(status) = std::fs::read_to_string(format!("{base}/status")) {
        let (rss_bytes, threads) = parse_linux_status(&status);
        if let Some(rss) = rss_bytes {
            out.insert("rssBytes".into(), rss.into());
        }
        if let Some(t) = threads {
            out.insert("threads".into(), t.into());
        }
    }
    if let Ok(entries) = std::fs::read_dir(format!("{base}/fd")) {
        out.insert("openFds".into(), (entries.count() as u64).into());
    }
    if let Ok(stack) = std::fs::read_to_string(format!("{base}/stack")) {
        if let Some(kernel_stack) = parse_linux_stack(&stack) {
            out.insert("kernelStack".into(), kernel_stack.into());
        }
    }
    out
}

/// Runs a subprocess with a strict wall-clock deadline, killing and reaping it on timeout.
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn run_bounded(mut cmd: Command, timeout: Duration) -> Option<String> {
    if timeout.is_zero() {
        return None;
    }
    let deadline = Instant::now() + timeout;
    let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.take(SAMPLE_STDOUT_MAX_BYTES as u64).read_to_end(&mut buf);
        let _ = tx.send(buf);
    });
    match rx.recv_timeout(timeout) {
        Ok(buf) => {
            // Poll try_wait bounded by remaining deadline (capped at 200 ms) so a child whose stdout exceeded
            // SAMPLE_STDOUT_MAX_BYTES never blocks the launcher.
            let wait_deadline = deadline.min(Instant::now() + Duration::from_millis(200));
            loop {
                match child.try_wait() {
                    Ok(Some(_)) | Err(_) => break,
                    Ok(None) => {
                        let left = wait_deadline.saturating_duration_since(Instant::now());
                        if left.is_zero() {
                            let _ = child.kill();
                            let _ = child.wait();
                            break;
                        }
                        std::thread::sleep(left.min(Duration::from_millis(10)));
                    }
                }
            }
            Some(String::from_utf8_lossy(&buf).into_owned())
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

/// Collects bounded `ps` and `sample` diagnostics on macOS (strictly <= 3 s total).
#[cfg(target_os = "macos")]
pub fn collect(pid: i32) -> Map<String, Value> {
    let mut out = Map::new();
    if pid <= 0 {
        return out;
    }
    let deadline = Instant::now() + MACOS_TOTAL_BUDGET;
    let pid_arg = pid.to_string();

    let mut ps_cmd = Command::new("/bin/ps");
    ps_cmd.args(["-o", "state=,pcpu=,rss=,wchan=", "-p", &pid_arg]);
    if let Some(ps_text) = run_bounded(ps_cmd, MACOS_PS_TIMEOUT.min(deadline.saturating_duration_since(Instant::now()))) {
        let parsed = parse_macos_ps(&ps_text);
        if let Some(state) = parsed.proc_state {
            out.insert("procState".into(), state.into());
        }
        if let Some(pcpu) = parsed.pcpu {
            out.insert("pcpu".into(), pcpu.into());
        }
        if let Some(rss) = parsed.rss_bytes {
            out.insert("rssBytes".into(), rss.into());
        }
        if let Some(wchan) = parsed.wchan {
            out.insert("wchan".into(), wchan.into());
        }
    }

    let remaining = deadline.saturating_duration_since(Instant::now());
    if !remaining.is_zero() {
        // `-file /dev/stdout` avoids macOS `sample` writing a full-path `.sample.txt` report to `/tmp`.
        let mut sample_cmd = Command::new("/usr/bin/sample");
        sample_cmd.args([&pid_arg, "1", "-mayDie", "-file", "/dev/stdout"]);
        if let Some(sample_text) = run_bounded(sample_cmd, remaining) {
            if let Some(stack) = parse_macos_sample_main_stack(&sample_text) {
                out.insert("mainStack".into(), stack.into());
            }
        }
    }

    out
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
pub fn collect(_pid: i32) -> Map<String, Value> {
    Map::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_stat_handles_spaces_and_parens_in_comm() {
        assert_eq!(parse_linux_stat("12345 (node) S 1 12345 12345 0 -1"), Some("S".into()));
        assert_eq!(parse_linux_stat("42 (weird (app) name) D 1 42 42 0 -1"), Some("D".into()));
        assert_eq!(parse_linux_stat("99 (node (worker)) R 1 99"), Some("R".into()));
        assert_eq!(parse_linux_stat("broken"), None);
        assert_eq!(parse_linux_stat("12 (node)"), None);
    }

    #[test]
    fn linux_status_parses_vmrss_and_threads() {
        let sample = "Name:\tnode\nState:\tS (sleeping)\nVmPeak:\t2000000 kB\nVmRSS:\t 512000 kB\nThreads:\t18\n";
        assert_eq!(parse_linux_status(sample), (Some(512000 * 1024), Some(18)));
        assert_eq!(parse_linux_status("Name:\tnode\n"), (None, None));
    }

    #[test]
    fn linux_stack_strips_addresses_caps_frames_and_truncates_safely() {
        let sample = "\
[<0>] futex_wait_queue+0x60/0x90
[<ffffffff81123456>] futex_wait+0x170/0x260
[<0>] do_futex+0x120/0x1a0
[<0>] __x64_sys_futex+0x127/0x190
";
        assert_eq!(
            parse_linux_stack(sample),
            Some("futex_wait_queue+0x60/0x90 <- futex_wait+0x170/0x260 <- do_futex+0x120/0x1a0 <- __x64_sys_futex+0x127/0x190".into())
        );

        let long_lines: String = (0..30).map(|i| format!("[<0>] very_long_kernel_symbol_name_for_frame_{i:02}_padding_padding_padding+0x10/0x20\n")).collect();
        let parsed = parse_linux_stack(&long_lines).unwrap();
        assert!(parsed.len() <= KERNEL_STACK_MAX_BYTES);
        assert!(parsed.contains("frame_00"));
        assert!(!parsed.contains("frame_20"));
        assert_eq!(parse_linux_stack("   \n\n"), None);
    }

    #[test]
    fn macos_ps_parses_state_cpu_rss_and_wchan() {
        assert_eq!(
            parse_macos_ps("  R+   99.8  716800  -\n"),
            MacosPs { proc_state: Some("R+".into()), pcpu: Some(99.8), rss_bytes: Some(716800 * 1024), wchan: None }
        );
        assert_eq!(
            parse_macos_ps("  S     0.4  123456  psynch_cvwait\n"),
            MacosPs { proc_state: Some("S".into()), pcpu: Some(0.4), rss_bytes: Some(123456 * 1024), wchan: Some("psynch_cvwait".into()) }
        );
        assert_eq!(parse_macos_ps(""), MacosPs::default());
    }

    #[test]
    fn macos_sample_follows_heaviest_branch_without_mixing_siblings() {
        let sample = "\
Sampling process 4242 for 1 second with 1 millisecond of run time between samples
Analysis of sampling node (pid 4242) every 1 millisecond
Process:         node [4242]
Path:            /Users/alice/.stillfail/app/node/bin/node

Call graph:
    998 Thread_10001
    + 998 thread_start  (in libsystem_pthread.dylib) + 8  [0x1956a1234]
    823 Thread_10000   DispatchQueue_1: com.apple.main-thread  (serial)
    + 823 start  (in dyld) + 2840  [0x19532c274]
    +   823 main  (in /Users/alice/.stillfail/app/node/bin/node) + 123  [0x104a1b2c0]
    +     823 uv_run  (in /Users/alice/.stillfail/app/mesh/mesh.node) + 0x140  [0x105123456]
    +       1 uv__run_timers  (in node) + 40  [0x105123600]
    +       ! 1 v8::Function::Call  (in node) + 12  [0x105123700]
    +       822 uv__io_poll  (in node) + 100  [0x105123500]
    +         822 kevent  (in libsystem_kernel.dylib) + 8  [0x195678900]

Total number in stack (recursive counted multiple, when >=5):
";
        let stack = parse_macos_sample_main_stack(sample).unwrap();
        assert_eq!(
            stack,
            "start (in dyld) -> main (in node) -> uv_run (in mesh.node) -> uv__io_poll (in node) -> kevent (in libsystem_kernel.dylib)"
        );
        assert!(!stack.contains("uv__run_timers"));
        assert!(!stack.contains("v8::Function::Call"));
        assert!(!stack.contains("/Users/"));
        assert!(!stack.contains("0x"));
    }

    #[test]
    fn macos_sample_keeps_leaf_tail_and_prefixes_ellipsis_when_deep_or_long() {
        // 35 frames: must keep the bottom 25 leaf frames, drop outer roots (`start`, `main`), and prefix `… -> `.
        let mut deep = String::from("Call graph:\n    100 Thread_20000   DispatchQueue_1: com.apple.main-thread\n");
        for depth in 0..35 {
            let indent = "  ".repeat(depth);
            let name = match depth {
                0 => "start".to_string(),
                1 => "main".to_string(),
                34 => "blocking_leaf_syscall".to_string(),
                n => format!("frame_{n:02}"),
            };
            deep.push_str(&format!("    + {indent}100 {name}  (in node) + 8  [0x1000]\n"));
        }
        let parsed = parse_macos_sample_main_stack(&deep).unwrap();
        assert!(parsed.starts_with(STACK_ELLIPSIS));
        assert!(parsed.ends_with("blocking_leaf_syscall (in node)"));
        assert!(!parsed.contains("start (in node)"));
        assert!(!parsed.contains("main (in node)"));
        assert!(parsed.len() <= MAIN_STACK_MAX_BYTES);

        // Long frames exceeding 1600 bytes: must drop outer frames and keep the blocking leaf intact with valid UTF-8.
        let mut long_stack = String::from("Call graph:\n    50 Thread_20001\n");
        for depth in 0..20 {
            let indent = "  ".repeat(depth);
            let name = if depth == 19 {
                "leaf_阻塞函数_kevent".to_string()
            } else {
                format!("outer_{depth:02}_{}", "é".repeat(50))
            };
            long_stack.push_str(&format!("    + {indent}50 {name} (in /private/tmp/app.dylib) + 16 [0x1234]\n"));
        }
        let truncated = parse_macos_sample_main_stack(&long_stack).unwrap();
        assert!(truncated.starts_with(STACK_ELLIPSIS));
        assert!(truncated.ends_with("leaf_阻塞函数_kevent (in app.dylib)"));
        assert!(truncated.len() <= MAIN_STACK_MAX_BYTES);
        assert!(truncated.is_char_boundary(truncated.len()));
        assert!(!truncated.contains("/private/tmp/"));
        assert!(!truncated.contains("0x1234"));
    }

    #[test]
    fn macos_sample_strips_parens_in_paths_and_unsymbolicated_hex_frames() {
        let sample = "\
Call graph:
    10 Thread_30000   DispatchQueue_1: com.apple.main-thread
    + 10 0x104abc  (in node)  [0x104abc]
    +   10 native_call  (in /Users/a (work)/lib/x.node) + 24  [0x110000123]
";
        let stack = parse_macos_sample_main_stack(sample).unwrap();
        assert_eq!(stack, "??? (in node) -> native_call (in x.node)");
        assert!(!stack.contains("0x"));
        assert!(!stack.contains("/Users/"));
        assert!(!stack.contains("(work)"));
    }

    #[cfg(unix)]
    #[test]
    fn run_bounded_kills_and_reaps_timed_out_child() {
        let started = Instant::now();
        let mut cmd = Command::new("/bin/sleep");
        cmd.arg("5");
        let out = run_bounded(cmd, Duration::from_millis(100));
        assert!(out.is_none());
        assert!(started.elapsed() < Duration::from_secs(2), "timed out child should be killed promptly");
    }
}
