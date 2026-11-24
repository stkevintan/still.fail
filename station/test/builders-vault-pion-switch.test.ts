// Real dual-engine production switch, UseIndex hot-switch (#known preservation), UTF-16LE BLOB &
// JS JSON edge-case 0-diff parity, vault-use-ambiguity coverage, SQLITE_BUSY / error contract, and
// static SQLite lexical transaction guard tests for `builders_vault` (`--builder vault-uses`).
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
} from "../src/read/mb-reader.ts";
import { readerModeEnvKey, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { initializeVaultMembers } from "../src/vault/member-index.ts";
import { initializePendingIndex } from "../src/vault/pending-index.ts";
import { initializeReboxIndex } from "../src/vault/rebox-index.ts";
import {
  backfillUsePreparation,
  initializeUseIndex,
  tryReadUses,
  UseIndex,
} from "../src/vault/use-index.ts";

const ASK_TIMEOUT_MS = 30_000;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-vault-switch-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosix = platform.os === "windows" ? "POSIX shell wrappers are not directly spawnable on Windows" : false;

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function makeLegacyPionStub(dir: string, name: string, logFile: string): string {
  const stub = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}`,
    'if [ "${1:-}" = "--version" ]; then',
    '  printf "stillfail-pion 0.0.1-legacy (linux-x64)\\n"',
    "  exit 0",
    "fi",
    'echo "legacy stub does not support vault-uses $*" >&2',
    "exit 2",
    "",
  ].join("\n");
  writeFileSync(stub, sh, "utf8");
  chmodSync(stub, 0o755);
  return stub;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

function clearSpawns(logFile: string): void {
  writeFileSync(logFile, "", "utf8");
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

function resolveBinaries(t: { skip: (msg: string) => void }): { realMb: string; realPion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  return { realMb: resolve(realMb), realPion: resolve(realPion!) };
}

type Waiter = {
  resolve: (res: Record<string, unknown>) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};

class VaultProc {
  readonly #child: ChildProcess;
  readonly #waiting: Waiter[] = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #ending = false;
  #protocolError: Error | null = null;
  readonly #closed: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  constructor(binary: string, dbPath: string) {
    const child = spawn(binary, ["--builder", "vault-uses", "--db", dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => this.#onData(c));
    this.#closed = new Promise((done) => {
      let ended = false;
      const finish = (code: number | null, signal: NodeJS.Signals | null) => {
        if (ended) return;
        ended = true;
        if (!this.#ending) {
          this.#fail(`vault-uses exited unexpectedly (code=${code}, signal=${signal}); stderr=${this.#stderr}`);
        }
        this.#rejectAll(new Error(`vault-uses exited (code=${code}, signal=${signal}); stderr=${this.#stderr}`));
        done({ code, signal });
      };
      child.on("error", (err) => {
        this.#fail(`vault-uses spawn error: ${err.message}`);
        if (child.pid === undefined) finish(null, null);
      });
      child.on("close", (code, signal) => finish(code, signal));
    });
  }

  #rejectAll(err: Error) {
    for (const w of this.#waiting.splice(0)) {
      clearTimeout(w.timer);
      w.reject(err);
    }
  }

  #fail(msg: string) {
    if (this.#protocolError === null) this.#protocolError = new Error(msg);
    this.#rejectAll(this.#protocolError);
    this.#child.kill("SIGKILL");
  }

  #onData(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
      const line = this.#carry.subarray(0, nl).toString("utf8");
      this.#carry = this.#carry.subarray(nl + 1);
      let parsed: Record<string, unknown>;
      try {
        parsed = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return this.#fail(`stdout emitted non-JSON line: ${JSON.stringify(line.slice(0, 200))}`);
      }
      const w = this.#waiting.shift();
      if (w === undefined) return this.#fail(`stdout emitted unsolicited line: ${line.slice(0, 200)}`);
      clearTimeout(w.timer);
      w.resolve(parsed);
    }
  }

  askRaw(raw: string | Buffer): Promise<Record<string, unknown>> {
    if (this.#protocolError !== null) return Promise.reject(this.#protocolError);
    return new Promise((resolveAsk, rejectAsk) => {
      const timer = setTimeout(() => {
        this.#fail(`ask timed out after ${ASK_TIMEOUT_MS}ms; stderr=${this.#stderr}`);
      }, ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve: resolveAsk, reject: rejectAsk, timer });
      const payload = typeof raw === "string" ? Buffer.from(`${raw}\n`, "utf8") : Buffer.concat([raw, Buffer.from("\n")]);
      this.#child.stdin!.write(payload, (err) => {
        if (err) this.#fail(`stdin write failed: ${err.message}`);
      });
    });
  }

  writeRawNoReply(raw: string | Buffer): void {
    this.#child.stdin!.write(raw);
  }

  ask(obj: object): Promise<Record<string, unknown>> {
    return this.askRaw(JSON.stringify(obj));
  }

  async kill(): Promise<void> {
    this.#ending = true;
    if (this.#child.exitCode === null && this.#child.signalCode === null) {
      this.#child.kill("SIGKILL");
    }
    await this.#closed;
  }

  async end(): Promise<void> {
    this.#ending = true;
    try {
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(this.#waiting.length, 0, "no ask left unanswered");
      this.#child.stdin!.end();
      const { code, signal } = await this.#closed;
      assert.equal(signal, null, `ended by signal ${signal}; stderr=${this.#stderr}`);
      assert.equal(code, 0, `exit code ${code}; stderr=${this.#stderr}`);
    } finally {
      if (this.#child.exitCode === null && this.#child.signalCode === null) {
        this.#child.kill("SIGKILL");
        await this.#closed;
      }
    }
  }
}

function createVaultDb(path: string, withMembers = true): DatabaseSync {
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode = WAL;
    CREATE TABLE vault_requests (ws TEXT NOT NULL, id TEXT NOT NULL, session TEXT NOT NULL,
      status TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws,id));
    CREATE TABLE vaults (ws TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws,id));`);
  initializeUseIndex(db);
  initializePendingIndex(db);
  initializeReboxIndex(db);
  if (withMembers) initializeVaultMembers(db);
  return db;
}

function seedRichVaultDb(path: string): DatabaseSync {
  const db = createVaultDb(path, true);
  const putReq = db.prepare("INSERT INTO vault_requests VALUES (?, ?, 's', ?, ?)");
  const putVault = db.prepare("INSERT INTO vaults VALUES (?, ?, ?)");
  const edgeBodies: Array<[string, string, string]> = [
    // Ordinary + duplicate keys + save combinations
    ["e01", "granted", '{"item":"e01","vault":"v","at":20}'],
    ["e02", "granted", '{"item":"e02","vault":"wrong","vault":"v","at":20}'],
    ["e03", "granted", '{"item":"e03","vault":"v","at":99,"at":19}'],
    ["e04", "granted", '{"item":"e04","vault":"v","vault":"wrong","at":100}'],
    ["e05", "granted", '{"item":"e05","vault":"v","save":{"typed":true},"save":null,"at":18}'],
    ["e06", "granted", '{"item":"e06","vault":"v","save":null,"save":{"typed":true},"at":101}'],
    // Lone surrogates & U+FFFD & embedded NUL in vault/owner/keys
    ["e07", "granted", '{"item":"e07","vault":"\\ud800","at":3}'],
    ["e08", "granted", '{"item":"e08","vault":"\\udc00","at":3}'],
    ["e09", "granted", '{"item":"e09","vault":"\\ufffd","at":3}'],
    ["e10", "granted", '{"item":"e10","vault":"plain","owner":"\\ud800@x","at":4}'],
    ["e11", "granted", '{"item":"e11","vault":"plain","owner":"\\udc00@x","at":4}'],
    ["e12", "granted", '{"item":"e12","vault":"plain","owner":"\\ufffd@x","at":4}'],
    ["e13", "granted", '{"item":"e13","vault":"plain","owner":"a@x","at":5}'],
    ["e14", "granted", '{"item":"e14","vault":"plain","owner":"a@x\\u0000y","at":5}'],
    ["e15", "granted", '{"item":"e15","vault":"v\\u0000x","at":5}'],
    ["e16", "granted", '{"item":"e16","vault":"v","k\\u0000":1,"at":6}'],
    // Empty vault / owner
    ["e17", "granted", '{"item":"e17","vault":"wrong","vault":"","at":1}'],
    ["e18", "granted", '{"item":"e18","vault":"plain","owner":"wrong","owner":"","at":2}'],
    // Large/special numeric `at`: ±(2^53+1), -0, 1e21, 5e-324, 1e400, -1e400, bool, null, string, object with index keys & dupes
    ["e19", "granted", '{"item":"e19","vault":"v","vault":"v","at":9007199254740993}'],
    ["e20", "granted", '{"item":"e20","vault":"v","vault":"v","at":-9007199254740993}'],
    ["e21", "granted", '{"item":"e21","vault":"v","vault":"v","at":-0}'],
    ["e22", "granted", '{"item":"e22","vault":"v","vault":"v","at":1e21}'],
    ["e23", "granted", '{"item":"e23","vault":"v","vault":"v","at":5e-324}'],
    ["e24", "granted", '{"item":"e24","vault":"v","vault":"v","at":1e400}'],
    ["e25", "granted", '{"item":"e25","vault":"v","vault":"v","at":-1e400}'],
    ["e26", "granted", '{"item":"e26","vault":"v","vault":"v","at":true}'],
    ["e27", "granted", '{"item":"e27","vault":"v","vault":"v","at":false}'],
    ["e28", "granted", '{"item":"e28","vault":"v","vault":"v","at":null}'],
    ["e29", "granted", '{"item":"e29","vault":"v","vault":"v","at":"t\\udfff"}'],
    ["e30", "granted", '{"item":"e30","vault":"v","vault":"v","at":{"b":1.5,"2":[true,null,1e21,-0,5e-324],"10":"x\\ud800","0":1,"a":2,"b":9,"01":3}}'],
    // Pending requests (ordinary, duplicate keys, NUL keys)
    ["p01", "pending", '{"item":"p01","vault":"v","at":10}'],
    ["p02", "pending", '{"item":"p02","vault":"plain","owner":"o@x","at":11}'],
    ["p03", "pending", '{"item":"p03","vault":"v","vault":"v2","at":12}'],
    ["p04", "pending", '{"item":"p04","vault":"v","k\\u0000":1,"at":13}'],
    ["p05", "pending", '{"item":"p05","vault":"v","save":{"typed":true},"owner":"o@x","at":14}'],
  ];
  db.exec("BEGIN");
  for (const ws of ["w", "x"]) {
    for (const [id, status, body] of edgeBodies) {
      putReq.run(ws, `${ws}-${id}`, status, body);
    }
    // Add enough extra rows (> 32 batch limit) to force multi-batch backfill
    for (let i = 0; i < 40; i++) {
      const status = i % 3 === 0 ? "pending" : i % 2 === 0 ? "granted" : "denied";
      putReq.run(ws, `${ws}-z${String(i).padStart(3, "0")}`, status, `{"item":"${ws}-z${i}","vault":"v","at":${1000 + i}}`);
    }
    putVault.run(ws, "v-ok", '{"members":["a@x","b@x"]}');
    putVault.run(ws, "v-bad", '{"members":"not-array"}');
    putVault.run(ws, "v-dup", '{"members":["a@x"],"members":["c@x"]}');
    putVault.run(ws, "v-nul", '{"members\\u0000x":["a@x"],"members":["d@x"]}');
  }
  db.exec("COMMIT");
  // Wipe lookup tables so backfill must process everything from scratch.
  db.exec(`
    DELETE FROM vault_use_lookup;
    DELETE FROM vault_use_backfill;
    DELETE FROM vault_use_ambiguous_v2;
    DELETE FROM vault_use_ambiguous_audit_v2;
    UPDATE vault_use_backfill_all SET after_ws = NULL, done = 0 WHERE id = 1;
    DELETE FROM vault_pending_lookup;
    DELETE FROM vault_pending_backfill;
    DELETE FROM vault_pending_audit_v2;
    DELETE FROM vault_pending_duplicates_v2;
    DELETE FROM vault_pending_nul_audit_v3;
    DELETE FROM vault_pending_nul_v3;
    DELETE FROM vault_member_lookup;
    DELETE FROM vault_member_invalid;
    DELETE FROM vault_member_backfill;
    DELETE FROM vault_member_audit_v2;
    DELETE FROM vault_member_duplicates_v2;
    DELETE FROM vault_member_type_audit_v3;
    DELETE FROM vault_member_nul_audit_v4;
    DELETE FROM vault_member_nul_v4;
    DELETE FROM vault_rebox_lookup;
    UPDATE vault_rebox_backfill SET after_ws = NULL, after_id = NULL, done = 0 WHERE id = 1;
  `);
  db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  return db;
}

function snapshotVaultTables(db: DatabaseSync): string[] {
  const names = (
    db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'vault_%' AND name <> 'vault_requests' AND name <> 'vaults' ORDER BY name",
    ).all() as { name: string }[]
  ).map((r) => r.name);
  const out: string[] = [];
  for (const name of names) {
    if (name === "vault_use_ambiguous_v2") {
      const stmt = db.prepare(
        "SELECT ws, id, dirty, is_use, typeof(vault) AS tv, hex(vault) AS hv, typeof(owner) AS to_, hex(owner) AS ho, typeof(at) AS tat, CAST(at AS TEXT) AS at_txt FROM vault_use_ambiguous_v2 ORDER BY ws, id",
      );
      stmt.setReadBigInts(true);
      for (const r of stmt.all() as Record<string, unknown>[]) {
        out.push(`${name} ${JSON.stringify(r, (_, v) => (typeof v === "bigint" ? `${v}n` : v))}`);
      }
    } else {
      const stmt = db.prepare(`SELECT * FROM ${name}`);
      stmt.setReadBigInts(true);
      const rows = (stmt.all() as Record<string, unknown>[]).map((r) =>
        `${name} ${JSON.stringify(r, (_, v) => {
          if (typeof v === "bigint") return `${v}n`;
          if (v instanceof Uint8Array) return `blob:${Buffer.from(v).toString("hex")}`;
          return v;
        })}`,
      ).sort();
      out.push(...rows);
    }
  }
  return out;
}

test("builders_vault: file-backed UseIndex hot-switches MB <-> Pion after idle release, preserves #known, and falls back on legacy Pion", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (bins === null) return;

  const dir = freshDir("vault-hot-switch-");
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const legacyLog = join(dir, "legacy.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "pion-wrap.sh", bins.realPion, pionLog);
  const legacyStub = makeLegacyPionStub(dir, "legacy-pion.sh", legacyLog);

  const dbPath = join(dir, "stillfail.db");
  const db = seedRichVaultDb(dbPath);

  let modeCfg: ReaderSelectConfig = { readers: { "vault-uses": "mb" } };
  let idleCallback: (() => void) | null = null;
  let idleWaiter: PromiseWithResolvers<() => void> | null = null;
  const fakeAfter = (_ms: number, f: () => void) => {
    idleCallback = f;
    if (idleWaiter !== null) {
      const w = idleWaiter;
      idleWaiter = null;
      w.resolve(f);
    }
    return () => {
      if (idleCallback === f) idleCallback = null;
    };
  };
  const awaitIdle = (): Promise<() => void> => {
    if (idleCallback !== null) return Promise.resolve(idleCallback);
    if (idleWaiter === null) idleWaiter = Promise.withResolvers<() => void>();
    return idleWaiter.promise;
  };

  await withEnv(
    {
      STILLFAIL_MB_READER: mbWrap,
      STILLFAIL_PION_READER: pionWrap,
      STILLFAIL_READER_ENGINE: undefined,
      [readerModeEnvKey("vault-uses")]: undefined,
    },
    async () => {
      // Pre-warm capability probe so Pion is ready once selected.
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported?.has("vault-uses"), "real stillfail-pion must advertise vault-uses in --version modes:");

      const index = new UseIndex(db, {
        readers: () => modeCfg,
        after: fakeAfter,
      });
      try {
        // 1. Default / config="mb": spawns real MB binary and completes background uses + rebox.
        const pageMb = await index.read("w", "v", null, 5);
        assert.equal(pageMb.length, 5);
        await index.preparePending("w", true, true);

        // Wait deterministically (no sleep/polling) until background work (uses + rebox) settles and arms idle timer.
        await awaitIdle();
        assert.notEqual(idleCallback, null, "UseIndex must become idle once background uses + rebox complete");
        assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder vault-uses")), "MB binary must have been spawned");
        assert.equal(
          readSpawns(pionLog).filter((l) => l.includes("--builder vault-uses")).length,
          0,
          "Pion must NOT spawn while config selects mb",
        );

        // Verify background backfill completed in DB.
        assert.equal(
          (db.prepare("SELECT done FROM vault_use_backfill_all WHERE id = 1").get() as { done: number }).done,
          1,
        );
        assert.equal(
          (db.prepare("SELECT done FROM vault_rebox_backfill WHERE id = 1").get() as { done: number }).done,
          1,
        );

        // 2. Release idle worker (via trimIdle), tamper DB done flags back to 0 to prove
        //    `#known` prevents rescanning completed background batches on the new engine!
        const trimmed1 = index.trimIdle();
        assert.equal(trimmed1, 1, "trimIdle must release idle MB worker");
        assert.equal(index.running, false);

        db.exec("UPDATE vault_use_backfill_all SET after_ws = NULL, done = 0 WHERE id = 1");
        db.exec("UPDATE vault_rebox_backfill SET after_ws = NULL, after_id = NULL, done = 0 WHERE id = 1");

        // 3. Hot-switch config to Pion -> next read spawns real Pion binary and returns identical page.
        clearSpawns(mbLog);
        clearSpawns(pionLog);
        modeCfg = { readers: { "vault-uses": "pion" } };
        assert.equal(
          resolveReaderSelection("vault-uses", { config: () => modeCfg }).engine,
          "pion",
          "config.readers['vault-uses']='pion' must resolve to pion after capability probe",
        );
        const pagePion = await index.read("w", "v", null, 5);
        assert.deepEqual(pagePion, pageMb, "Pion page after hot-switch must match MB page");
        // Wait until the newly spawned Pion MbUseReader settles to idle before asserting #known prevented rescanning.
        await awaitIdle();
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder vault-uses")), "Pion binary must have been spawned");
        assert.equal(readSpawns(mbLog).length, 0, "MB must NOT spawn while config selects pion");

        // Verify #known prevented rescanning uses & rebox (the tampered 0 flags stayed 0 even after Pion went idle!).
        assert.equal(
          (db.prepare("SELECT done FROM vault_use_backfill_all WHERE id = 1").get() as { done: number }).done,
          0,
          "#known must prevent Pion from rescanning already-settled uses backfill",
        );
        assert.equal(
          (db.prepare("SELECT done FROM vault_rebox_backfill WHERE id = 1").get() as { done: number }).done,
          0,
          "#known must prevent Pion from rescanning already-settled rebox backfill",
        );

        // 4. Release idle Pion worker and hot-switch back to MB.
        const trimmed2 = index.trimIdle();
        assert.equal(trimmed2, 1, "trimIdle must release idle Pion worker");
        assert.equal(index.running, false);

        clearSpawns(mbLog);
        clearSpawns(pionLog);
        modeCfg = { readers: { "vault-uses": "mb" } };
        const pageBackMb = await index.read("w", "\ud800", null, 10);
        await awaitIdle();
        assert.equal(pageBackMb.length, 1);
        assert.equal((JSON.parse(pageBackMb[0]!) as { item: string }).item, "e07");
        assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder vault-uses")), "MB must spawn after switching back");
        assert.equal(readSpawns(pionLog).length, 0, "Pion must NOT spawn after switching back to mb");
      } finally {
        await index.close();
      }
    },
  );

  // 4b. Pre-warmed STILLFAIL_READER_VAULT_USES=pion env switch spawns real Pion binary (never MB).
  await withEnv(
    {
      STILLFAIL_MB_READER: mbWrap,
      STILLFAIL_PION_READER: pionWrap,
      [readerModeEnvKey("vault-uses")]: "pion",
    },
    async () => {
      clearSpawns(mbLog);
      clearSpawns(pionLog);
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported?.has("vault-uses"));
      assert.equal(
        resolveReaderSelection("vault-uses").engine,
        "pion",
        "STILLFAIL_READER_VAULT_USES=pion must resolve to engine='pion' after probe",
      );
      const envIndex = new UseIndex(db, { after: fakeAfter });
      try {
        const pageEnv = await envIndex.read("w", "\ud800", null, 10);
        assert.equal(pageEnv.length, 1);
        assert.equal((JSON.parse(pageEnv[0]!) as { item: string }).item, "e07");
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder vault-uses")), "env switch must spawn Pion");
        assert.equal(readSpawns(mbLog).length, 0, "env switch must NOT spawn MB");
      } finally {
        await envIndex.close();
      }
    },
  );

  // 5. Legacy Pion binary without `modes:` falls back safely to MB with deduped warning.
  const heard: Line[] = [];
  hearLines((line) => heard.push(line));
  try {
    await withEnv(
      {
        STILLFAIL_MB_READER: mbWrap,
        STILLFAIL_PION_READER: legacyStub,
        [readerModeEnvKey("vault-uses")]: "pion",
      },
      async () => {
        clearSpawns(mbLog);
        clearSpawns(legacyLog);
        await probePionSupportedModes(legacyStub);
        const index = new UseIndex(db, { after: fakeAfter });
        try {
          const page = await index.read("w", "v", null, 3);
          assert.equal(page.length, 3);
          assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder vault-uses")), "must fall back to MB");
          assert.equal(
            readSpawns(legacyLog).filter((l) => l.includes("--builder vault-uses")).length,
            0,
            "legacy Pion stub must never be spawned for vault-uses",
          );
          assert.ok(
            heard.some((l) => l.message.includes("pion-binary-unsupported-mode") || JSON.stringify(l).includes("pion-binary-unsupported-mode")),
            "fallback must log pion-binary-unsupported-mode",
          );
        } finally {
          await index.close();
        }
      },
    );
  } finally {
    hearLines(null);
    db.close();
  }
});

test("builders_vault: dual-process 0-diff parity on UTF-16LE BLOBs, JS numbers, duplicate keys, ambiguity, pending/members/rebox, and request-line errors", async (t) => {
  const bins = resolveBinaries(t);
  if (bins === null) return;

  const dir = freshDir("vault-parity-");
  const mbPath = join(dir, "mb.db");
  const pionPath = join(dir, "pion.db");
  const mbDb = seedRichVaultDb(mbPath);
  const pionDb = seedRichVaultDb(pionPath);
  const mbProc = new VaultProc(bins.realMb, mbPath);
  const pionProc = new VaultProc(bins.realPion, pionPath);

  try {
    // 1. Empty lines silently skipped before a valid request.
    mbProc.writeRawNoReply("\n\n");
    pionProc.writeRawNoReply("\n\n");

    // 2. Ready before preparation -> {"unready": true} for both use reads and arbitrary string `kind` pending.
    for (const q of [
      { id: 1, ws: "w", vault: "v", owner: null, limit: 10 },
      { kind: "custom-pending-kind", id: 2, ws: "w", members: true, audit: true },
    ]) {
      const [mRes, pRes] = await Promise.all([
        mbProc.ask({ op: "ready", q }),
        pionProc.ask({ op: "ready", q }),
      ]);
      assert.deepStrictEqual(pRes, { unready: true });
      assert.deepStrictEqual(pRes, mRes);
    }

    // 3. Step-by-step `prepare` for uses on workspace "w" until complete, comparing every step & table snapshot.
    const useQ = { id: 10, ws: "w", vault: "v", owner: null, limit: 25 };
    let steps = 0;
    for (let done = false; !done && steps < 30; steps++) {
      const [mRes, pRes] = await Promise.all([
        mbProc.ask({ op: "prepare", q: useQ }),
        pionProc.ask({ op: "prepare", q: useQ }),
      ]);
      assert.deepStrictEqual(pRes, mRes, `prepare uses step ${steps}`);
      assert.deepStrictEqual(snapshotVaultTables(pionDb), snapshotVaultTables(mbDb), `tables after prepare uses step ${steps}`);
      done = mRes.complete === true;
    }
    assert.ok(steps >= 3, `expected multi-batch prepare, got ${steps}`);

    // 4. Verify all edge-case reads (lone surrogates, U+FFFD, embedded NUL, empty vault/owner, ±(2^53+1), mixed `at`, ordering).
    const edgeReads = [
      { id: 11, ws: "w", vault: "v", owner: null, limit: 100 },
      { id: 12, ws: "w", vault: "wrong", owner: null, limit: 10 },
      { id: 13, ws: "w", vault: "\ud800", owner: null, limit: 10 },
      { id: 14, ws: "w", vault: "\udc00", owner: null, limit: 10 },
      { id: 15, ws: "w", vault: "\ufffd", owner: null, limit: 10 },
      { id: 16, ws: "w", vault: "plain", owner: "\ud800@x", limit: 10 },
      { id: 17, ws: "w", vault: "plain", owner: "\udc00@x", limit: 10 },
      { id: 18, ws: "w", vault: "plain", owner: "\ufffd@x", limit: 10 },
      { id: 19, ws: "w", vault: "plain", owner: "a@x", limit: 10 },
      { id: 20, ws: "w", vault: "plain", owner: "a@x\0y", limit: 10 },
      { id: 21, ws: "w", vault: "v\0x", owner: null, limit: 10 },
      { id: 22, ws: "w", vault: "", owner: null, limit: 10 },
      { id: 23, ws: "w", vault: "plain", owner: "", limit: 10 },
    ];
    for (const q of edgeReads) {
      const [mRes, pRes] = await Promise.all([
        mbProc.ask({ op: "ready", q }),
        pionProc.ask({ op: "ready", q }),
      ]);
      assert.deepStrictEqual(pRes, mRes, `ready ${JSON.stringify(q)}`);
      assert.deepStrictEqual((pRes.answered as { bodies: string[] }).bodies, tryReadUses(mbDb, q), `tryReadUses ${JSON.stringify(q)}`);
    }

    // 5. Pending preparation with arbitrary string `kind`, members=true, audit=true, plus `uses` and `rebox`.
    for (const [op, q] of [
      ["prepare", { kind: "arbitrary-str", id: 30, ws: "w", members: true, audit: true }],
      ["uses", undefined],
      ["rebox", undefined],
    ] as const) {
      let k = 0;
      for (let done = false; !done && k < 30; k++) {
        const payload = q ? { op, q } : { op };
        const [mRes, pRes] = await Promise.all([mbProc.ask(payload), pionProc.ask(payload)]);
        assert.deepStrictEqual(pRes, mRes, `${op} step ${k}`);
        assert.deepStrictEqual(snapshotVaultTables(pionDb), snapshotVaultTables(mbDb), `tables after ${op} step ${k}`);
        done = op === "prepare" ? mRes.complete === true : mRes.done === true;
      }
      assert.ok(k >= 2, `${op} should take multiple steps, got ${k}`);
    }

    // 6. Ready for pending after preparation -> {"answered":{"id":31,"ready":true}} (any string kind).
    {
      const q = { kind: "any-string", id: 31, ws: "w", members: true, audit: true };
      const [mRes, pRes] = await Promise.all([mbProc.ask({ op: "ready", q }), pionProc.ask({ op: "ready", q })]);
      assert.deepStrictEqual(pRes, { answered: { id: 31, ready: true } });
      assert.deepStrictEqual(pRes, mRes);
    }

    // 7. Request-line error parity (raw byte-for-byte comparison, zero prefix stripping):
    //    malformed JSON (exact UTF-16 error offset), invalid UTF-8 bytes (WHATWG lossy U+FFFD),
    //    unknown op, and corrupted DB body JSON (`JSON.parse: ` prefix).
    {
      const badLine = Buffer.from('{"op":"🚀",bad}', "utf8"); // emoji = 2 UTF-16 code units -> offset 11
      const [mRes, pRes] = await Promise.all([mbProc.askRaw(badLine), pionProc.askRaw(badLine)]);
      assert.deepStrictEqual(Object.keys(pRes), ["error"], "unreadable request error must have no id");
      assert.strictEqual(pRes.error, "unreadable request: unexpected input at 11");
      assert.deepStrictEqual(pRes, mRes, "unreadable request error must match MB byte-for-byte");
    }
    for (const rawReq of [
      Buffer.concat([Buffer.from('{"op":"ready","q":{"id":1,"ws":"w","vault":"'), Buffer.from([0xff, 0xfe]), Buffer.from('","owner":null,"limit":5}}')]),
      Buffer.from('{"op":"no-such-op"}', "utf8"),
    ]) {
      const [mRes, pRes] = await Promise.all([mbProc.askRaw(rawReq), pionProc.askRaw(rawReq)]);
      assert.deepStrictEqual(pRes, mRes, `raw request parity: ${rawReq.toString("hex")}`);
    }

    // Corrupted body marked dirty in vault_use_ambiguous_v2 -> both return exact {"error": "JSON.parse: unexpected input at 14"} with NO id.
    for (const db of [mbDb, pionDb]) {
      db.exec("DROP TRIGGER IF EXISTS vault_use_lookup_add");
      db.prepare("INSERT INTO vault_requests VALUES ('w', 'bad-json', 's', 'granted', '{\"vault\":\"🚀\",oops}')").run();
      db.prepare("INSERT OR REPLACE INTO vault_use_ambiguous_v2 (ws, id, dirty, is_use) VALUES ('w', 'bad-json', 1, 0)").run();
    }
    {
      const [mRes, pRes] = await Promise.all([
        mbProc.ask({ op: "prepare", q: { id: 99, ws: "w", vault: "v", owner: null, limit: 5 } }),
        pionProc.ask({ op: "prepare", q: { id: 99, ws: "w", vault: "v", owner: null, limit: 5 } }),
      ]);
      assert.deepStrictEqual(Object.keys(pRes), ["error"], "JSON.parse error must have no id");
      assert.strictEqual(pRes.error, "JSON.parse: unexpected input at 14");
      assert.deepStrictEqual(pRes, mRes, "JSON.parse error must match MB byte-for-byte");
    }

    await Promise.all([mbProc.end(), pionProc.end()]);
  } finally {
    await Promise.all([mbProc.kill(), pionProc.kill()]);
    mbDb.close();
    pionDb.close();
  }
});

test("builders_vault: SQLITE_BUSY returns {busy:true} (no id) and ordinary SQL error returns {error:...} (no id) with 0-diff recovery", async (t) => {
  const bins = resolveBinaries(t);
  if (bins === null) return;

  const dir = freshDir("vault-busy-");
  const mbPath = join(dir, "mb.db");
  const pionPath = join(dir, "pion.db");
  const mbDb = seedRichVaultDb(mbPath);
  const pionDb = seedRichVaultDb(pionPath);
  const mbLocker = new DatabaseSync(mbPath);
  const pionLocker = new DatabaseSync(pionPath);
  const mbProc = new VaultProc(bins.realMb, mbPath);
  const pionProc = new VaultProc(bins.realPion, pionPath);

  try {
    // 1. Hold write lock on both DBs -> prepare / rebox / uses must return {"busy": true} (no id).
    mbLocker.exec("BEGIN IMMEDIATE");
    pionLocker.exec("BEGIN IMMEDIATE");
    for (const payload of [
      { op: "prepare", q: { id: 42, ws: "w", vault: "v", owner: null, limit: 5 } },
      { op: "rebox" },
      { op: "uses" },
    ]) {
      const [mRes, pRes] = await Promise.all([mbProc.ask(payload), pionProc.ask(payload)]);
      assert.deepStrictEqual(Object.keys(pRes), ["busy"], "busy reply must have only key 'busy' (no id)");
      assert.deepStrictEqual(pRes, { busy: true });
      assert.deepStrictEqual(pRes, mRes);
    }
    mbLocker.exec("ROLLBACK");
    pionLocker.exec("ROLLBACK");

    // 2. After releasing lock, ordinary SQL error via trigger -> {"error": "repair failure"} (no id), rolled back cleanly.
    for (const db of [mbDb, pionDb]) {
      // Advance backfill + audit so next prepare step hits repair_ambiguous.
      while (!backfillUsePreparation(db, "w")) {}
      db.prepare("UPDATE vault_use_ambiguous_v2 SET dirty = 1 WHERE ws = 'w' AND id = 'w-e02'").run();
      db.exec("CREATE TRIGGER fail_repair BEFORE UPDATE ON vault_use_ambiguous_v2 BEGIN SELECT RAISE(ABORT, 'repair failure'); END");
    }
    {
      const payload = { op: "prepare", q: { id: 55, ws: "w", vault: "v", owner: null, limit: 5 } };
      const [mRes, pRes] = await Promise.all([mbProc.ask(payload), pionProc.ask(payload)]);
      assert.deepStrictEqual(Object.keys(pRes), ["error"], "SQL error reply must have only key 'error' (no id)");
      assert.deepStrictEqual(pRes, { error: "repair failure" });
      assert.deepStrictEqual(pRes, mRes);
    }

    // Drop trigger and recover cleanly to 0-diff.
    for (const db of [mbDb, pionDb]) db.exec("DROP TRIGGER fail_repair");
    {
      const payload = { op: "prepare", q: { id: 56, ws: "w", vault: "v", owner: null, limit: 5 } };
      const [mRes, pRes] = await Promise.all([mbProc.ask(payload), pionProc.ask(payload)]);
      assert.equal(pRes.complete, true);
      assert.deepStrictEqual(pRes, mRes);
      assert.deepStrictEqual(snapshotVaultTables(pionDb), snapshotVaultTables(mbDb));
    }

    await Promise.all([mbProc.end(), pionProc.end()]);
  } finally {
    await Promise.all([mbProc.kill(), pionProc.kill()]);
    try { mbLocker.exec("ROLLBACK"); } catch {}
    try { pionLocker.exec("ROLLBACK"); } catch {}
    mbLocker.close();
    pionLocker.close();
    mbDb.close();
    pionDb.close();
  }
});

// ── Static SQLite lexical transaction guard on builders_vault (`+`-folding + quoted identifiers) ──

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
        else out += esc;
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

type TxViolation = { file: string; line: number; keyword: string };

function findRawTxViolations(filename: string, source: string): TxViolation[] {
  const violations: TxViolation[] = [];
  const forbidden = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  for (const expr of extractPionStringExprs(source)) {
    const tokens = tokenizeSql(expr.value);
    let atStmtStart = true;
    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t]!;
      if (tok.kind === "semi") { atStmtStart = true; continue; }
      if (!atStmtStart) continue;
      atStmtStart = false;
      if (tok.kind !== "word" || !forbidden.has(tok.upper)) continue;
      if (
        (tok.upper === "RELEASE" || tok.upper === "SAVEPOINT") &&
        tokens[t + 1]?.kind !== "word" &&
        tokens[t + 1]?.kind !== "ident" &&
        tokens[t + 1]?.kind !== "str"
      ) {
        continue;
      }
      violations.push({ file: filename, line: expr.line, keyword: tok.upper });
    }
  }
  return violations;
}

function lineOfNeedle(source: string, needle: string): number {
  const idx = source.indexOf(needle);
  assert.ok(idx >= 0, `expected anchor ${JSON.stringify(needle)} in source`);
  return source.slice(0, idx).split("\n").length;
}

test("builders_vault: static SQLite transaction guard (+-folding + quoted identifiers) has 0 violations and catches real closure-body mutations", () => {
  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_vault/src", import.meta.url)));
  const files = readdirSync(srcDir)
    .filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion"))
    .sort();
  assert.deepStrictEqual(files, ["ops.pion", "pending.pion", "steps.pion"]);

  for (const file of files) {
    const content = readFileSync(join(srcDir, file), "utf8");
    assert.deepStrictEqual(
      findRawTxViolations(file, content),
      [],
      `${file} must contain zero raw transaction SQL`,
    );
  }

  // Real closure-body mutation checks (exact anchor lines inside `tx_bool(db, fn(tx_db ...))` and `savepoint_swallow_err`):
  const stepsSrc = readFileSync(join(srcDir, "steps.pion"), "utf8");
  const pendingSrc = readFileSync(join(srcDir, "pending.pion"), "utf8");

  const stepsTxAnchor = 'let audit = match tx_db.first(\n      "SELECT after_id, done FROM vault_use_ambiguous_audit_v2 WHERE ws = ?",';
  const stepsTxLine = lineOfNeedle(stepsSrc, stepsTxAnchor);
  assert.deepStrictEqual(
    findRawTxViolations("steps.pion", stepsSrc.replace(stepsTxAnchor, `let _ = tx_db.exec("COM" + "MIT")\n    ${stepsTxAnchor}`)),
    [{ file: "steps.pion", line: stepsTxLine, keyword: "COMMIT" }],
    "must detect +-folded COMMIT injected inside tx_err closure in steps.pion at exact line",
  );

  const stepsSpAnchor = "let state = match use_state(sp_db, q.ws) {";
  const stepsSpLine = lineOfNeedle(stepsSrc, stepsSpAnchor);
  assert.deepStrictEqual(
    findRawTxViolations("steps.pion", stepsSrc.replace(stepsSpAnchor, `let _ = sp_db.exec("RELEASE [vault_use_page]")\n      ${stepsSpAnchor}`)),
    [{ file: "steps.pion", line: stepsSpLine, keyword: "RELEASE" }],
    "must detect quoted RELEASE injected inside savepoint_swallow_err closure in steps.pion at exact line",
  );

  // Anchor directly inside `backfill_pending_audit`'s `tx_bool(db, fn(tx_db : sql_db::Db) ...)` write closure (~line 179).
  const pendingTxAnchor = 'let audit = match tx_db.first("SELECT after_id, done FROM " + progress + " WHERE ws = ?", [ws]) {';
  const pendingTxLine = lineOfNeedle(pendingSrc, pendingTxAnchor);
  assert.ok(pendingTxLine > 170, `pending.pion tx closure anchor must be inside backfill_pending_audit (>170), got ${pendingTxLine}`);
  assert.deepStrictEqual(
    findRawTxViolations("pending.pion", pendingSrc.replace(pendingTxAnchor, `let _ = tx_db.exec("ROLL" + "BACK")\n    ${pendingTxAnchor}`)),
    [{ file: "pending.pion", line: pendingTxLine, keyword: "ROLLBACK" }],
    "must detect +-folded ROLLBACK injected inside tx_err closure in pending.pion at exact line",
  );
});
