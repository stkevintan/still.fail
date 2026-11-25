// Wave 5 Sub-Wave 5.1 Foundation gate tests (`W5-0`):
// 1. All 10 `Permit` frame-interleaving boundary cases against real MoonBit `stillfail-reader --builder turn-counts`
//    with explicit ordered stdout frame assertions.
// 2. Zero-exception static SQLite lexical transaction guard across ALL `.pion` files in `pion/station/packages/`
//    (only `sql_db.pion` is permitted to contain raw transaction SQL; `builder_loop.pion` and all `builders_*`
//    packages must have zero violations).
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { addSessionTurns } from "../src/store/schema.ts";
import { Store } from "../src/store/store.ts";

const LINE_TIMEOUT_MS = 15_000;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "w5-foundation-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function forgetCounts(db: DatabaseSync): void {
  db.exec(`
    DROP TRIGGER IF EXISTS session_turns_add;
    DROP TRIGGER IF EXISTS session_turns_drop;
    DROP TRIGGER IF EXISTS session_turns_before_insert;
    DROP TRIGGER IF EXISTS session_turns_move;
    DROP TABLE IF EXISTS session_turns_guard;
    DROP TABLE session_turns
  `);
}

function seedTurnCountsDb(dir: string, label: string): { path: string; store: Store } {
  const path = join(dir, `${label}.db`);
  const store = Store.open(path, join(dir, `${label}-archive`));
  for (const key of ["A", "B", "C", "empty"]) {
    store.insertSession({
      key,
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: `/w/${key}`,
      token: key,
      createdAt: 1,
      lastActiveAt: 1,
    });
  }
  const put = store.db.prepare("INSERT INTO turns(rowid,id,session_key,kind,started_at) VALUES (?, ?, ?, 'input', ?)");
  store.db.exec("BEGIN");
  for (let n = 0; n < 300; n++) put.run(n + 1, `a-${n}`, "A", n + 1);
  for (let n = 0; n < 5; n++) put.run(n + 1000, `b-${n}`, "B", n + 1);
  for (let n = 0; n < 3; n++) put.run(n + 2000, `c-${n}`, "C", n + 1);
  store.db.exec("COMMIT");
  forgetCounts(store.db);
  addSessionTurns(store.db);
  store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  return { path, store };
}

function guardCount(db: DatabaseSync, session: string): number {
  return (db.prepare("SELECT count(*) AS n FROM session_turns_guard WHERE session = ?").get(session) as { n: number }).n;
}

class RawLineProc {
  readonly #child: ChildProcess;
  readonly #lines: string[] = [];
  readonly #waiters: Array<{ resolve: (line: string | null) => void; reject: (err: Error) => void; timer: NodeJS.Timeout }> = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #closed = false;
  readonly #exitPromise: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  constructor(binary: string, args: string[]) {
    const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => {
      this.#carry = this.#carry.length === 0 ? c : Buffer.concat([this.#carry, c]);
      for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
        const line = this.#carry.subarray(0, nl).toString("utf8");
        this.#carry = this.#carry.subarray(nl + 1);
        const w = this.#waiters.shift();
        if (w) {
          clearTimeout(w.timer);
          w.resolve(line);
        } else {
          this.#lines.push(line);
        }
      }
    });
    this.#exitPromise = new Promise((done) => {
      child.on("close", (code, signal) => {
        this.#closed = true;
        for (const w of this.#waiters.splice(0)) {
          clearTimeout(w.timer);
          w.resolve(null);
        }
        done({ code, signal });
      });
    });
  }

  writeRaw(data: string | Buffer): void {
    this.#child.stdin!.write(data);
  }

  endStdin(): void {
    this.#child.stdin!.end();
  }

  nextLine(): Promise<string | null> {
    if (this.#lines.length > 0) return Promise.resolve(this.#lines.shift()!);
    if (this.#closed) return Promise.resolve(null);
    return new Promise((resolveLine, rejectLine) => {
      const timer = setTimeout(() => {
        rejectLine(new Error(`timed out waiting for stdout line; stderr=${this.#stderr}`));
      }, LINE_TIMEOUT_MS);
      this.#waiters.push({ resolve: resolveLine, reject: rejectLine, timer });
    });
  }

  async nextJson(): Promise<Record<string, unknown>> {
    const line = await this.nextLine();
    assert.notEqual(line, null, `expected JSON line, got EOF; stderr=${this.#stderr}`);
    return JSON.parse(line!) as Record<string, unknown>;
  }

  async finish(): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
    this.#child.stdin!.end();
    const res = await this.#exitPromise;
    assert.equal(this.#lines.length, 0, `unexpected trailing stdout lines: ${JSON.stringify(this.#lines)}`);
    assert.equal(this.#carry.length, 0, `unexpected trailing stdout bytes: ${this.#carry.toString("utf8")}`);
    return res;
  }

  async kill(): Promise<void> {
    if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
    await this.#exitPromise;
  }
}

/// Helper: start an active scan on session A (creates a guard row in `session_turns_guard` and returns done=false).
async function startActiveScanA(proc: RawLineProc, db: DatabaseSync): Promise<void> {
  proc.writeRaw('{"session":"A"}\n');
  assert.deepStrictEqual(await proc.nextJson(), { take: true });
  proc.writeRaw('{"permit":true}\n');
  assert.deepStrictEqual(await proc.nextJson(), { done: false });
  assert.equal(guardCount(db, "A"), 1, "active scan on A must hold a guard row");
}

test("Permit interleaving boundaries (10 cases) against real MB stillfail-reader --builder turn-counts", async (t) => {
  const realMb = mbReaderBinary();
  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return;
  }
  const dir = freshDir("permit-mb-");

  // Case 1: cancel(A) + ask(B) in same chunk + late grant -> A guard deleted, {"give":true}, then ONLY B answered.
  {
    const { path, store } = seedTurnCountsDb(dir, "case1");
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      await startActiveScanA(proc, store.db);
      // Send cancel(A) and ask(B) together in one chunk before permit reply arrives.
      proc.writeRaw('{"session":"A","cancel":true}\n{"session":"B"}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true }, "case1: cancel(A) asks permit");
      // Late grant for cancel(A)
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { give: true }, "case1: cancel(A) releases permit");
      assert.equal(guardCount(store.db, "A"), 0, "case1: A guard must be deleted");
      // Next frame is B asking for permit (no extra frame for cancel(A))
      assert.deepStrictEqual(await proc.nextJson(), { take: true }, "case1: deferred B asks permit");
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { done: false }, "case1: B step 1");
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }

  // Case 2: cancel(A) + ask(B) in same chunk + late deny -> A guard NOT deleted, NO {"give":true}, then B answered.
  {
    const { path, store } = seedTurnCountsDb(dir, "case2");
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      await startActiveScanA(proc, store.db);
      proc.writeRaw('{"session":"A","cancel":true}\n{"session":"empty"}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true }, "case2: cancel(A) asks permit");
      proc.writeRaw('{"permit":false}\n');
      // No {"give":true}; empty session needs no write and answers immediately.
      assert.deepStrictEqual(await proc.nextJson(), { done: true }, "case2: deferred empty answered without give");
      assert.equal(guardCount(store.db, "A"), 1, "case2: A guard must remain when denied");
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }

  // Case 3: empty line "", malformed JSON "{bad", foreign object {"foo":1}, {"permit":"bad"},
  //         and lone-surrogate permit {"permit":true,"note":"\uD800"} while stdin stays open ->
  //         each consumes once and immediately rejects without hanging, followed by a valid request answered cleanly.
  //         Also verify 3-way fresh-scan guard creation: plain {"permit":true} -> guard=1,
  //         lone surrogate {"permit":true,"note":"\uD800"} -> guard=0, valid pair {"permit":true,"note":"\uD83D\uDE80"} -> guard=1.
  for (const badReply of ["", "{bad", '{"foo":1}', '{"permit":"bad"}', '{"permit":true,"note":"\\uD800"}']) {
    const { path, store } = seedTurnCountsDb(dir, `case3-${badReply.replace(/[^a-z0-9]/gi, "_")}`);
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      await startActiveScanA(proc, store.db);
      proc.writeRaw('{"session":"A","cancel":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw(`${badReply}\n{"session":"empty"}\n`);
      // Immediately rejects permit without closing stdin, emits no give and no extra error frame, then answers empty.
      assert.deepStrictEqual(
        await proc.nextJson(),
        { done: true },
        `case3(${JSON.stringify(badReply)}): rejected immediately and next ask answered cleanly`,
      );
      assert.equal(guardCount(store.db, "A"), 1, `case3(${JSON.stringify(badReply)}): guard untouched`);
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }
  for (const [label, reply, wantGuards] of [
    ["plain", '{"permit":true}', 1],
    ["lone-surrogate", '{"permit":true,"note":"\\uD800"}', 0],
    ["valid-surrogate-pair", '{"permit":true,"note":"\\uD83D\\uDE80"}', 1],
  ] as const) {
    const { path, store } = seedTurnCountsDb(dir, `case3-surrogate-${label}`);
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      proc.writeRaw('{"session":"A"}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw(`${reply}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { done: false });
      assert.equal(guardCount(store.db, "A"), wantGuards, `case3(${label}): expected guard count ${wantGuards}`);
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }

  // Case 4: mode-keyed invalid request ({"session":null}) interleaved after cancel(A) while waiting for permit ->
  //         deferred into FIFO, late {"permit":true} still grants & deletes A guard, then main loop replies invalid.
  {
    const { path, store } = seedTurnCountsDb(dir, "case4");
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      await startActiveScanA(proc, store.db);
      proc.writeRaw('{"session":"A","cancel":true}\n{"session":null}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { give: true }, "case4: cancel(A) gives permit");
      assert.equal(guardCount(store.db, "A"), 0, "case4: A guard deleted");
      const invalid = await proc.nextJson();
      assert.equal(invalid.done, false);
      assert.equal(invalid.error, "invalid old turn counts preparation request");
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }

  // Case 5: cancel(A) + complete ask(B) + EOF without permit reply -> take denied, no give, B drained and answered
  //         (B needs write -> take() returns false due to eof without emitting {"take":true}, emits {"done":false}).
  {
    const { path, store } = seedTurnCountsDb(dir, "case5");
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      await startActiveScanA(proc, store.db);
      proc.writeRaw('{"session":"A","cancel":true}\n{"session":"B"}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true }, "case5: cancel(A) asks permit");
      proc.endStdin();
      // EOF denies cancel(A) without emitting give; main loop drains deferred B; B's take() sees eof=true and returns false immediately.
      assert.deepStrictEqual(await proc.nextJson(), { done: false }, "case5: deferred B drained after EOF");
      assert.equal(await proc.nextLine(), null, "case5: clean EOF after draining B");
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }

  // Cases 7, 8, 9, 10 (Note: repeat take while holding is verified in Pion `builders_core_test.pion`,
  // since MB `turns.step` calls `may_write` at most once per step):
  // - Case 7: cancel with no active scan -> emits nothing (no take, no response)
  // - Case 8: cancel with active scan -> emits no business answer (only take + give)
  // - Case 9: same chunk {"permit":true}\n<ask(empty)>\n -> permit consumed, empty processed
  // - Case 10: cross-chunk line assembly + EOF trailing half-line discarded
  {
    const { path, store } = seedTurnCountsDb(dir, "case7_10");
    const proc = new RawLineProc(realMb, ["--builder", "turn-counts", "--db", path]);
    try {
      // Case 7: cancel with no active scan -> no take, no output; followed by empty ask -> only {"done":true}
      proc.writeRaw('{"session":"nonexistent","cancel":true}\n{"session":"empty"}\n');
      assert.deepStrictEqual(await proc.nextJson(), { done: true }, "case7: cancel without scan emits nothing");

      // Case 8 + 9: start A, cancel A, reply permit+ask(empty) in SAME chunk
      await startActiveScanA(proc, store.db);
      proc.writeRaw('{"session":"A","cancel":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n{"session":"empty"}\n');
      assert.deepStrictEqual(await proc.nextJson(), { give: true }, "case8/9: cancel gives permit, no business reply");
      assert.deepStrictEqual(await proc.nextJson(), { done: true }, "case9: ask in same chunk after permit answered");

      // Case 10: cross-chunk line assembly + trailing half-line at EOF discarded
      proc.writeRaw('{"ses');
      proc.writeRaw('sion":"empty"}\n{"session":"half-line-no-nl"');
      assert.deepStrictEqual(await proc.nextJson(), { done: true }, "case10: cross-chunk line assembled");
      proc.endStdin();
      assert.equal(await proc.nextLine(), null, "case10: trailing half-line discarded on EOF");
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }
});

function seedSaidDb(dir: string, label: string): { path: string; store: Store; longThread: number; readyThread: number } {
  const path = join(dir, `${label}.db`);
  const store = Store.open(path, join(dir, `${label}-archive`));
  store.insertSession({
    key: "s0",
    connect: "ember",
    runtime: "claude",
    profile: "cc",
    workspace: "/w/s0",
    token: "s0",
    createdAt: 1,
    lastActiveAt: 1,
  });
  const longThread = store.openThread("ember", "CHAT", `${label}-long`, null, null).id;
  const readyThread = store.openThread("ember", "CHAT", `${label}-ready`, null, null).id;
  store.joinThread(longThread, "s0", "ember");
  store.joinThread(readyThread, "s0", "ember");
  const put = store.db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,ts,at) VALUES (?,?,'message',?,?,?,?)");
  store.db.exec("BEGIN");
  put.run(longThread, 1, "agent", "s0", "first-long", 1);
  for (let n = 2; n <= 300; n++) put.run(longThread, n, "person", "me", `l-${n}`, n);
  put.run(readyThread, 1, "agent", "s0", "first-ready", 1);
  store.db.exec("COMMIT");
  store.db.prepare("UPDATE thread_state SET said_other_known=0 WHERE thread=?").run(longThread);
  store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  return { path, store, longThread, readyThread };
}

test("Permit classification on real MB stillfail-reader --builder said (empty/malformed/foreign immediate reject + mode-keyed null deferred)", async (t) => {
  const realMb = mbReaderBinary();
  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return;
  }
  const dir = freshDir("permit-said-mb-");

  // 1. Empty line, bad JSON, foreign object {"foo":1} while stdin stays open -> immediate reject, no extra frame, readyThread answered.
  for (const badReply of ["", "{bad", '{"foo":1}']) {
    const { path, store, longThread, readyThread } = seedSaidDb(dir, `said-bad-${badReply.replace(/[^a-z0-9]/gi, "_")}`);
    const proc = new RawLineProc(realMb, ["--builder", "said", "--db", path]);
    try {
      proc.writeRaw(`${JSON.stringify({ thread: longThread })}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { done: false });

      proc.writeRaw(`${JSON.stringify({ thread: longThread, cancel: true })}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw(`${badReply}\n${JSON.stringify({ thread: readyThread })}\n`);
      assert.deepStrictEqual(
        await proc.nextJson(),
        { done: true },
        `said(${JSON.stringify(badReply)}): rejected immediately and readyThread answered cleanly`,
      );
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }

  // 2. Mode-keyed invalid request {"thread":null} interleaved after cancel -> deferred, permit still grants, main loop replies invalid.
  {
    const { path, store, longThread } = seedSaidDb(dir, "said-deferred-null");
    const proc = new RawLineProc(realMb, ["--builder", "said", "--db", path]);
    try {
      proc.writeRaw(`${JSON.stringify({ thread: longThread })}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { done: false });

      proc.writeRaw(`${JSON.stringify({ thread: longThread, cancel: true })}\n{"thread":null}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { give: true }, "said: cancel gives permit");
      const invalid = await proc.nextJson();
      assert.equal(invalid.done, false);
      assert.equal(invalid.error, "invalid sidebar said state preparation request");
      const exit = await proc.finish();
      assert.equal(exit.code, 0);
    } finally {
      await proc.kill();
      store.close();
    }
  }
});

// ── Zero-exception static SQLite lexical transaction guard (only `sql_db.pion` allowed) ──

type PionStringExpr = { line: number; value: string };

function extractPionStringExprs(source: string): PionStringExpr[] {
  const exprs: PionStringExpr[] = [];
  const n = source.length;
  let i = 0;
  let line = 1;

  const skipWsAndComments = () => {
    while (i < n) {
      const ch = source[i]!;
      if (ch === " " || ch === "\t" || ch === "\r") { i++; continue; }
      if (ch === "\n") { line++; i++; continue; }
      if (ch === "/" && source[i + 1] === "/") {
        i += 2;
        while (i < n && source[i] !== "\n") i++;
        continue;
      }
      if (ch === "/" && source[i + 1] === "*") {
        i += 2;
        while (i + 1 < n && !(source[i] === "*" && source[i + 1] === "/")) {
          if (source[i] === "\n") line++;
          i++;
        }
        i += 2;
        continue;
      }
      break;
    }
  };

  const readStringLiteral = (): string => {
    i++; // opening '"'
    let out = "";
    while (i < n) {
      const ch = source[i]!;
      if (ch === '"') { i++; return out; }
      if (ch === "\\") {
        i++;
        if (i >= n) return out;
        const esc = source[i++]!;
        if (esc === "n") out += "\n";
        else if (esc === "r") out += "\r";
        else if (esc === "t") out += "\t";
        else if (esc === '"') out += '"';
        else if (esc === "\\") out += "\\";
        else if (esc === "u" && source[i] === "{") {
          const close = source.indexOf("}", i + 1);
          if (close > i + 1) {
            const cp = parseInt(source.slice(i + 1, close), 16);
            if (!Number.isNaN(cp)) out += String.fromCodePoint(cp);
            i = close + 1;
          }
        } else out += esc;
      } else {
        if (ch === "\n") line++;
        out += ch;
        i++;
      }
    }
    return out;
  };

  while (i < n) {
    skipWsAndComments();
    if (i >= n) break;
    if (source[i] === '"') {
      const startLine = line;
      let combined = readStringLiteral();
      for (;;) {
        const savedI = i;
        const savedLine = line;
        skipWsAndComments();
        if (source[i] === "+") {
          i++;
          skipWsAndComments();
          if (source[i] === '"') {
            combined += readStringLiteral();
            continue;
          }
          // Fold interpolated expressions inside `+` SQL builders (e.g. `"CREATE TRIGGER " + name + " BEGIN " + body + " END;"`)
          // into a neutral identifier placeholder so trigger DDL stays intact while raw tx SQL is still caught.
          if (i < n && /[A-Za-z_(]/.test(source[i]!)) {
            let depth = 0;
            while (i < n) {
              const ch = source[i]!;
              if (ch === "(" || ch === "[" || ch === "{") { depth++; i++; continue; }
              if (ch === ")" || ch === "]" || ch === "}") {
                if (depth === 0) break;
                depth--;
                i++;
                continue;
              }
              if (depth === 0 && (ch === "+" || ch === "," || ch === ";" || ch === "\n")) break;
              if (ch === '"') { readStringLiteral(); continue; }
              i++;
            }
            combined += " __expr__ ";
            continue;
          }
        }
        i = savedI;
        line = savedLine;
        break;
      }
      exprs.push({ line: startLine, value: combined });
      continue;
    }
    i++;
  }
  return exprs;
}

type SqlTok = { kind: "word"; upper: string } | { kind: "ident" } | { kind: "str" } | { kind: "semi" } | { kind: "other" };

function tokenizeSql(sql: string): SqlTok[] {
  const out: SqlTok[] = [];
  let i = sql.startsWith("\uFEFF") ? 1 : 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") { i++; continue; }
    if (ch === "-" && sql[i + 1] === "-") {
      i += 2;
      while (i < n && sql[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && sql[i + 1] === "*") {
      i += 2;
      while (i + 1 < n && !(sql[i] === "*" && sql[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    if (ch === "'") {
      i++;
      while (i < n) {
        if (sql[i] === "'") {
          i++;
          if (sql[i] === "'") { i++; continue; }
          break;
        }
        i++;
      }
      out.push({ kind: "str" });
      continue;
    }
    if (ch === '"' || ch === "`") {
      const q = ch;
      i++;
      while (i < n) {
        if (sql[i] === q) {
          i++;
          if (sql[i] === q) { i++; continue; }
          break;
        }
        i++;
      }
      out.push({ kind: "ident" });
      continue;
    }
    if (ch === "[") {
      i++;
      while (i < n && sql[i] !== "]") i++;
      if (i < n) i++;
      out.push({ kind: "ident" });
      continue;
    }
    if (ch === ";") { out.push({ kind: "semi" }); i++; continue; }
    if (/[A-Za-z_]/.test(ch)) {
      const start = i;
      while (i < n && /[A-Za-z0-9_$]/.test(sql[i]!)) i++;
      out.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    out.push({ kind: "other" });
    i++;
  }
  return out;
}

function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  for (const expr of extractPionStringExprs(source)) {
    const tokens = tokenizeSql(expr.value);
    let atStmtStart = true;
    let inTriggerHeader = false;
    let inTriggerBody = false;
    let atTriggerStmtStart = false;
    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t]!;
      if (inTriggerBody) {
        if (tok.kind === "semi") atTriggerStmtStart = true;
        else if (atTriggerStmtStart && tok.kind === "word" && tok.upper === "END") {
          inTriggerBody = false;
          atTriggerStmtStart = false;
          atStmtStart = false;
        } else atTriggerStmtStart = false;
        continue;
      }
      if (inTriggerHeader) {
        if (tok.kind === "word" && tok.upper === "BEGIN") {
          inTriggerHeader = false;
          inTriggerBody = true;
          atTriggerStmtStart = true;
        } else if (tok.kind === "semi") {
          inTriggerHeader = false;
          atStmtStart = true;
        }
        continue;
      }
      if (tok.kind === "semi") { atStmtStart = true; continue; }
      if (!atStmtStart) continue;
      atStmtStart = false;
      if (tok.kind !== "word") continue;
      if (tok.upper === "CREATE") {
        const t1 = tokens[t + 1];
        const t2 = tokens[t + 2];
        if (
          (t1?.kind === "word" && t1.upper === "TRIGGER") ||
          (t1?.kind === "word" && (t1.upper === "TEMP" || t1.upper === "TEMPORARY") && t2?.kind === "word" && t2.upper === "TRIGGER")
        ) {
          inTriggerHeader = true;
        }
        continue;
      }
      if (!forbiddenHeads.has(tok.upper)) continue;
      // SQLite `SAVEPOINT <name>` / `RELEASE [SAVEPOINT] <name>` accept bare, quoted (`"`, `` ` ``, `[...]`),
      // or single-quoted identifiers; ignore standalone non-SQL literals like Cargo's `"release"` directory name.
      if (
        (tok.upper === "RELEASE" || tok.upper === "SAVEPOINT") &&
        tokens[t + 1]?.kind !== "word" &&
        tokens[t + 1]?.kind !== "ident" &&
        tokens[t + 1]?.kind !== "str"
      ) {
        continue;
      }
      violations.push(`${filename}:${expr.line}: forbidden raw transaction SQL "${tok.upper}" in literal ${JSON.stringify(expr.value)}`);
    }
  }
  return violations;
}

function collectPionSources(rootDir: string, prefix = ""): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(rootDir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    const full = join(rootDir, entry.name);
    if (entry.isDirectory()) {
      out.push(...collectPionSources(full, rel));
    } else if (entry.name.endsWith(".pion") && !entry.name.endsWith("_test.pion")) {
      out.push(rel);
    }
  }
  return out;
}

/// Strip ONLY the body of `fn run_smoke_sqlite(...)` from `smoke/src/main.pion` so low-level
/// `sqlite_ffi` smoke tests (`BEGIN;` / `COMMIT;`) are exempted while the rest of `main.pion` stays guarded.
function stripRunSmokeSqlite(source: string): string {
  const marker = "fn run_smoke_sqlite(";
  const start = source.indexOf(marker);
  assert.ok(start >= 0, "expected fn run_smoke_sqlite in smoke/src/main.pion");
  const openBrace = source.indexOf("{", start);
  assert.ok(openBrace >= 0, "expected opening brace for run_smoke_sqlite");
  let depth = 0;
  let i = openBrace;
  let inStr = false;
  while (i < source.length) {
    const ch = source[i]!;
    if (inStr) {
      if (ch === "\\") { i += 2; continue; }
      if (ch === '"') inStr = false;
      i++;
      continue;
    }
    if (ch === '"') { inStr = true; i++; continue; }
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) {
        return source.slice(0, start) + source.slice(i + 1);
      }
    }
    i++;
  }
  assert.fail("unterminated run_smoke_sqlite function");
}

function collectSqlPackages(pkgsDir: string, allFiles: string[]): Set<string> {
  const depsByPkg = new Map<string, string[]>();
  for (const entry of readdirSync(pkgsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const manifestPath = join(pkgsDir, entry.name, "pion.toml");
    if (!existsSync(manifestPath)) continue;
    const manifest = readFileSync(manifestPath, "utf8");
    const deps: string[] = [];
    let inDeps = false;
    for (const rawLine of manifest.split("\n")) {
      const line = rawLine.replace(/#.*$/, "").trim();
      if (!line) continue;
      if (line.startsWith("[")) {
        inDeps = line === "[dependencies]";
        continue;
      }
      if (inDeps) {
        const m = /^([A-Za-z0-9_-]+)\s*=/.exec(line);
        if (m) deps.push(m[1]!);
      }
    }
    depsByPkg.set(entry.name, deps);
  }
  const sqlPackages = new Set<string>(["sql_db", "sqlite_ffi"]);
  // Also seed any package that directly declares or references sqlite3_*/stq_* FFI symbols.
  for (const rel of allFiles) {
    const pkg = rel.split("/")[0]!;
    if (sqlPackages.has(pkg)) continue;
    const src = readFileSync(join(pkgsDir, rel), "utf8");
    if (/\b(?:sqlite3_|stq_)\w+\b/.test(src)) sqlPackages.add(pkg);
  }
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pkg, deps] of depsByPkg) {
      if (sqlPackages.has(pkg)) continue;
      if (deps.some((d) => sqlPackages.has(d))) {
        sqlPackages.add(pkg);
        changed = true;
      }
    }
  }
  return sqlPackages;
}

test("recursive zero-exception static SQLite transaction guard across ALL SQLite-linked pion/station/packages/**/*.pion", () => {
  const pkgsDir = resolve(fileURLToPath(new URL("../../pion/station/packages", import.meta.url)));
  assert.ok(existsSync(pkgsDir), `expected ${pkgsDir} to exist`);
  const allFiles = collectPionSources(pkgsDir);
  const sqlPackages = collectSqlPackages(pkgsDir, allFiles);
  const checkedFiles = allFiles.filter((rel) => sqlPackages.has(rel.split("/")[0]!));
  assert.ok(checkedFiles.includes("sql_db/src/sql_db.pion"), "must discover sql_db.pion");
  assert.ok(checkedFiles.includes("sqlite_ffi/src/sqlite_ffi.pion"), "must discover sqlite_ffi.pion");
  assert.ok(checkedFiles.includes("builders_core/src/builder_loop.pion"), "must discover builder_loop.pion");
  assert.ok(checkedFiles.includes("builders_stateful/src/page_letters.pion"), "must discover page_letters.pion");
  assert.ok(checkedFiles.includes("station_conv/src/station_conv.pion"), "must discover station_conv.pion");
  assert.ok(checkedFiles.includes("locate/src/locate.pion"), "must discover locate.pion");
  assert.ok(checkedFiles.includes("builders_usage/src/counter.pion"), "must discover builders_usage/src/counter.pion");
  assert.ok(checkedFiles.includes("builders_usage/src/record.pion"), "must discover builders_usage/src/record.pion");
  assert.ok(checkedFiles.includes("builders_search/src/search_docs.pion"), "must discover search_docs.pion");
  assert.ok(checkedFiles.includes("builders_search/src/history_search.pion"), "must discover history_search.pion");
  assert.ok(checkedFiles.includes("smoke/src/main.pion"), "must discover smoke/src/main.pion");

  for (const rel of checkedFiles) {
    if (rel === "sql_db/src/sql_db.pion") continue;
    const raw = readFileSync(join(pkgsDir, rel), "utf8");
    const content = rel === "smoke/src/main.pion" ? stripRunSmokeSqlite(raw) : raw;
    assert.deepStrictEqual(
      findRawTxControlViolations(rel, content),
      [],
      `${rel} must contain zero raw transaction SQL (only sql_db.pion and run_smoke_sqlite are exempted)`,
    );
  }

  // Verify quoted SQLite identifiers after SAVEPOINT/RELEASE are detected while standalone directory "release" is allowed.
  assert.deepStrictEqual(findRawTxControlViolations("dir-name.pion", 'let d = "release"'), []);
  for (const quotedStmt of [
    'let _ = db.exec("SAVEPOINT [sp]")',
    'let _ = db.exec("RELEASE [sp]")',
    'let _ = db.exec("SAVEPOINT \\"sp\\"")',
    'let _ = db.exec("RELEASE `sp`")',
    "let _ = db.exec(\"SAVEPOINT 'sp'\")",
    "let _ = db.exec(\"RELEASE 'sp'\")",
  ]) {
    const hits = findRawTxControlViolations("quoted-sp.pion", quotedStmt);
    assert.equal(hits.length, 1, `quoted identifier savepoint mutation ${quotedStmt} must be detected`);
  }

  // In-closure real-file mutation checks: inject directly inside real business function/closure bodies.
  const archiveMarksSrc = readFileSync(join(pkgsDir, "builders_core/src/archive_marks.pion"), "utf8");
  const txClosureRe = /(fn\(tx_db : sql_db::Db\) -> [^\n{]+\{\n)/;
  assert.match(archiveMarksSrc, txClosureRe, "expected db.tx_err closure in archive_marks.pion");
  for (const stmt of ['let _ = tx_db.exec("COMMIT")', 'let _ = tx_db.exec("SAVEPOINT sp")', 'let _ = tx_db.exec("ROLL" + "BACK")']) {
    const mutated = archiveMarksSrc.replace(txClosureRe, `$1      ${stmt}\n`);
    assert.notEqual(mutated, archiveMarksSrc);
    const hits = findRawTxControlViolations("archive_marks.pion", mutated);
    assert.equal(hits.length, 1, `in-closure mutation ${stmt} in archive_marks.pion must be detected`);
  }

  const loopSrc = readFileSync(join(pkgsDir, "builders_core/src/builder_loop.pion"), "utf8");
  const loopAnchor = "let res = step(db, ask)\n";
  assert.ok(loopSrc.includes(loopAnchor), "expected step(db, ask) inside builder_loop.pion");
  for (const stmt of ['let _ = db.exec("BEGIN IMMEDIATE")', 'let _ = db.exec("COMMIT")', 'let _ = db.exec("ROLL" + "BACK")', 'let _ = db.exec("SAVEPOINT sp")', 'let _ = db.exec("RELEASE sp")']) {
    const mutated = loopSrc.replace(loopAnchor, `${loopAnchor}          ${stmt}\n`);
    const hits = findRawTxControlViolations("builder_loop.pion", mutated);
    assert.equal(hits.length, 1, `in-body mutation ${stmt} in builder_loop.pion must be detected`);
  }
});
