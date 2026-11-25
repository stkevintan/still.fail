import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, chmodSync, closeSync, constants, existsSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { open as openAsync, type FileHandle } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, sep } from "node:path";
import { test } from "node:test";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import type { ReaderSelectConfig } from "../src/read/reader-select.ts";
import { Search } from "../src/search/search.ts";
import { packFile } from "../src/sessions/archive.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";

function resolveDualBinaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion || requireDual) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is required (${explicitPion ?? "unset"}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(realPion, ["--version"], { encoding: "utf8" });
  const m = ver.match(/modes:([^\n\r]+)/);
  const modes = m ? m[1]!.split(",").map((s) => s.trim()).filter(Boolean) : [];
  assert.ok(modes.includes("search"), `Pion --version modes list must include exact token "search": ${ver}`);
  return { mb: realMb, pion: realPion };
}

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
}

class RawLineClient {
  readonly child: ReturnType<typeof spawn>;
  #buf = "";
  #lines: string[] = [];
  #waiters: ((line: string) => void)[] = [];

  constructor(bin: string, args: string[]) {
    this.child = spawn(bin, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.child.stdout!.setEncoding("utf8");
    this.child.stdout!.on("data", (chunk: string) => {
      this.#buf += chunk;
      for (;;) {
        const nl = this.#buf.indexOf("\n");
        if (nl < 0) break;
        const line = this.#buf.slice(0, nl);
        this.#buf = this.#buf.slice(nl + 1);
        const w = this.#waiters.shift();
        if (w) w(line);
        else this.#lines.push(line);
      }
    });
  }

  writeRaw(text: string): void {
    this.child.stdin!.write(text);
  }

  send(obj: unknown): void {
    this.child.stdin!.write(`${JSON.stringify(obj)}\n`);
  }

  sendAndFlush(obj: unknown): Promise<void> {
    return new Promise((resolve, reject) => {
      this.child.stdin!.write(`${JSON.stringify(obj)}\n`, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }

  nextLine(): Promise<string> {
    if (this.#lines.length > 0) return Promise.resolve(this.#lines.shift()!);
    return new Promise((resolve, reject) => {
      const onExit = (code: number | null) => {
        reject(new Error(`process exited prematurely (code=${code}) while awaiting line`));
      };
      this.child.once("exit", onExit);
      this.#waiters.push((line) => {
        this.child.off("exit", onExit);
        resolve(line);
      });
    });
  }

  async nextJson(): Promise<any> {
    return JSON.parse(await this.nextLine());
  }

  async close(): Promise<void> {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return;
    await new Promise<void>((resolve) => {
      this.child.once("exit", () => resolve());
      this.child.stdin!.end();
    });
  }
}

function makeFixture(opts: { multiChunkHistory?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "w6-search-switch-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath, join(dir, "archive"));

  const addSession = (key: string, runtime: string, ws: string | null, lastActiveAt: number) => {
    store.insertSession({
      key,
      connect: "ember",
      runtime,
      profile: "cc",
      workspace: `/w/${key}`,
      token: `tok-${key}`,
      createdAt: 1,
      lastActiveAt,
      ws,
    } as Parameters<Store["insertSession"]>[0]);
  };

  addSession("s-chat", "claude", "W1", 10);
  const tid = store.openThreadOf("ember", "ember", "s-chat", null, "a@x", "s-chat").id;
  store.joinThread(tid, "s-chat", "ember");

  // Populate 1,800 messages across 8 batches (256/batch) so a message scan yields >= 7 times at P1.
  let ts = 0;
  for (let i = 0; i < 1800; i++) {
    const body = i === 1750 ? "slowneedle final batch hit" : `filler message number ${i} padding text`;
    store.insertMessage({ ...newMessage(tid, String(++ts), "person", "a@x", body) } as ReturnType<typeof newMessage>);
  }
  // Message whose UTF-16 excerpt boundary cuts right through a surrogate pair (😀 at units 2..3, needle at unit 83).
  store.insertMessage({
    ...newMessage(tid, String(++ts), "person", "a@x", `xx😀${"a".repeat(79)}surrogateneedle`),
  } as ReturnType<typeof newMessage>);

  // Distinguishable profiles for fast single-step queries & 1 vs 1.0 vs "1" assertions.
  writeFileSync(
    join(dir, "config.json"),
    JSON.stringify({
      profiles: [
        { id: "fastprof", home: "homes/fast", runtime: "claude", name: "FastProfileHit" },
        { id: "prof-alpha", home: "homes/alpha", runtime: "claude", name: "ProfileAlphaHit" },
        { id: "prof-beta", home: "homes/beta", runtime: "claude", name: "ProfileBetaHit" },
      ],
    }),
  );

  const put = (path: string, text: string) => {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  };

  // Real >8 MiB multi-chunk transcripts (Rust shell TEXT_PART = 8 MiB -> 2 chunks across P11!).
  // Combined with the single-writeRaw POSIX FIFO MEMORY.md kernel barrier, A and B are mathematically
  // guaranteed to pause at P11 in Round 3 right before qGate blocks the event loop in kernel `read(fifo)`.
  const chunkLine = `${JSON.stringify({ type: "assistant", message: { content: "x".repeat(4000) } })}\n`;
  const repeats = opts.multiChunkHistory ? 2200 : 80; // 2200 * ~4060B ≈ 8.93 MiB -> 2 x 8 MiB chunks

  // Isolate h-a (WA) and h-b (WB) into distinct workspaces so query A ONLY scans ha1.jsonl
  // and query B ONLY scans hb1.jsonl during dual-handle P11 concurrency verification.
  addSession("h-a", "claude", "WA", 100);
  store.ranIn("h-a", "ha1", "cc");
  store.setRuntimeSessionId("h-a", "ha1");
  const bigA =
    chunkLine.repeat(repeats) +
    `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T10:00:00Z", message: { content: "alphaonlytoken" } })}\n`;
  put(join(dir, "transcripts", "claude", "-w-h-a", "ha1.jsonl"), bigA);

  addSession("h-b", "claude", "WB", 90);
  store.ranIn("h-b", "hb1", "cc");
  store.setRuntimeSessionId("h-b", "hb1");
  const bHead = `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T10:30:00Z", message: { content: "betafirstchunk" } })}\n`;
  const bigB =
    bHead +
    chunkLine.repeat(repeats) +
    `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T11:00:00Z", message: { content: "betafirstchunk betaonlytoken overlapcheck" } })}\n`;
  put(join(dir, "transcripts", "claude", "-w-h-b", "hb1.jsonl"), bigB);

  // Small history transcript with a plain keyword + raw JSON-escaped lone surrogates (\ud800 and \ude00).
  addSession("h-surr", "claude", "W1", 80);
  store.ranIn("h-surr", "hs1", "cc");
  store.setRuntimeSessionId("h-surr", "hs1");
  put(
    join(dir, "transcripts", "claude", "-w-h-surr", "hs1.jsonl"),
    `{"type":"assistant","timestamp":"2026-11-01T12:00:00Z","message":{"content":"surrogatehisttoken \\ud800 mid \\ude00 end"}}\n`,
  );

  // Cursor assistant transcript with raw JSON-escaped lone surrogate (\ud800).
  addSession("h-cursor", "cursor", "W1", 75);
  store.ranIn("h-cursor", "cu1", "cc");
  store.setRuntimeSessionId("h-cursor", "cu1");
  put(
    join(dir, "transcripts", "cursor", "cu1.jsonl"),
    `{"type":"assistant","time":1700000000000,"text":"cursorneedle \\ud800 end"}\n`,
  );

  // Claude transcript: 4000 leading spaces + <command-name> user record MUST be filtered BEFORE 4000-code-point clipping,
  // so the following assistant record lands at entry index 0 on both MB and Pion!
  addSession("h-cmd", "claude", "W1", 70);
  store.ranIn("h-cmd", "hc1", "cc");
  store.setRuntimeSessionId("h-cmd", "hc1");
  put(
    join(dir, "transcripts", "claude", "-w-h-cmd", "hc1.jsonl"),
    [
      JSON.stringify({ type: "user", timestamp: "2026-11-01T12:00:00Z", message: { role: "user", content: `${" ".repeat(4000)}<command-name>/clear</command-name>` } }),
      JSON.stringify({ type: "assistant", timestamp: "2026-11-01T12:00:01Z", message: { content: "cmdfilterneedle hit after filtered command" } }),
      "",
    ].join("\n"),
  );

  // POSIX FIFO barrier at `<data>/agent/workspaces/WG/MEMORY.md` for zero-race P11 interception on Linux/macOS.
  let fifoPath: string | null = null;
  if (opts.multiChunkHistory && process.platform !== "win32") {
    const wgDir = join(dir, "agent", "workspaces", "WG");
    mkdirSync(wgDir, { recursive: true });
    fifoPath = join(wgDir, "MEMORY.md");
    execFileSync("mkfifo", [fifoPath]);
  }

  return {
    dir,
    dbPath,
    store,
    fifoPath,
    close: () => {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

function openFdTargets(pid: number): string[] | null {
  if (process.platform !== "linux") return null;
  // On Linux, never swallow /proc errors (test must fail loudly if /proc/<pid>/fd is unreadable).
  const out: string[] = [];
  for (const fd of readdirSync(`/proc/${pid}/fd`)) {
    out.push(readlinkSync(`/proc/${pid}/fd/${fd}`));
  }
  return out;
}

function openFdCount(pid: number): number | null {
  if (process.platform !== "linux") return null;
  return readdirSync(`/proc/${pid}/fd`).length;
}

test("deterministic no-sleep concurrency: fast query B overtakes slow A; POSIX FIFO MEMORY.md barrier dual-FD P11 interleaved cancel A preserves B with strict 0 FD leak", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const fx = makeFixture({ multiChunkHistory: true });
  const asker = { workspace: "W1", home: true, scopes: [] };
  const askerA = { workspace: "WA", home: false, scopes: [] };
  const askerB = { workspace: "WB", home: false, scopes: [] };
  const askerG = { workspace: "WG", home: true, scopes: [] };
  const client = new RawLineClient(bins.pion, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
  const pid = client.child.pid!;

  /// Run `body()` while the Pion event loop is strictly kernel-blocked inside `std::fs::read(fifoPath)`.
  /// `qGate` (`kinds: ["chat", "memory"]`, `askerG` with `home: true`) is written in the SAME single chunk
  /// right behind the history queries so there is ZERO parent-wakeup scheduling race:
  ///   Round 1: history queries yield P9; qGate finishes the 1-thread page and yields P3 (`ThreadsAfterPage`).
  ///   Round 2: history queries yield P12; qGate scans `home` (`None`) memory and yields P7 (`MemoryWalk`).
  ///   Round 3: history queries open their >8 MiB transcripts and yield P11 (holding open FDs!);
  ///            qGate opens `agent/workspaces/WG/MEMORY.md` (FIFO) -> unlocks `gateEntered` and
  ///            blocks the entire single-threaded Pion event loop in kernel `read(fifo)` until `gateFh.close()`!
  const withFifoBarrier = async (prefixLines: string, gateId: number, body: () => Promise<void>) => {
    assert.ok(fx.fifoPath !== null, "POSIX FIFO barrier requires POSIX platform");
    let gateFh: FileHandle | null = null;
    const gateEntered = openAsync(fx.fifoPath, "w");
    try {
      const qGate = JSON.stringify({ type: "query", id: gateId, query: "gateunused", asker: askerG, kinds: ["chat", "memory"] });
      client.writeRaw(`${prefixLines}${qGate}\n`);
      gateFh = await gateEntered;
      await body();
    } finally {
      if (gateFh !== null) {
        const fh = gateFh;
        gateFh = null;
        await fh.close();
      } else if (fx.fifoPath !== null) {
        // Unblock any pending libuv O_WRONLY open on early error exit so the test never hangs.
        try {
          const fd = openSync(fx.fifoPath, constants.O_RDONLY | constants.O_NONBLOCK);
          closeSync(fd);
        } catch {
          // ignore
        }
        await gateEntered.then((fh) => fh.close()).catch(() => {});
      }
    }
  };

  try {
    // 1. Slow message scan (A, id=1) + fast profile query (B, id=2) sent back-to-back in one write:
    //    B finishes in 2 steps (ProfileRun -> FinalPause), while A yields >= 7 times across P1 message batches.
    const qSlow = JSON.stringify({ type: "query", id: 1, query: "slowneedle", asker, kinds: ["message"] });
    const qFast = JSON.stringify({ type: "query", id: 2, query: "FastProfileHit", asker, kinds: ["profile"] });
    client.writeRaw(`${qSlow}\n${qFast}\n`);

    const replies1: any[] = [];
    while (replies1.length < 2) {
      const m = await client.nextJson();
      if ("scopePending" in m || "sessionListPending" in m) continue;
      replies1.push(m);
    }
    assert.equal(replies1[0].id, 2, `fast query B must finish before slow query A; got order ${JSON.stringify(replies1.map((r) => r.id))}`);
    assert.equal(replies1[0].groups[0].kind, "profile");
    assert.equal(replies1[1].id, 1);
    assert.equal(replies1[1].groups[0].kind, "message");

    // 2. Real >8 MiB isolated-workspace dual-FD P11 interleaving with single-writeRaw POSIX FIFO kernel barrier:
    //    Query A (askerA -> WA) ONLY scans ha1.jsonl; Query B (askerB -> WB) ONLY scans hb1.jsonl.
    //    Written in ONE chunk with qGate(13) -> Round 3 freezes Pion in kernel `read(fifo)` right after A & B enter P11!
    const fdBase = openFdCount(pid);
    const qHistA = JSON.stringify({ type: "query", id: 10, query: "alphaonlytoken", asker: askerA, kinds: ["history"] });
    const qHistB = JSON.stringify({ type: "query", id: 11, query: "betafirstchunk betaonlytoken overlapcheck", asker: askerB, kinds: ["history"] });

    if (fx.fifoPath !== null) {
      await withFifoBarrier(`${qHistA}\n${qHistB}\n`, 13, async () => {
        if (process.platform === "linux") {
          const midP11Targets = openFdTargets(pid)!;
          assert.ok(
            midP11Targets.some((t) => t.endsWith("ha1.jsonl")),
            `expected ha1.jsonl open in /proc/${pid}/fd while kernel-blocked at FIFO P11 barrier; got ${JSON.stringify(midP11Targets)}`,
          );
          assert.ok(
            midP11Targets.some((t) => t.endsWith("hb1.jsonl")),
            `expected hb1.jsonl open in /proc/${pid}/fd while kernel-blocked at FIFO P11 barrier; got ${JSON.stringify(midP11Targets)}`,
          );
        }
        // Flush cancel A into stdin pipe while Pion is STILL kernel-blocked in read(fifo)!
        await client.sendAndFlush({ type: "cancel", id: 10 });
      });
    } else {
      client.writeRaw(`${qHistA}\n${qHistB}\n`);
      await client.sendAndFlush({ type: "cancel", id: 10 });
    }

    const expectedIds = fx.fifoPath !== null ? 3 : 2;
    const histReplies = new Map<number, any>();
    while (histReplies.size < expectedIds) {
      const m = await client.nextJson();
      if ("scopePending" in m || "sessionListPending" in m) continue;
      histReplies.set(m.id, m);
    }
    if (fx.fifoPath !== null) {
      assert.equal(histReplies.get(13)?.error, undefined, "FIFO memory gate query must finish cleanly");
    }
    assert.equal(histReplies.get(10)?.error, "the search took too long");
    assert.equal(histReplies.get(11)?.error, undefined);
    assert.equal(histReplies.get(11)?.groups?.length, 1);
    assert.equal(histReplies.get(11)?.groups[0].kind, "history");
    assert.equal(histReplies.get(11)?.groups[0].hits.length, 1);
    assert.ok(histReplies.get(11)?.groups[0].hits[0].text.includes("betaonlytoken"));

    // 3. Repeated FIFO-barrier-verified mid-P11 cancellations across 4 >8 MiB history queries -> STRICT 0 FD leak.
    for (let i = 0; i < 4; i++) {
      const qid = 100 + i * 2;
      const gid = 101 + i * 2;
      const qLine = `${JSON.stringify({ type: "query", id: qid, query: "alphaonlytoken", asker: askerA, kinds: ["history"] })}\n`;
      if (fx.fifoPath !== null) {
        await withFifoBarrier(qLine, gid, async () => {
          if (process.platform === "linux") {
            const targets = openFdTargets(pid)!;
            assert.ok(
              targets.some((t) => t.endsWith("ha1.jsonl")),
              `iteration ${i}: expected ha1.jsonl open in /proc/${pid}/fd at FIFO barrier; got ${JSON.stringify(targets)}`,
            );
          }
          await client.sendAndFlush({ type: "cancel", id: qid });
        });
        const pair = new Map<number, any>();
        while (pair.size < 2) {
          const m = await client.nextJson();
          if ("scopePending" in m || "sessionListPending" in m) continue;
          pair.set(m.id, m);
        }
        assert.equal(pair.get(gid)?.error, undefined);
        assert.equal(pair.get(qid)?.error, "the search took too long");
      } else {
        client.writeRaw(qLine);
        await client.sendAndFlush({ type: "cancel", id: qid });
        const ans = await client.nextJson();
        assert.equal(ans.id, qid);
        assert.equal(ans.error, "the search took too long");
      }
    }
    const fdAfter = openFdCount(pid);
    if (fdBase !== null && fdAfter !== null) {
      assert.equal(fdAfter, fdBase, `expected strict 0 FD leak across FIFO-barrier >8 MiB P11 cancellations: before=${fdBase} after=${fdAfter}`);
    }
  } finally {
    await client.close();
    fx.close();
  }
});

test("protocol & wire 0-diff vs real MB: unknown/finished cancel silent, distinguishable 1 vs 1.0 vs string id, lone-surrogate query, same-chunk cancel, message & history lone-surrogate excerpt", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const fx = makeFixture();
  const asker = { workspace: "W1", home: true, scopes: [] };

  const runSharedScenario = async (bin: string) => {
    const c = new RawLineClient(bin, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    try {
      const rawLines: string[] = [];
      // A. Unknown id cancel -> NO reply; followed by sentinel empty query id=900
      c.writeRaw(`{"type":"cancel","id":99999}\n{"type":"query","id":900,"query":"   ","asker":${JSON.stringify(asker)}}\n`);
      rawLines.push(await c.nextLine());

      // B. Cancel already-completed id=900 -> NO reply; followed by pre-cancelled empty query id=901
      c.writeRaw(
        `{"type":"cancel","id":900}\n` +
        `{"type":"cancel","id":901}\n` +
        `{"type":"query","id":901,"query":"","asker":${JSON.stringify(asker)}}\n`,
      );
      rawLines.push(await c.nextLine());

      // B2. Lone-surrogate query string (`\ud800`) followed by sentinel id=903:
      //     both MB (`@json.parse` catch -> continue) and Pion (`sql_db::parse_json` Err -> return) silently ignore 902 and reply only 903.
      c.writeRaw(
        `{"type":"query","id":902,"query":"\\ud800","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n` +
        `{"type":"query","id":903,"query":"   ","asker":${JSON.stringify(asker)}}\n`,
      );
      rawLines.push(await c.nextLine());

      // C. Distinguishable numeric `1.0` / `1` vs string `"1"`:
      //    cancel `1` cancels `1.0` (ProfileAlphaHit -> error) and consumes cancel so subsequent `1` succeeds (ProfileBetaHit);
      //    string `"1"` is a distinct key and succeeds with ProfileAlphaHit.
      c.writeRaw(
        `{"type":"cancel","id":1}\n` +
        `{"type":"query","id":1.0,"query":"ProfileAlphaHit","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n` +
        `{"type":"query","id":1,"query":"ProfileBetaHit","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n` +
        `{"type":"query","id":"1","query":"ProfileAlphaHit","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n`,
      );
      const trio: string[] = [];
      while (trio.length < 3) {
        const line = await c.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        trio.push(line);
      }
      rawLines.push(...trio);

      // D. Same-chunk query + cancel -> "the search took too long"
      c.writeRaw(
        `{"type":"query","id":42,"query":"slowneedle","asker":${JSON.stringify(asker)},"kinds":["message"]}\n` +
        `{"type":"cancel","id":42}\n`,
      );
      for (;;) {
        const line = await c.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        rawLines.push(line);
        break;
      }

      // D2. Claude 4000-leading-spaces `<command-name>` filtered BEFORE 4000-code-point clipping -> assistant hit at index 0
      c.writeRaw(`{"type":"query","id":43,"query":"cmdfilterneedle","asker":${JSON.stringify(asker)},"kinds":["history"]}\n`);
      for (;;) {
        const line = await c.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        rawLines.push(line);
        break;
      }
      return rawLines;
    } finally {
      await c.close();
    }
  };

  // Normalize MoonBit Failure source-location prefix (`src/search/match.mbt:...:... FAILED: `) when comparing error replies.
  const normalize = (lines: string[]) =>
    lines.map((l) => {
      const obj = JSON.parse(l);
      if (typeof obj.error === "string") {
        obj.error = obj.error.replace(/^.*FAILED:\s*/, "");
      }
      return obj;
    });

  try {
    const [mbRaw, pionRaw] = [await runSharedScenario(bins.mb), await runSharedScenario(bins.pion)];
    const mbNorm = normalize(mbRaw);
    const pionNorm = normalize(pionRaw);

    // Explicitly verify distinguishable targets for 1.0 (cancelled), 1 (ProfileBetaHit), and "1" (ProfileAlphaHit)
    const id1Replies = pionNorm.filter((o) => o.id === 1);
    assert.equal(id1Replies.length, 2, "expected 2 numeric id=1 replies (1.0 cancelled + 1 succeeded)");
    assert.equal(id1Replies.filter((o) => o.error === "the search took too long").length, 1, "cancel 1 must cancel 1.0");
    const id1Ok = id1Replies.find((o) => Array.isArray(o.groups));
    assert.equal(id1Ok?.groups?.[0]?.hits?.[0]?.profile, "prof-beta", "subsequent id=1 must succeed with prof-beta");
    const strIdOk = pionNorm.find((o) => o.id === "1");
    assert.equal(strIdOk?.groups?.[0]?.hits?.[0]?.profile, "prof-alpha", 'string id="1" must succeed with prof-alpha');
    const cmdHit = pionNorm.find((o) => o.id === 43);
    assert.equal(cmdHit?.groups?.[0]?.hits?.[0]?.index, 0, "4000-space <command-name> must be filtered before clip so assistant hit is index 0");

    // Full 0-diff against real MB (preserving exact per-step reply structure)
    const byKey = (arr: any[]) => [...arr].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
    assert.deepEqual(byKey(pionNorm), byKey(mbNorm), "Pion and MB must produce 0-diff responses across all protocol/wire cases");

    // E. Pion-side UTF-16 lone-surrogate preservation on BOTH message excerpt cut AND history transcript JSON escapes:
    //    `js_json::stringify_line` cleanly escapes lone surrogates as `\ud800`/`\ude00` (matching JS JSON.stringify),
    //    whereas MB's UTF-8 stdout encoder aborts on lone surrogates.
    const pc = new RawLineClient(bins.pion, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    try {
      pc.writeRaw(`{"type":"query","id":77,"query":"surrogateneedle","asker":${JSON.stringify(asker)},"kinds":["message"]}\n`);
      let msgSurrLine = "";
      for (;;) {
        const line = await pc.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        msgSurrLine = line;
        break;
      }
      assert.ok(msgSurrLine.includes("\\ude00"), `expected lone surrogate escape in message excerpt: ${msgSurrLine}`);
      assert.equal(JSON.parse(msgSurrLine).id, 77);

      // History transcript with raw JSON-escaped lone surrogates (\ud800 and \ude00)
      pc.writeRaw(`{"type":"query","id":78,"query":"surrogatehisttoken","asker":${JSON.stringify(asker)},"kinds":["history"]}\n`);
      let histSurrLine = "";
      for (;;) {
        const line = await pc.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        histSurrLine = line;
        break;
      }
      assert.ok(histSurrLine.includes("\\ud800"), `expected raw \\ud800 preserved in history excerpt: ${histSurrLine}`);
      assert.ok(histSurrLine.includes("\\ude00"), `expected raw \\ude00 preserved in history excerpt: ${histSurrLine}`);
      assert.ok(!histSurrLine.includes("\ufffd"), `history excerpt must NOT replace lone surrogates with U+FFFD: ${histSurrLine}`);
      const histParsed = JSON.parse(histSurrLine);
      assert.equal(histParsed.id, 78);
      assert.equal(histParsed.groups[0].hits.length, 1);

      // Cursor assistant transcript with raw JSON-escaped lone surrogate (\ud800)
      pc.writeRaw(`{"type":"query","id":79,"query":"cursorneedle","asker":${JSON.stringify(asker)},"kinds":["history"]}\n`);
      let curSurrLine = "";
      for (;;) {
        const line = await pc.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        curSurrLine = line;
        break;
      }
      assert.ok(curSurrLine.includes("\\ud800"), `expected raw \\ud800 preserved in Cursor history excerpt: ${curSurrLine}`);
      assert.ok(!curSurrLine.includes("\ufffd"), `Cursor history excerpt must NOT replace lone surrogate with U+FFFD: ${curSurrLine}`);
      const curParsed = JSON.parse(curSurrLine);
      assert.equal(curParsed.id, 79);
      assert.equal(curParsed.groups[0].hits.length, 1);
    } finally {
      await pc.close();
    }
  } finally {
    fx.close();
  }
});

test("cross-engine .zst parity, bidirectional SHA-1 transcript-marks interop (MB<->Pion with raw partial UTF-8 bytes), and live hot-reload new Search (MB -> Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const fx = makeFixture();
  const wrapDir = mkdtempSync(join(tmpdir(), "w6-search-wrap-"));
  const mbLog = join(wrapDir, "mb.log");
  const pionLog = join(wrapDir, "pion.log");
  const mbWrap = makeRecordingWrapper(wrapDir, "mb-wrap.sh", bins.mb, mbLog);
  const pionWrap = makeRecordingWrapper(wrapDir, "pion-wrap.sh", bins.pion, pionLog);

  try {
    // 1. Pack h-a transcript to .zst -> direct MB vs Pion history search 0-diff parity
    await packFile(join(fx.dir, "transcripts", "claude", "-w-h-a", "ha1.jsonl"));
    const asker = { workspace: "W1", home: true, scopes: [] };
    const askerA = { workspace: "WA", home: false, scopes: [] };
    const mbProc = new MbProcess(bins.mb, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    const pionProc = new MbProcess(bins.pion, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    const askOne = (proc: MbProcess, query: string) =>
      new Promise<any>((resolve) => {
        const handler = (m: any) => {
          if ("scopePending" in m || "sessionListPending" in m) return;
          proc.off("message", handler);
          resolve(m);
        };
        proc.on("message", handler);
        proc.postMessage({ type: "query", id: 1, query, asker: askerA, kinds: ["history"] });
      });
    try {
      const [mbA, pionA] = await Promise.all([askOne(mbProc, "alphaonlytoken"), askOne(pionProc, "alphaonlytoken")]);
      assert.deepEqual(pionA, mbA, "packed .zst history search must be 0-diff between MB and Pion");
      assert.equal(pionA.groups.length, 1);
      assert.equal(pionA.groups[0].hits.length, 1);
    } finally {
      await Promise.all([mbProc.terminate(), pionProc.terminate()]);
    }

    // 2. Bidirectional real SHA-1 `transcript-marks/<sha1>.json` cross-engine interop (MB <-> Pion):
    //    Includes an incomplete multi-byte UTF-8 char (€ = E2 82 AC split after E2 82) in a half-written JSONL line,
    //    and tampers with line 1 (preserving byte length) so any engine that ignores marks and re-scans from 0 FAILS!
    const marksDir = join(fx.dir, "transcript-marks");
    const mSessPath = join(fx.dir, "transcripts", "claude", "-w-h-marks", "hm1.jsonl");
    fx.store.insertSession({
      key: "h-marks",
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: "/w/h-marks",
      token: "tok-h-marks",
      createdAt: 1,
      lastActiveAt: 110,
      ws: "W1",
    } as Parameters<Store["insertSession"]>[0]);
    fx.store.ranIn("h-marks", "hm1", "cc");
    fx.store.setRuntimeSessionId("h-marks", "hm1");
    const expectedSha1 = createHash("sha1").update(mSessPath, "utf8").digest("hex");
    const expectedMarkFile = join(marksDir, `${expectedSha1}.json`);

    const line1 = `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T12:00:00Z", message: { content: "line-one-original" } })}\n`;
    const halfLineFull = Buffer.from(
      `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T12:01:00Z", message: { content: "price €100" } })}\n`,
      "utf8",
    );
    const euroPos = halfLineFull.indexOf(Buffer.from([0xe2, 0x82, 0xac]));
    assert.ok(euroPos > 0);
    // Split RIGHT inside the 3-byte UTF-8 sequence of '€' (keep 0xE2 0x82 in partial, 0xAC in the appended suffix)
    const halfPart1 = halfLineFull.subarray(0, euroPos + 2);
    const halfPart2 = halfLineFull.subarray(euroPos + 2);
    const line3 = `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T12:02:00Z", message: { content: "line-three-final" } })}\n`;

    const writeInitialTranscript = () => {
      mkdirSync(dirname(mSessPath), { recursive: true });
      writeFileSync(mSessPath, Buffer.concat([Buffer.from(line1, "utf8"), halfPart1]));
    };
    const tamperLine1AndAppend = () => {
      // Overwrite line 1 with invalid JSON of EXACT same byte length (would drop count from 3 -> 2 if mark were ignored!)
      const cur = readFileSync(mSessPath);
      const l1Len = Buffer.byteLength(line1, "utf8");
      const tampered = Buffer.concat([Buffer.from(`${"x".repeat(l1Len - 1)}\n`, "utf8"), cur.subarray(l1Len), halfPart2, Buffer.from(line3, "utf8")]);
      writeFileSync(mSessPath, tampered);
    };

    // 2a. MB writes mark -> tamper line 1 & append rest -> Pion resumes from MB's <sha1>.json!
    rmSync(marksDir, { recursive: true, force: true });
    writeInitialTranscript();
    const mbReader1 = readersOf(fx.dir, bins.mb);
    try {
      const st1 = JSON.parse(await mbReader1.read("transcriptState", { key: "h-marks" }, "en"));
      assert.equal(st1.states[0].count, 1);
    } finally {
      mbReader1.close();
    }
    assert.ok(existsSync(expectedMarkFile), `MB must write mark at exact SHA-1 path ${expectedMarkFile}`);
    const mbWrittenMark = JSON.parse(readFileSync(expectedMarkFile, "utf8"));
    assert.equal(mbWrittenMark.state.partial, halfPart1.toString("base64"), "MB mark partial must be raw base64 of incomplete UTF-8 bytes");

    tamperLine1AndAppend();
    const pionResumed = JSON.parse(
      execFileSync(bins.pion, ["--smoke-history-marks", "--data", fx.dir, "--path", mSessPath, "--runtime", "claude", "--sep", sep], {
        encoding: "utf8",
      }),
    );
    assert.equal(pionResumed.markFile, expectedMarkFile);
    assert.equal(pionResumed.count, 3, "Pion must resume from MB mark (count=3 including tampered line 1; ignoring mark would give 2)");
    assert.ok(
      pionResumed.tailEntries.some((e: any) => typeof e.text === "string" && e.text.includes("price €100")),
      `Pion must reassemble split UTF-8 € from MB base64 partial: ${JSON.stringify(pionResumed.tailEntries)}`,
    );

    // 2b. Pion writes mark -> verify exact SHA-1 file & schema parity -> tamper line 1 & append rest -> MB resumes from Pion's <sha1>.json!
    rmSync(marksDir, { recursive: true, force: true });
    writeInitialTranscript();
    const pionInitial = JSON.parse(
      execFileSync(bins.pion, ["--smoke-history-marks", "--data", fx.dir, "--path", mSessPath, "--runtime", "claude", "--sep", sep], {
        encoding: "utf8",
      }),
    );
    assert.equal(pionInitial.count, 1);
    assert.ok(existsSync(expectedMarkFile), `Pion must write mark at exact SHA-1 path ${expectedMarkFile}`);
    const pionWrittenMark = JSON.parse(readFileSync(expectedMarkFile, "utf8"));
    assert.deepEqual(pionWrittenMark, mbWrittenMark, "Pion and MB transcript-marks/<sha1>.json must be byte/schema identical");

    tamperLine1AndAppend();
    const mbReader2 = readersOf(fx.dir, bins.mb);
    try {
      const st2 = JSON.parse(await mbReader2.read("transcriptState", { key: "h-marks" }, "en"));
      assert.equal(st2.states[0].count, 3, "MB must resume from Pion mark (count=3 including tampered line 1; ignoring mark would give 2)");
      const tl2 = JSON.parse(await mbReader2.read("timeline", { key: "h-marks", from: "0", to: "10" }, "en"));
      assert.ok(
        tl2.entries.some((e: any) => typeof e.text === "string" && e.text.includes("price €100")),
        `MB must reassemble split UTF-8 € from Pion base64 partial: ${JSON.stringify(tl2.entries)}`,
      );
    } finally {
      mbReader2.close();
    }

    // 3. Real hot-reload on production `new Search`: start on MB -> in-flight query finishes on MB ->
    //    flip liveConfig to "pion" + trimIdle + hanging probe -> first post-reload spawn hits Pion wrapper!
    await withEnv(
      {
        STILLFAIL_MB_READER: mbWrap,
        STILLFAIL_PION_READER: pionWrap,
        STILLFAIL_READER_SEARCH: undefined,
        STILLFAIL_READER_ENGINE: undefined,
      },
      async () => {
        const searchSpawns = (logFile: string) =>
          readSpawns(logFile).filter((l) => /--builder search(?:\s|$)/.test(l));
        let liveConfig: ReaderSelectConfig = { readers: { search: "mb" } };
        const search = new Search({ data: fx.dir, backfill: { readers: () => liveConfig } });
        try {
          // 3a. Initial query hits real MB wrapper (0 Pion spawns)
          const r1 = await search.query("FastProfileHit", asker, { kinds: ["profile"] });
          assert.equal(r1.groups.length, 1);
          assert.equal(searchSpawns(mbLog).length, 1, "initial query must spawn MB wrapper");
          assert.equal(searchSpawns(pionLog).length, 0, "0 Pion spawns while configured as mb");

          // 3b. Flip liveConfig to "pion" while an in-flight query is running on MB -> completes on existing MB worker
          const inFlight = search.query("slowneedle", asker, { kinds: ["message"] });
          liveConfig = { readers: { search: "pion" } };
          const r2 = await inFlight;
          assert.equal(r2.groups.length, 1);
          assert.equal(r2.groups[0]!.kind, "message");
          assert.equal(searchSpawns(mbLog).length, 1, "in-flight query stays on existing MB worker");
          assert.equal(searchSpawns(pionLog).length, 0, "no Pion spawn during in-flight MB query");

          // 3c. Trim idle MB worker, install hanging Pion probe, issue query #3 -> first post-reload spawn hits Pion!
          assert.equal(search.trimIdle(), 1, "trimIdle must release idle MB search worker");
          let releaseProbe!: () => void;
          let probeCalls = 0;
          setPionProbeRunnerForTest((bin) => {
            probeCalls++;
            return new Promise<ReadonlySet<string> | null>((resolve) => {
              releaseProbe = () => {
                const ver = execFileSync(bin, ["--version"], { encoding: "utf8" });
                const m = ver.match(/modes:([^\n\r]+)/);
                resolve(m ? new Set(m[1]!.split(",").map((s) => s.trim()).filter(Boolean)) : null);
              };
            });
          });

          const pendingPion = search.query("FastProfileHit", asker, { kinds: ["profile"] });
          await Promise.resolve();
          assert.equal(probeCalls, 1, "hanging Pion probe should be triggered once after hot-reload");
          assert.equal(searchSpawns(mbLog).length, 1, "MB must NOT respawn while Pion probe is pending");

          releaseProbe();
          const r3 = await pendingPion;
          assert.equal(r3.groups.length, 1);
          assert.equal(r3.groups[0]!.kind, "profile");
          assert.equal(searchSpawns(pionLog).length, 1, "post-reload query must spawn Pion wrapper");
          assert.equal(searchSpawns(mbLog).length, 1, "MB must NOT spawn again after switch to Pion");
        } finally {
          setPionProbeRunnerForTest(null);
          await search.stop();
        }
      },
    );
  } finally {
    fx.close();
    rmSync(wrapDir, { recursive: true, force: true });
  }
});
