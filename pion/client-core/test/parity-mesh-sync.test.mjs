// W27d Differential Parity & E2E Test Suite (`parity-mesh-sync.test.mjs`):
//   1. 1:1 differential parity of ALL expanded ops in Pion `sync::ops_request` vs real
//      `client/core-ts/src/ops.ts` `request(name, params)` (method, path, query, body, fallback, effect: 0 diffs).
//   2. Real `pion/base/packages/mesh` `MeshStationTransport` / `shell_mesh_transport` handshake:
//      - ALPN === "stillfail/admin/1", control line `protocol === 2`, Cloud member credential
//      - Ed25519 `claimBy` signature cross-verified by BOTH Pion `native_lock_crypto().endpoint_proof`
//        AND Node `@noble/curves/ed25519` over `client/core-ts/src/lock.ts` `endpointBytes`!
//      - `lock_unconfirmed: true` surfaced cleanly, HTTP + SSE + `reply.cancel()` + `Link::exchange_k`.
//   3. Real `node:sqlite` E2E verification of:
//      - `GET /lock` (`fetch_lock_k`) + SSE `event: lock` valid persistence to `workspace_pref(ws, "lock")`
//        and malicious `G_evil` rejection (`LockRejected`).
//      - `GET /chats?marks=1&own=1` (`fetch_marks_k`) atomic SQLite `shared_mark` persistence,
//        `marks_dirty` targeted refresh without wiping `RowsMemo`, and `missed` resync.
//      - Multi-station `attach_station_transport` auto-flush and clear recovery hints.
//
// Compiles a temporary native Pion driver in `os.tmpdir()` (zero edits to `parity_cli`) and
// cleans up all temporary artifacts in `after()`.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { ed25519 } from "../../../client/core-ts/node_modules/@noble/curves/ed25519.js";
import { holdLanguage } from "../../../client/core-ts/src/i18n.ts";
import { endpointBytes } from "../../../client/core-ts/src/lock.ts";
import { request as tsOpsRequest } from "../../../client/core-ts/src/ops.ts";
import { AccountDb } from "../../../client/core-ts/src/db/account.ts";
import { ensureSharedSidecar } from "../../../client/core-ts/src/db/schema.ts";
import { Runner } from "../../../client/core-ts/src/runtime.ts";
import { TestTime } from "../../../client/core-ts/src/testing.ts";

holdLanguage();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const clientCoreRoot = path.join(repoRoot, "pion/client-core");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

function makeNodeSql(dbPath = ":memory:") {
  const db = new DatabaseSync(dbPath);
  const stmts = new Map();
  const stmt = (sql) => {
    let s = stmts.get(sql);
    if (!s) {
      s = db.prepare(sql);
      stmts.set(sql, s);
    }
    return s;
  };
  return {
    raw: db,
    exec(sql) {
      db.exec(sql);
    },
    run(sql, params = []) {
      const r = stmt(sql).run(...params);
      return Number(r.changes ?? 0);
    },
    all(sql, params = []) {
      const s = stmt(sql);
      s.setReturnArrays(true);
      return s.all(...params);
    },
    close() {
      stmts.clear();
      db.close();
    },
  };
}

function makeDummyDerive() {
  return {
    tone: () => null,
    asks: () => false,
    state: () => "idle",
    watched: () => false,
  };
}

function unhex(h) {
  return Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
}

const DRIVER_MAIN_PION = `// Temporary native Pion driver for parity-mesh-sync.test.mjs
import "base_codec"
import "crypto"
import "effect"
import "form"
import "lock"
import "mesh"
import "outbox"
import "shell"
import "sql"
import "store"
import "sync"

fn j_str(j : base_codec::Json, k : String) -> String {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Str(s)) => s
    _ => ""
  }
}

fn j_int(j : base_codec::Json, k : String) -> Int {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Num(n, _)) => n.to_int()
    _ => 0
  }
}

fn bytes_to_str(b : Bytes) -> String {
  let sb = StringBuilder::new()
  for i in 0..<b.length() {
    sb.write_byte(b[i])
  }
  sb.to_string()
}

fn make_seed(tag : Int) -> Bytes {
  let b = Bytes::new(32)
  for i in 0..<32 {
    b[i] = ((tag + i * 13) & 0xFF) as Byte
  }
  b
}

fn run_mesh_handshake_check() -> base_codec::Json {
  let rt = effect::Runtime::new()
  let storage : Map[String, Bytes] = Map::new()
  let mut captured_alpn = ""
  let mut captured_hello_line = ""
  let mut captured_refresh_line = ""
  let mut saw_stream_reset = false
  let mut next_stream_id = 30
  let mut ctrl_stream_id = 0
  let mut ctrl_write_count = 0
  let mut ctrl_pending_read : Option[Int64] = None
  let mut http_stream_id = 0
  let mut http_read_step = 0
  let mut sse_stream_id = 0
  let mut sse_read_step = 0
  let mut local_ep_id = ""
  let peer_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  let holder : Array[shell::Shell] = []
  let sh = shell::Shell::stood_in(
    rt,
    fn(id : Int64, op : String, args : base_codec::Json, bytes : Option[Bytes]) -> Unit {
      let s = holder[0]
      if op == "storage.get" {
        s.answer(id, base_codec::json_obj([]), bytes=storage.get(j_str(args, "key")))
        return
      }
      if op == "storage.set" {
        match bytes { Some(b) => storage.set(j_str(args, "key"), b); None => () }
        s.answer(id, base_codec::json_obj([]))
        return
      }
      if op == "iroh.bind" {
        let seed = match bytes { Some(b) => b; None => Bytes::new(32) }
        local_ep_id = crypto::sha256_hex(seed)
        s.answer(id, base_codec::json_obj([("id", base_codec::json_int(10))]))
        return
      }
      if op == "iroh.connect" {
        captured_alpn = match bytes { Some(b) => bytes_to_str(b); None => "" }
        s.answer(id, base_codec::json_obj([("id", base_codec::json_int(20))]))
        return
      }
      if op == "conn.closed" {
        return
      }
      if op == "conn.close" || op == "iroh.close" {
        s.answer(id, base_codec::json_obj([]))
        return
      }
      if op == "conn.openBi" {
        let sid = next_stream_id
        next_stream_id += 1
        if ctrl_stream_id == 0 {
          ctrl_stream_id = sid
        } else if http_stream_id == 0 {
          http_stream_id = sid
        } else {
          sse_stream_id = sid
        }
        s.answer(id, base_codec::json_obj([("id", base_codec::json_int(sid))]))
        return
      }
      if op == "istream.write" {
        let sid = j_int(args, "id")
        let payload = match bytes { Some(b) => bytes_to_str(b); None => "" }
        if sid == ctrl_stream_id {
          ctrl_write_count += 1
          if ctrl_write_count == 1 {
            captured_hello_line = payload
          } else {
            captured_refresh_line = payload
          }
          s.answer(id, base_codec::json_obj([]))
          match ctrl_pending_read {
            Some(rid) => {
              ctrl_pending_read = None
              let ans = if ctrl_write_count == 1 {
                "{\\"ok\\":true,\\"lock_unconfirmed\\":true,\\"station\\":{\\"id\\":\\"st-mesh-1\\",\\"name\\":\\"Studio\\"}}\\n"
              } else {
                "{\\"ok\\":true,\\"lock_unconfirmed\\":false,\\"station\\":{\\"id\\":\\"st-mesh-1\\",\\"name\\":\\"Studio\\"}}\\n"
              }
              s.answer(rid, base_codec::json_obj([]), bytes=Some(ans.to_bytes()))
            }
            None => ()
          }
          return
        }
        s.answer(id, base_codec::json_obj([]))
        return
      }
      if op == "istream.finish" {
        s.answer(id, base_codec::json_obj([]))
        return
      }
      if op == "istream.reset" {
        saw_stream_reset = true
        s.answer(id, base_codec::json_obj([]))
        return
      }
      if op == "istream.read" {
        let sid = j_int(args, "id")
        if sid == ctrl_stream_id {
          if ctrl_write_count == 1 {
            s.answer(id, base_codec::json_obj([]), bytes=Some("{\\"ok\\":true,\\"lock_unconfirmed\\":true,\\"station\\":{\\"id\\":\\"st-mesh-1\\",\\"name\\":\\"Studio\\"}}\\n".to_bytes()))
          } else if ctrl_write_count >= 2 {
            s.answer(id, base_codec::json_obj([]), bytes=Some("{\\"ok\\":true,\\"lock_unconfirmed\\":false,\\"station\\":{\\"id\\":\\"st-mesh-1\\",\\"name\\":\\"Studio\\"}}\\n".to_bytes()))
          } else {
            ctrl_pending_read = Some(id)
          }
          return
        }
        if sid == http_stream_id {
          if http_read_step == 0 {
            http_read_step = 1
            s.answer(id, base_codec::json_obj([]), bytes=Some("{\\"status\\":200,\\"headers\\":{}}\\n{\\"pong\\":true}".to_bytes()))
          } else {
            s.answer(id, base_codec::json_obj([]), bytes=None)
          }
          return
        }
        if sid == sse_stream_id {
          if sse_read_step == 0 {
            sse_read_step = 1
            s.answer(id, base_codec::json_obj([]), bytes=Some("{\\"status\\":200,\\"headers\\":{\\"content-type\\":\\"text/event-stream\\"}}\\n: hello\\n\\n".to_bytes()))
          }
          return
        }
        s.answer(id, base_codec::json_obj([]), bytes=None)
        return
      }
      s.answer(id, base_codec::json_obj([]))
    },
    fn(op : String, _args : base_codec::Json) -> shell::AskResult {
      if op == "iroh.endpointId" { return shell::AskResult::Ok(base_codec::json_str(local_ep_id)) }
      if op == "iroh.relayStatus" {
        return shell::AskResult::Ok(base_codec::json_arr([
          base_codec::json_obj([("url", base_codec::json_str("https://relay.still.fail/")), ("connected", base_codec::json_bool(true))]),
        ]))
      }
      if op == "conn.closeReason" { return shell::AskResult::Ok(base_codec::json_null()) }
      if op == "conn.paths" { return shell::AskResult::Ok(base_codec::json_arr([])) }
      if op == "conn.stats" { return shell::AskResult::Ok(base_codec::json_obj([("rxBytes", base_codec::json_int(0)), ("txBytes", base_codec::json_int(0))])) }
      shell::AskResult::Err(shell::ShellError::{ message: "unsupported" })
    },
    fn(n : Int) -> Bytes {
      let out = Bytes::new(n)
      for i in 0..<n { out[i] = ((0x33 + i * 5) & 0xFF) as Byte }
      out
    },
  )
  holder.push(sh)

  let cfg = sync::MeshStationConfig::new(
    "ws-parity-mesh",
    peer_id,
    ["https://relay.still.fail/"],
    fn(_dev : String, _fresh : Bool, ck : (effect::Exit[String]) -> Unit) -> Unit {
      ck(effect::Exit::Succeeded("cred-parity-v1"))
    },
    device_kind="app",
    device_label="ParityHost",
  )
  let (ctrl, transport) = sync::shell_mesh_transport(sh, cfg)

  let mut http_status = 0
  let mut http_body = ""
  let _ = rt.fork(fn(k : (effect::Exit[Unit]) -> Unit) -> Unit {
    (transport.request_k)("GET", "/ping", [], Bytes::new(0), fn(ex : effect::Exit[sync::HttpReply]) -> Unit {
      match ex {
        effect::Exit::Succeeded(r) => {
          http_status = r.status
          http_body = bytes_to_str(r.body)
        }
        _ => ()
      }
      k(effect::Exit::Succeeded(()))
    })
  })
  let _ = rt.run_ready()

  let unconfirmed_before = ctrl.is_lock_unconfirmed()
  let mut unconfirmed_after = true
  let _ = rt.fork(fn(k : (effect::Exit[Unit]) -> Unit) -> Unit {
    ctrl.refresh_credential_k("cred-parity-v2", fn(ex : effect::Exit[sync::MeshAdmission]) -> Unit {
      match ex {
        effect::Exit::Succeeded(adm) => { unconfirmed_after = adm.lock_unconfirmed }
        _ => ()
      }
      k(effect::Exit::Succeeded(()))
    })
  })
  let _ = rt.run_ready()

  // Start SSE stream and interrupt it to prove real reply.cancel() -> istream.reset
  let mut sse_chunks = 0
  let sse_fiber = rt.fork(fn(k : (effect::Exit[Unit]) -> Unit) -> Unit {
    (transport.stream_k)("/events", [("accept", "text/event-stream")], fn(_b : Bytes) -> Unit {
      sse_chunks += 1
    }, k)
  })
  let _ = rt.run_ready()
  sse_fiber.interrupt()
  let _ = rt.run_ready()

  let ep_id = match ctrl.device_id() { Some(id) => id; None => "" }
  let hello_j = match base_codec::json_parse(captured_hello_line) {
    base_codec::JsonParseResult::Ok(j) => j
    base_codec::JsonParseResult::Err(_) => base_codec::json_null()
  }
  let lock_j = match base_codec::json_get(hello_j, "lock") { Some(v) => v; None => base_codec::json_null() }
  let claim_dev = j_str(lock_j, "device")
  let claim_proof = j_str(lock_j, "proof")
  let pion_proof_ok = (sync::native_lock_crypto().endpoint_proof)("ws-parity-mesh", claim_dev, ep_id, claim_proof)

  let _ = rt.fork(fn(k : (effect::Exit[Unit]) -> Unit) -> Unit { ctrl.close_k(k) })
  let _ = rt.run_ready()

  base_codec::json_obj([
    ("alpn", base_codec::json_str(captured_alpn)),
    ("hello", hello_j),
    ("endpointId", base_codec::json_str(ep_id)),
    ("pionProofOk", base_codec::json_bool(pion_proof_ok)),
    ("unconfirmedBefore", base_codec::json_bool(unconfirmed_before)),
    ("unconfirmedAfter", base_codec::json_bool(unconfirmed_after)),
    ("refreshLine", base_codec::json_str(captured_refresh_line)),
    ("httpStatus", base_codec::json_int(http_status)),
    ("httpBody", base_codec::json_str(http_body)),
    ("sseChunks", base_codec::json_int(sse_chunks)),
    ("sawStreamReset", base_codec::json_bool(saw_stream_reset)),
  ])
}

fn run_sqlite_lock_marks_multi_e2e(world : World) -> base_codec::Json {
  let rt = effect::Runtime::new()
  let sh = shell::Shell::stood_in(
    rt,
    fn(_id : Int64, _op : String, _args : base_codec::Json, _bytes : Option[Bytes]) -> Unit {},
    fn(op : String, args : base_codec::Json) -> shell::AskResult {
      let req = base_codec::json_obj([
        ("sqlReq", base_codec::json_obj([("op", base_codec::json_str(op)), ("args", args)])),
      ])
      io_println(world, base_codec::json_stringify(req))
      match io_read_line(world) {
        Some(line) =>
        match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Ok(resp) =>
          match base_codec::json_get(resp, "err") {
            Some(base_codec::Json::Str(e)) => shell::AskResult::Err(shell::ShellError::{ message: e })
            _ =>
            match base_codec::json_get(resp, "ok") {
              Some(v) => shell::AskResult::Ok(v)
              None => shell::AskResult::Ok(base_codec::json_null())
            }
          }
          base_codec::JsonParseResult::Err(e) => shell::AskResult::Err(shell::ShellError::{ message: e })
        }
        None => shell::AskResult::Err(shell::ShellError::{ message: "eof" })
      }
    },
    fn(n : Int) -> Bytes { Bytes::new(n) },
  )
  let db = match sql::Sql::open(sh, "w27d-sqlite") {
    sql::SqlResult::Ok(d) => d
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }

  let alice_seed = make_seed(71)
  let evil_seed = make_seed(72)
  let alice_key = sync::ed25519_key_id(alice_seed)
  let evil_key = sync::ed25519_key_id(evil_seed)
  let c = sync::native_lock_crypto()

  let e0 = match sync::sign_lock_entry(
    alice_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-sql-e2e")),
      ("seq", form::Json::Num(0.0)),
      ("prev", form::Json::Null),
      ("at", form::Json::Num(1790002000.0)),
      ("kind", form::Json::Str("genesis")),
      (
        "body",
        form::Json::Obj([
          ("owner", form::Json::Str("alice")),
          ("origins", form::Json::Arr([form::Json::Str("https://app.still.fail")])),
          ("rp_id", form::Json::Str("still.fail")),
          ("cloud_keys", form::Json::Obj([("keys", form::Json::Arr([]))])),
          ("members", form::Json::Arr([form::Json::Obj([("sub", form::Json::Str("alice")), ("email", form::Json::Str("alice@example.com")), ("role", form::Json::Str("owner"))])])),
          ("devices", form::Json::Arr([form::Json::Obj([("id", form::Json::Str("1111111111111111111111111111111111111111111111111111111111111111")), ("sub", form::Json::Str("alice")), ("kind", form::Json::Str("app")), ("label", form::Json::Str("Alice")), ("sign_key", form::Json::Str(alice_key))])])),
          ("passkeys", form::Json::Arr([])),
          ("stations", form::Json::Arr([])),
          ("gateways", form::Json::Arr([])),
        ]),
      ),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let root_g = match lock::entry_hash(e0, c) { Ok(h) => h; Err(_) => "" }

  let e0_evil = match sync::sign_lock_entry(
    evil_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-sql-e2e")),
      ("seq", form::Json::Num(0.0)),
      ("prev", form::Json::Null),
      ("at", form::Json::Num(1790002001.0)),
      ("kind", form::Json::Str("genesis")),
      (
        "body",
        form::Json::Obj([
          ("owner", form::Json::Str("evil")),
          ("origins", form::Json::Arr([form::Json::Str("https://app.still.fail")])),
          ("rp_id", form::Json::Str("still.fail")),
          ("cloud_keys", form::Json::Obj([("keys", form::Json::Arr([]))])),
          ("members", form::Json::Arr([form::Json::Obj([("sub", form::Json::Str("evil")), ("email", form::Json::Str("evil@evil.test")), ("role", form::Json::Str("owner"))])])),
          ("devices", form::Json::Arr([form::Json::Obj([("id", form::Json::Str("2222222222222222222222222222222222222222222222222222222222222222")), ("sub", form::Json::Str("evil")), ("kind", form::Json::Str("app")), ("label", form::Json::Str("Evil")), ("sign_key", form::Json::Str(evil_key))])])),
          ("passkeys", form::Json::Arr([])),
          ("stations", form::Json::Arr([])),
          ("gateways", form::Json::Arr([])),
        ]),
      ),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let root_evil = match lock::entry_hash(e0_evil, c) { Ok(h) => h; Err(_) => "" }

  let lock_resp = base_codec::json_stringify(base_codec::json_obj([
    ("head", base_codec::json_obj([("seq", base_codec::json_int(0)), ("hash", base_codec::json_str(root_g)), ("genesis", base_codec::json_str(root_g))])),
    ("entries", base_codec::json_arr([sync::form_to_codec(e0)])),
  ]))
  let mut marks_resp = "{\\"reads\\":{\\"55\\":9},\\"pins\\":{\\"c-55\\":8888},\\"kept\\":[55],\\"hidden\\":[56],\\"muted\\":[56],\\"dismissed\\":[\\"55:2\\"],\\"selves\\":[\\"U99\\"]}"

  let reqs_st1 : Array[String] = []
  let reqs_st2 : Array[String] = []
  let mut sse_push : Option[(Bytes) -> Unit] = None

  let tr1 = sync::StationTransport::{
    request_k: fn(m : String, p : String, _h : Array[(String, String)], _b : Bytes, k : (effect::Exit[sync::HttpReply]) -> Unit) -> Unit {
      reqs_st1.push(m + " " + p)
      if m == "GET" && p == "/lock" {
        k(effect::Exit::Succeeded(sync::HttpReply::{ status: 200, headers: [], body: lock_resp.to_bytes() }))
        return
      }
      if m == "GET" && p.starts_with("/chats?marks=1&own=1") {
        k(effect::Exit::Succeeded(sync::HttpReply::{ status: 200, headers: [], body: marks_resp.to_bytes() }))
        return
      }
      k(effect::Exit::Succeeded(sync::HttpReply::{ status: 200, headers: [], body: "{\\"chats\\":[],\\"entries\\":[]}".to_bytes() }))
    },
    stream_k: fn(_p : String, _h : Array[(String, String)], on_chunk : (Bytes) -> Unit, _k : (effect::Exit[Unit]) -> Unit) -> Unit {
      sse_push = Some(on_chunk)
    },
  }
  let tr2 = sync::StationTransport::{
    request_k: fn(m : String, p : String, _h : Array[(String, String)], _b : Bytes, k : (effect::Exit[sync::HttpReply]) -> Unit) -> Unit {
      reqs_st2.push(m + " " + p)
      k(effect::Exit::Succeeded(sync::HttpReply::{ status: 200, headers: [], body: "{\\"n\\":1,\\"clientKey\\":\\"ck-multi-1\\"}".to_bytes() }))
    },
    stream_k: fn(_p : String, _h : Array[(String, String)], _on : (Bytes) -> Unit, _k : (effect::Exit[Unit]) -> Unit) -> Unit {},
  }

  let core = sync::ClientCore::new("ws-sql-e2e", "st1", rt, db, tr1, fn() -> Unit {})
  core.set_viewer("alice@example.com")
  let _ = core.events.apply_snapshot(base_codec::json_obj([
    ("chats", base_codec::json_arr([
      base_codec::json_obj([("id", base_codec::json_str("c-55")), ("session", base_codec::json_str("c-55")), ("thread", base_codec::json_int(55)), ("title", base_codec::json_str("T55")), ("lastActiveAt", base_codec::json_int64(2000.to_int64()))]),
      base_codec::json_obj([("id", base_codec::json_str("c-56")), ("session", base_codec::json_str("c-56")), ("thread", base_codec::json_int(56)), ("title", base_codec::json_str("T56")), ("lastActiveAt", base_codec::json_int64(1000.to_int64()))]),
    ])),
  ]))
  let _ = core.handle_wire("{\\"id\\":1,\\"subscribe\\":{\\"topic\\":\\"chats\\",\\"scope\\":\\"ws-sql-e2e\\"},\\"keyed\\":true}")
  let memo_before = core.rows_memo.cached_count()

  core.start()
  let _ = rt.run_ready()
  match sse_push { Some(cb) => cb(": hi\\n\\n".to_bytes()); None => () }
  let _ = rt.run_ready()

  // Push malicious G_evil via SSE event: lock -> must emit LockRejected and preserve root_g
  let evil_sse = "id: l-evil\\nevent: lock\\ndata: " + base_codec::json_stringify(base_codec::json_obj([
    ("head", base_codec::json_obj([("seq", base_codec::json_int(0)), ("hash", base_codec::json_str(root_evil)), ("genesis", base_codec::json_str(root_evil))])),
    ("entries", base_codec::json_arr([sync::form_to_codec(e0_evil)])),
  ])) + "\\n\\n"
  match sse_push { Some(cb) => cb(evil_sse.to_bytes()); None => () }
  let _ = rt.run_ready()

  let evs = core.drain_frame()
  let mut saw_lock_rejected = false
  for i in 0..<evs.length() {
    match evs[i] {
      sync::CoreEvent::LockRejected(ws, _) => if ws == "ws-sql-e2e" { saw_lock_rejected = true }
      _ => ()
    }
  }

  // Push chat-mark SSE -> scoped GET /chats?marks=1&own=1 without wiping RowsMemo
  match sse_push { Some(cb) => cb("id: m-1\\nevent: chat-mark\\ndata: {\\"session\\":\\"c-55\\",\\"thread\\":55,\\"read\\":9}\\n\\n".to_bytes()); None => () }
  let _ = rt.run_ready()
  let memo_after = core.rows_memo.cached_count()
  let pinned_before_clear = core.viewer_marks.pins.get("st1:c-55").is_some()
  let hidden_before_clear = core.viewer_marks.hidden.get("st1:56").is_some()
  let muted_before_clear = core.viewer_marks.muted.get("st1:56").is_some()

  // Now simulate scoped unpin c-55 + unhide/unmute thread 56 via GET /chats?marks=1&own=1&session=c-55&thread=56
  marks_resp = "{\\"reads\\":{},\\"pins\\":{},\\"kept\\":[],\\"hidden\\":[],\\"muted\\":[],\\"dismissed\\":[],\\"selves\\":[\\"U99\\"]}"
  let _ = rt.fork(fn(k : (effect::Exit[Unit]) -> Unit) -> Unit {
    core.sync.fetch_marks_k(
      effect::priority_shown(),
      fn(_ex : effect::Exit[Array[String]]) -> Unit { k(effect::Exit::Succeeded(())) },
      sessions=["c-55"],
      threads=[56],
    )
  })
  let _ = rt.run_ready()
  let pinned_after_clear = core.viewer_marks.pins.get("st1:c-55").is_some()
  let hidden_after_clear = core.viewer_marks.hidden.get("st1:56").is_some()
  let muted_after_clear = core.viewer_marks.muted.get("st1:56").is_some()

  // P0 guardrails: Cloud op & read-only GET op must NOT hit tr1 or write changing!
  let reqs_before_guards = reqs_st1.length()
  let cloud_err = match core.handle_wire("{\\"id\\":901,\\"call\\":\\"workspace.create\\",\\"params\\":{\\"account\\":\\"acc-1\\",\\"name\\":\\"X\\"}}") {
    Some((txt, _)) => txt
    None => ""
  }
  let peek_err = match core.handle_wire("{\\"id\\":902,\\"call\\":\\"file.peek\\",\\"params\\":{\\"key\\":\\"c-55\\",\\"path\\":\\"a.ts\\"}}") {
    Some((txt, _)) => txt
    None => ""
  }
  let mem_err = match core.handle_wire("{\\"id\\":903,\\"call\\":\\"memory.get\\",\\"params\\":{}}") {
    Some((txt, _)) => txt
    None => ""
  }
  let _ = rt.run_ready()
  let guard_leaked_req = reqs_st1.length() != reqs_before_guards

  // Multi-station send to unattached st2 -> attach_station_transport auto-flushes!
  let _ = core.local_outbox.send_message(rt, 77, "ck-multi-1", "alice", "multi msg", 3000.to_int64(), station=Some("st2"))
  let _ = rt.run_ready()
  let backlog_before_attach = core.local_outbox.has_unreached_for_station("st2")
  core.attach_station_transport("st2", tr2)
  let _ = rt.run_ready()
  let backlog_after_attach = core.local_outbox.has_unreached_for_station("st2")

  core.stop()
  let _ = rt.run_ready()

  let pinned = match core.pinned_lock_root() { Some(r) => r; None => "" }
  let reqs1_j : Array[base_codec::Json] = []
  for i in 0..<reqs_st1.length() { reqs1_j.push(base_codec::json_str(reqs_st1[i])) }
  let reqs2_j : Array[base_codec::Json] = []
  for i in 0..<reqs_st2.length() { reqs2_j.push(base_codec::json_str(reqs_st2[i])) }

  base_codec::json_obj([
    ("rootG", base_codec::json_str(root_g)),
    ("pinned", base_codec::json_str(pinned)),
    ("sawLockRejected", base_codec::json_bool(saw_lock_rejected)),
    ("memoBefore", base_codec::json_int(memo_before)),
    ("memoAfter", base_codec::json_int(memo_after)),
    ("pinnedBeforeClear", base_codec::json_bool(pinned_before_clear)),
    ("hiddenBeforeClear", base_codec::json_bool(hidden_before_clear)),
    ("mutedBeforeClear", base_codec::json_bool(muted_before_clear)),
    ("pinnedAfterClear", base_codec::json_bool(pinned_after_clear)),
    ("hiddenAfterClear", base_codec::json_bool(hidden_after_clear)),
    ("mutedAfterClear", base_codec::json_bool(muted_after_clear)),
    ("cloudErr", base_codec::json_str(cloud_err)),
    ("peekErr", base_codec::json_str(peek_err)),
    ("memErr", base_codec::json_str(mem_err)),
    ("guardLeakedReq", base_codec::json_bool(guard_leaked_req)),
    ("backlogBeforeAttach", base_codec::json_bool(backlog_before_attach)),
    ("backlogAfterAttach", base_codec::json_bool(backlog_after_attach)),
    ("reqsSt1", base_codec::json_arr(reqs1_j)),
    ("reqsSt2", base_codec::json_arr(reqs2_j)),
  ])
}

fn main(world : World) -> Unit {
  while true {
    match io_read_line(world) {
      None => break
      Some(line) => {
        if line.length() == 0 { continue }
        match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Err(e) => io_println(world, base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e))])))
          base_codec::JsonParseResult::Ok(req) => {
            let op = j_str(req, "op")
            let args = match base_codec::json_get(req, "args") { Some(v) => v; None => base_codec::json_obj([]) }
            if op == "ops_request" {
              let name = j_str(args, "name")
              let params = match base_codec::json_get(args, "params") { Some(v) => v; None => base_codec::json_obj([]) }
              let res = match sync::ops_request(name, params) {
                sync::OpResult::Ok(r) => base_codec::json_obj([("status", base_codec::json_str("ok")), ("request", r.to_json())])
                sync::OpResult::Unknown => base_codec::json_obj([("status", base_codec::json_str("unknown"))])
                sync::OpResult::Invalid(m) => base_codec::json_obj([("status", base_codec::json_str("invalid")), ("message", base_codec::json_str(m))])
              }
              io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", res)])))
            } else if op == "mesh_handshake" {
              io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", run_mesh_handshake_check())])))
            } else if op == "sqlite_e2e" {
              io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", run_sqlite_lock_marks_multi_e2e(world))])))
            } else {
              io_println(world, base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str("unknown op: " + op))])))
            }
          }
        }
      }
    }
  }
}
`;

class DriverClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.queue = [];
    this.stderr = "";
    this.activeSql = null;
    this.proc.stderr.on("data", (d) => {
      this.stderr += d.toString("utf8");
    });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        let msg;
        try {
          msg = JSON.parse(line);
        } catch (e) {
          const waiter = this.queue.shift();
          if (waiter) waiter.reject(new Error(`Bad JSON from driver: ${line}\n${e}`));
          continue;
        }
        if ("sqlReq" in msg) {
          this.#handleSqlReq(msg.sqlReq);
          continue;
        }
        const waiter = this.queue.shift();
        if (waiter) waiter.resolve(msg);
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`driver exited ${code}: ${this.stderr}`));
      }
    });
  }

  #handleSqlReq({ op, args }) {
    const reply = (obj) => {
      this.proc.stdin.write(`${JSON.stringify(obj)}\n`);
    };
    try {
      if (op === "sql.open") { reply({ ok: { id: 1 } }); return; }
      if (op === "sql.close") { reply({ ok: null }); return; }
      const sql = args?.sql ?? "";
      const params = Array.isArray(args?.params) ? args.params : [];
      if (op === "sql.exec") { this.activeSql.exec(sql); reply({ ok: null }); return; }
      if (op === "sql.run") { reply({ ok: this.activeSql.run(sql, params) }); return; }
      if (op === "sql.all") { reply({ ok: this.activeSql.all(sql, params) }); return; }
      reply({ err: `unsupported sql op: ${op}` });
    } catch (e) {
      reply({ err: String(e?.message ?? e) });
    }
  }

  call(op, args = {}, { sql = null } = {}) {
    this.activeSql = sql;
    return new Promise((resolve, reject) => {
      this.queue.push({
        resolve: (resp) => {
          this.activeSql = null;
          if ("err" in resp) reject(new Error(resp.err));
          else resolve(resp.ok);
        },
        reject: (err) => {
          this.activeSql = null;
          reject(err);
        },
      });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    });
  }

  close() {
    this.proc.stdin.end();
    this.proc.kill();
  }
}

let tmpDir = null;
let rpc = null;

before(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-w27d-parity-"));
  const srcDir = path.join(tmpDir, "src");
  fs.mkdirSync(srcDir, { recursive: true });
  const baseDir = path.join(repoRoot, "pion/base/packages");
  const rulesDir = path.join(repoRoot, "pion/rules/packages");
  const ccPkgs = path.join(clientCoreRoot, "packages");
  const wsToml = `[package]
name = "w27d_driver"
version = "0.1.0"
edition = "2026"

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
effect = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "effect-v0.1.0", subdir = "packages/effect" }
crypto = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "crypto-v0.4.1", subdir = "packages/crypto" }
flate = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "flate-v0.1.0", subdir = "packages/flate" }
url = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "url-v0.1.0", subdir = "packages/url" }
time = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "time-v0.1.0", subdir = "packages/time" }
http1 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "http1-v0.1.0", subdir = "packages/http1" }
json5 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "json5-v0.1.0", subdir = "packages/json5" }
markdown = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "markdown-v0.3.0", subdir = "packages/markdown" }
regex = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "regex-v0.1.0", subdir = "packages/regex" }
base_codec = { path = "${baseDir}/base_codec" }
wire = { path = "${baseDir}/wire" }
shell = { path = "${baseDir}/shell" }
sql = { path = "${baseDir}/sql" }
mesh = { path = "${baseDir}/mesh" }
form = { path = "${rulesDir}/form" }
fork = { path = "${rulesDir}/fork" }
history = { path = "${rulesDir}/history" }
role = { path = "${rulesDir}/role" }
lock = { path = "${rulesDir}/lock" }
vault = { path = "${rulesDir}/vault" }
outbox = { path = "${ccPkgs}/outbox" }
store = { path = "${ccPkgs}/store" }
protocol = { path = "${ccPkgs}/protocol" }
core_abi = { path = "${ccPkgs}/core_abi" }
views = { path = "${ccPkgs}/views" }
sync = { path = "${ccPkgs}/sync" }

[dependencies]
base_codec = { workspace = true }
crypto = { workspace = true }
effect = { workspace = true }
form = { workspace = true }
lock = { workspace = true }
mesh = { workspace = true }
outbox = { workspace = true }
shell = { workspace = true }
sql = { workspace = true }
store = { workspace = true }
sync = { workspace = true }
`;
  fs.writeFileSync(path.join(tmpDir, "pion.toml"), wsToml, "utf8");
  fs.copyFileSync(path.join(clientCoreRoot, "pion.lock"), path.join(tmpDir, "pion.lock"));
  fs.writeFileSync(path.join(srcDir, "main.pion"), DRIVER_MAIN_PION, "utf8");
  const binPath = path.join(tmpDir, "w27d_driver");
  execFileSync(pioncBin, ["build", "-o", binPath, tmpDir], { cwd: repoRoot, stdio: "inherit" });
  rpc = new DriverClient(binPath);
});

after(() => {
  if (rpc) rpc.close();
  if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
});

// ── Test 1: 1:1 differential parity of ALL expanded ops against `client/core-ts/src/ops.ts` ──

const OP_VECTORS = [
  // Station admin / config / copies / move / decisions / jobs / memory / process / permissions
  ["tools.access", { station: "ws/st1" }],
  ["tools.setAccess", { station: "ws/st1", access: "read" }],
  ["agentEnv.set", { station: "ws/st1", text: "FOO=1\nBAR=2" }],
  ["search.setPersonal", { station: "ws/st1", personal: true }],
  ["network.setCongestion", { station: "ws/st1", congestion: "bbr" }],
  ["copies.setSettings", { station: "ws/st1", mode: "selected", stations: ["st2"], acceptOthers: true }],
  ["copies.testS3", { station: "ws/st1", endpoint: "https://s3.example", bucket: "bk", forcePathStyle: true }],
  ["copies.restore", { station: "ws/st1", origin: "st0", gen: "g1", fromStation: "st2" }],
  ["copies.restore", { station: "ws/st1", origin: "st0", gen: "g1", fromS3: "s3-id" }],
  ["copies.history", { station: "ws/st1" }],
  ["copies.history", { station: "ws/st1", limit: 25 }],
  ["copies.history", { station: "ws/st1", limit: 999 }],
  ["copies.retire", { station: "ws/st1", to: "st2" }],
  ["copies.retireCancel", { station: "ws/st1" }],
  ["copies.retireAgain", { station: "ws/st1" }],
  ["copies.retirePreview", { station: "ws/st1" }],
  ["move.start", { station: "ws/st1", to: "st2", module: "chats", item: "c-1", withNeeds: true }],
  ["move.back", { station: "ws/st1", from: "st2", all: true }],
  ["move.stop", { station: "ws/st1" }],
  ["station.restart", { station: "ws/st1" }],
  ["station.resumeInterrupted", { station: "ws/st1", keys: ["s1", "s2"] }],
  ["station.dismissInterrupted", { station: "ws/st1" }],
  ["context.setAfresh", { station: "ws/st1", afreshWhenCold: true, afreshAbove: 2 }],
  ["diagnostics.setLogs", { station: "ws/st1", logs: false }],
  ["elevation.set", { station: "ws/st1", on: true }],
  ["screenService.set", { station: "ws/st1", on: true }],
  ["automaticDecisions.save", { station: "ws/st1", input: { enabled: true } }],
  ["automaticDecisions.review", { station: "ws/st1" }],
  ["automaticDecisions.policy", { station: "ws/st1", input: { rules: ["a"] } }],
  ["automaticDecisions.refresh", { station: "ws/st1" }],
  ["archiving.save", { station: "ws/st1", days: 14, slackDays: 7, reviewed: true }],
  ["autoChats.save", { station: "ws/st1", enabled: false }],
  ["memory.get", { station: "ws/st1" }],
  ["process.end", { station: "ws/st1", pid: 4321, session: "s-1" }],
  ["permissions.request", { station: "ws/st1", grant: "screen" }],

  // Presets, files, links, widgets, machineSessions
  ["preset.add", { station: "ws/st1", name: "Dev", dirs: ["/repo"], instructions: "be brief", autoStation: true }],
  ["preset.put", { station: "ws/st1", id: "p/1", name: "Dev2", dirs: ["/repo"] }],
  ["preset.delete", { station: "ws/st1", id: "p/1" }],
  ["preset.clone", { station: "ws/st1", url: "https://github.com/AFK-surf/monoid" }],
  ["preset.cloneDrop", { station: "ws/st1", id: "cl-1" }],
  ["file.peek", { station: "ws/st1", key: "s/1", path: "src/a b.ts", line: 42 }],
  ["file.peek", { station: "ws/st1", key: "s-1", path: "README.md" }],
  ["link.preview", { station: "ws/st1", url: "https://still.fail/docs?x=1&y=2" }],
  ["widget.state", { station: "ws/st1", key: "s-1", path: "w/1.mbui" }],
  ["widget.setState", { station: "ws/st1", key: "s-1", path: "w/1.mbui", state: { open: true } }],
  ["machineSessions.list", { station: "ws/st1" }],
  ["machineSessions.read", { station: "ws/st1", runtime: "claude", id: "ms/1", limit: 50 }],
  ["machineSessions.read", { station: "ws/st1", runtime: "codex", id: "ms-2" }],
  ["machineSessions.continue", { station: "ws/st1", runtime: "claude", id: "ms-1" }],

  // Profiles, skills, logins
  ["profile.add", { station: "ws/st1", runtime: "claude", access: { kind: "oauth" } }],
  ["profile.useMachineLogin", { station: "ws/st1", runtime: "codex" }],
  ["profile.put", { station: "ws/st1", id: "pr/1", input: { name: "Work", models: ["z-model", "a-model", "z-model"] } }],
  ["profile.addModel", { station: "ws/st1", id: "pr-1", model: "gemini-4-neon" }],
  ["profile.delete", { station: "ws/st1", id: "pr-1" }],
  ["profile.share", { station: "ws/st1", id: "pr-1", on: true, allow: ["st2"], among: ["st1", "st2"] }],
  ["profile.share", { station: "ws/st1", id: "pr-1", on: true, allowAuto: true }],
  ["profile.move", { station: "ws/st1", id: "pr-1", to: "st2" }],
  ["skill.share", { station: "ws/st1", name: "my skill", on: true }],
  ["profile.resetQuota", { station: "ws/st1", id: "pr-1", reset: "daily" }],
  ["profile.quota", { station: "ws/st1", id: "pr-1" }],
  ["profile.check", { station: "ws/st1", id: "pr-1" }],
  ["profile.fusion", { station: "ws/st1", id: "pr-1" }],
  ["profile.login", { station: "ws/st1", id: "pr-1" }],
  ["profile.cancelLogin", { station: "ws/st1", id: "pr-1" }],
  ["profile.loginCode", { station: "ws/st1", id: "pr-1", code: "123456" }],
  ["profile.loginBrowser", { station: "ws/st1", id: "pr-1" }],
  ["login.new", { station: "ws/st1", runtime: "agy", access: "oauth", service: "google" }],
  ["login.code", { station: "ws/st1", id: "lg-1", code: "XYZ" }],
  ["login.drop", { station: "ws/st1", id: "lg-1" }],
  ["login.browser", { station: "ws/st1", id: "lg-1" }],

  // Connects, Feishu, Comma, Group, Slack
  ["connect.create", { station: "ws/st1", id: "cn-1", input: { kind: "slack" } }],
  ["connect.put", { station: "ws/st1", id: "cn-1", input: { name: "Main" } }],
  ["connect.delete", { station: "ws/st1", id: "cn-1" }],
  ["connect.reconnect", { station: "ws/st1", id: "cn-1" }],
  ["connect.move", { station: "ws/st1", id: "cn-1", to: "st2" }],
  ["connect.bindSession", { station: "ws/st1", connect: "cn-1", session: "s-1", title: "Bound" }],
  ["feishu.register", { station: "ws/st1", domain: "feishu", name: "Bot", requireMention: true }],
  ["feishu.cancelRegistration", { station: "ws/st1", id: "reg-1" }],
  ["feishu.verify", { station: "ws/st1", appId: "cli_1", appSecret: "sec" }],
  ["feishu.createConnect", { station: "ws/st1", feishu: { appId: "cli_1" }, mode: "group" }],
  ["feishu.putSecret", { station: "ws/st1", id: "cn-f1", appSecret: "new-sec" }],
  ["comma.createConnect", { station: "ws/st1", line: "comma://abc" }],
  ["group.createConnect", { station: "ws/st1", group: { id: "g1" }, requireMention: false }],
  ["slack.verify", { station: "ws/st1", appToken: "xapp-1", botToken: "xoxb-1" }],
  ["slack.people", { station: "ws/st1" }],
  ["slack.createAppUrl", { station: "ws/st1", name: "My App" }],
  ["slack.identity", { station: "ws/st1", user: "U123", bound: true }],
  ["slack.identity", { station: "ws/st1", user: "U123", bound: false }],

  // Software, Drive, MachineLogin, Screen, Terminal, Signin
  ["software.update", { station: "ws/st1", id: "station", repair: false }],
  ["software.updateAll", { station: "ws/st1" }],
  ["software.check", { station: "ws/st1" }],
  ["software.channel", { station: "ws/st1", channel: "beta" }],
  ["software.auto", { station: "ws/st1", on: true }],
  ["software.wait", { station: "ws/st1", wait: ["pr:8369"] }],
  ["software.wait", { station: "ws/st1", clear: true }],
  ["drive.setRoots", { station: "ws/st1", roots: ["/work", "/docs"] }],
  ["drive.folders", { station: "ws/st1", path: "a/b c" }],
  ["drive.mkdir", { station: "ws/st1", root: "r1", path: "dir/sub/new" }],
  ["drive.rename", { station: "ws/st1", root: "r1", from: "a/old.txt", to: "b/new.txt" }],
  ["drive.remove", { station: "ws/st1", root: "r1", path: "a/x.txt", permanent: true }],
  ["drive.zip", { station: "ws/st1", root: "r1", path: "dir" }],
  ["drive.stage", { station: "ws/st1", root: "r1", path: "dir/f.png", zip: false }],
  ["machineLogin.cancel", { station: "ws/st1", id: "ml-1" }],
  ["machineLogin.answer", { station: "ws/st1", id: "ml-1", text: "code-9" }],
  ["machineLogin.again", { station: "ws/st1", id: "ml-1" }],
  ["machineLogin.browser", { station: "ws/st1", id: "ml-1" }],
  ["screen.openBrowser", { station: "ws/st1", url: "https://example.com", id: "u_0123456789ab" }],
  ["screen.openBrowser", { station: "ws/st1", url: "https://example.com", id: "invalid" }],
  ["screen.close", { station: "ws/st1", screen: "browser:1" }],
  ["terminal.end", { station: "ws/st1", terminal: "term-1" }],
  ["screen.sleep", { station: "ws/st1", screen: "disp:0" }],
  ["screen.reload", { station: "ws/st1", screen: "browser:1" }],
  ["screen.back", { station: "ws/st1", screen: "browser:1" }],
  ["screen.forward", { station: "ws/st1", screen: "browser:1" }],
  ["screen.endView", { station: "ws/st1", screen: "disp:0", view: "v-1" }],
  ["screen.watchOnly", { station: "ws/st1", screen: "disp:0", view: "v-1" }],
  ["screen.endViews", { station: "ws/st1", screen: "disp:0" }],
  ["screen.logs", { station: "ws/st1", screen: "sim:1", after: 100 }],
  ["screen.apps", { station: "ws/st1", screen: "sim:1" }],
  ["screen.relaunch", { station: "ws/st1", screen: "sim:1", app: "com.example.app" }],
  ["screen.settings", { station: "ws/st1", screen: "sim:1" }],
  ["screen.setSetting", { station: "ws/st1", screen: "sim:1", name: "appearance", value: "dark" }],
  ["screen.screenshot", { station: "ws/st1", screen: "sim:1" }],
  ["screen.biometrics", { station: "ws/st1", screen: "sim:1", what: "match" }],
  ["screen.uninstall", { station: "ws/st1", screen: "sim:1", app: "com.example.app" }],
  ["screen.recordStart", { station: "ws/st1", screen: "sim:1", panel: "inner" }],
  ["screen.recordStop", { station: "ws/st1", screen: "sim:1" }],
  ["screen.install", { station: "ws/st1", screen: "sim:1", path: "/tmp/app.apk" }],
  ["screen.openUrl", { station: "ws/st1", screen: "sim:1", url: "https://still.fail" }],
  ["screen.location", { station: "ws/st1", screen: "sim:1", at: "35.68,139.76" }],
  ["screen.statusBar", { station: "ws/st1", screen: "sim:1", tidy: true }],
  ["screen.push", { station: "ws/st1", screen: "sim:1", app: "com.example", text: "hi" }],
  ["signin.self", { station: "ws/st1", id: "si-1", done: true }],
  ["signin.deny", { station: "ws/st1", id: "si-1" }],

  // Cloud workspace / invitation / loginSession / account
  ["workspace.create", { account: "acc-1", name: "Team", invite_code: "INV" }],
  ["workspace.rename", { account: "acc-1", workspace: "ws/1", name: "Renamed", emoji: "🚀" }],
  ["workspace.setRelays", { account: "acc-1", workspace: "ws-1", relays: ["https://r1.example"] }],
  ["workspace.setWay", { account: "acc-1", workspace: "ws-1", way: "lan", on: false }],
  ["workspace.delete", { account: "acc-1", workspace: "ws-1" }],
  ["workspace.invite", { account: "acc-1", workspace: "ws-1", role: "member", email: "a@b.com" }],
  ["workspace.removeAdded", { account: "acc-1", workspace: "ws-1", email: "a+1@b.com" }],
  ["workspace.revokeInvitation", { account: "acc-1", workspace: "ws-1", invitation: "inv-1" }],
  ["workspace.setRole", { account: "acc-1", workspace: "ws-1", member: "u-1", role: "admin" }],
  ["workspace.removeMember", { account: "acc-1", workspace: "ws-1", member: "u-1" }],
  ["workspace.enroll", { account: "acc-1", workspace: "ws-1", name: "Mac" }],
  ["workspace.createProvisionKey", { account: "acc-1", workspace: "ws-1", name: "CI", days: 30 }],
  ["workspace.renameStation", { account: "acc-1", workspace: "ws-1", station: "st-1", name: "Tokyo" }],
  ["workspace.removeStation", { account: "acc-1", workspace: "ws-1", station: "st-1" }],
  ["workspace.feedbackReply", { account: "acc-1", workspace: "ws-1", id: "FB-12", text: "Thanks!" }],
  ["invitation.preview", { account: "acc-1", token: "tok-1" }],
  ["invitation.accept", { account: "acc-1", id: "inv-1" }],
  ["invitation.accept", { account: "acc-1", token: "tok-1" }],
  ["invitation.decline", { account: "acc-1", id: "inv-1" }],
  ["loginSession.revoke", { account: "acc-1", id: "ls-1" }],
  ["account.setPicture", { account: "acc-1", picture: "data:image/png;base64,AA==" }],
  ["account.removePicture", { account: "acc-1" }],
];

test("W27d Ops Parity: 100% 1:1 diff against real client/core-ts/src/ops.ts across all expanded ops (0 diffs)", async () => {
  let diffs = 0;
  for (const [name, params] of OP_VECTORS) {
    const tsReq = tsOpsRequest(name, params);
    assert.ok(tsReq !== null, `TS ops.ts must recognize ${name}`);
    const pionResp = await rpc.call("ops_request", { name, params });
    assert.equal(pionResp.status, "ok", `Pion ops_request failed on ${name}: ${JSON.stringify(pionResp)}`);
    try {
      assert.deepStrictEqual(pionResp.request, tsReq);
    } catch (e) {
      diffs++;
      throw new Error(`Op diff on ${name} (${JSON.stringify(params)}):\n${e.message}`);
    }
  }
  assert.equal(diffs, 0, "expected 0 diffs across all expanded ops");
  console.log(`[W27d Ops Parity] Verified ${OP_VECTORS.length} op vectors against real ops.ts with 0 diffs.`);
});

test("W27d P0-6 Mesh Handshake: real pion/base/packages/mesh ALPN, protocol=2, Ed25519 claimBy cross-verified by @noble/curves, lock_unconfirmed, HTTP/SSE/cancel/exchange", async () => {
  const res = await rpc.call("mesh_handshake", {});
  assert.equal(res.alpn, "stillfail/admin/1", "ALPN must be stillfail/admin/1");
  assert.equal(res.hello.credential, "cred-parity-v1", "control hello carries Cloud member credential");
  assert.equal(res.hello.protocol, 2, "control hello carries protocol: 2");
  assert.equal(res.hello.lock.kind, "app");
  assert.equal(res.hello.lock.label, "ParityHost");
  assert.equal(res.pionProofOk, true, "Pion native_lock_crypto().endpoint_proof must accept claimBy");

  // Cross-verify the exact Ed25519 signature in Node using @noble/curves/ed25519 + client/core-ts/src/lock.ts endpointBytes!
  const msg = endpointBytes("ws-parity-mesh", res.endpointId);
  const nodeProofOk = ed25519.verify(unhex(res.hello.lock.proof), msg, unhex(res.hello.lock.device));
  assert.equal(nodeProofOk, true, "Node @noble/curves/ed25519 must verify Pion Mesh::sign claimBy signature");

  assert.equal(res.unconfirmedBefore, true, "lock_unconfirmed: true surfaced on initial admission");
  assert.equal(res.unconfirmedAfter, false, "Link::exchange_k updated lock_unconfirmed to false");
  assert.ok(res.refreshLine.includes("cred-parity-v2"), "exchange_k wrote refreshed credential");
  assert.equal(res.httpStatus, 200);
  assert.equal(res.httpBody, '{"pong":true}');
  assert.ok(res.sseChunks >= 1, "SSE chunk delivered over real mesh::Link");
  assert.equal(res.sawStreamReset, true, "interrupting SSE stream called reply.cancel() -> istream.reset");
  console.log("[W27d P0-6 Mesh] Verified ALPN, protocol=2, cross-language Ed25519 claimBy, lock_unconfirmed, HTTP/SSE/cancel/exchange.");
});

test("W27d Real node:sqlite E2E: GET /lock + SSE event: lock + GET /chats?marks=1&own=1 + multi-station attach_station_transport", async () => {
  const nodeSql = makeNodeSql(":memory:");
  try {
    const time = new TestTime();
    const acct = new AccountDb("sub-1", "w27d-init", nodeSql, new Runner(time.clock), makeDummyDerive());
    ensureSharedSidecar(nodeSql);
    void acct;

    const res = await rpc.call("sqlite_e2e", {}, { sql: nodeSql });
    assert.equal(res.error, undefined, `sqlite_e2e error: ${res.error}`);
    assert.equal(res.pinned, res.rootG, "GET /lock pinned rootG");
    assert.equal(res.sawLockRejected, true, "malicious G_evil via SSE event: lock rejected");
    assert.equal(res.memoBefore, 2, "RowsMemo warmed with 2 chats");
    assert.equal(res.memoAfter, 2, "marks_dirty preserved RowsMemo without wiping");
    assert.equal(res.backlogBeforeAttach, true, "unattached st2 queued as unreached");
    assert.equal(res.backlogAfterAttach, false, "attach_station_transport auto-flushed st2 backlog");
    assert.ok(res.reqsSt1.includes("GET /lock"), "st1 received GET /lock");
    assert.ok(res.reqsSt1.some((r) => r.startsWith("GET /chats?marks=1&own=1&session=c-55&thread=55")), "st1 received scoped GET /chats?marks=1&own=1");
    assert.deepStrictEqual(res.reqsSt2, ["POST /threads/77/messages"], "st2 received flushed message");

    // Verify real SQLite tables directly!
    const prefRows = nodeSql.all("SELECT json FROM workspace_pref WHERE workspace = ? AND key = ?", ["ws-sql-e2e", "lock"]);
    assert.equal(prefRows.length, 1, "workspace_pref(ws, 'lock') persisted in real SQLite");
    const persistedLock = JSON.parse(prefRows[0][0]);
    assert.equal(persistedLock.head.genesis, res.rootG, "persisted lock head.genesis equals pinned rootG");

    const markRows = nodeSql.all("SELECT kind, k, v FROM shared_mark WHERE station = ? ORDER BY kind, k", ["st1"]);
    const markMap = Object.fromEntries(markRows.map(([kind, k, v]) => [`${kind}:${k}`, v]));
    // Unscoped marks on thread 55 remain intact:
    assert.equal(markMap["read:55"], "9");
    assert.equal(markMap["kept:55"], "1");
    assert.equal(markMap["dismissed:55:2"], "1");
    // Scoped unpin c-55 + unhide/unmute thread 56 cleared cleanly in SQLite `shared_mark`, `chat.json`, and `viewer_marks`!
    assert.equal(res.pinnedBeforeClear, true, "c-55 was pinned before scoped clear");
    assert.equal(res.hiddenBeforeClear, true, "thread 56 was hidden before scoped clear");
    assert.equal(res.mutedBeforeClear, true, "thread 56 was muted before scoped clear");
    assert.equal(res.pinnedAfterClear, false, "viewer_marks.pins cleared for c-55");
    assert.equal(res.hiddenAfterClear, false, "viewer_marks.hidden cleared for thread 56");
    assert.equal(res.mutedAfterClear, false, "viewer_marks.muted cleared for thread 56");
    assert.equal(markMap["pin:c-55"], undefined, "shared_mark pin:c-55 deleted");
    assert.equal(markMap["hidden:56"], undefined, "shared_mark hidden:56 deleted");
    assert.equal(markMap["muted:56"], undefined, "shared_mark muted:56 deleted");
    const c56Rows = nodeSql.all("SELECT json FROM chat WHERE station = ? AND id = ?", ["st1", "c-56"]);
    assert.equal(c56Rows.length, 1);
    const c56Json = JSON.parse(c56Rows[0][0]);
    assert.equal(c56Json.hidden, false, "chat.json hidden reset to false on scoped clear");
    assert.equal(c56Json.muted, false, "chat.json muted reset to false on scoped clear");

    // P0 guardrails verified in real SQLite: Cloud ops & read-only GET ops rejected with 0 changing rows and 0 station requests!
    assert.ok(res.cloudErr.includes("cloud_transport_required"), `workspace.create error: ${res.cloudErr}`);
    assert.ok(res.peekErr.includes("read_op_not_mutation"), `file.peek error: ${res.peekErr}`);
    assert.ok(res.memErr.includes("read_op_not_mutation"), `memory.get error: ${res.memErr}`);
    assert.equal(res.guardLeakedReq, false, "0 requests leaked to tr1 for Cloud/GET ops");
    const changingRows = nodeSql.all("SELECT count(*) FROM changing");
    assert.equal(changingRows[0][0], 0, "0 rows written to SQLite changing table for Cloud/GET ops");

    console.log("[W27d SQLite E2E] Verified real SQLite workspace_pref(lock), shared_mark + scoped clear, chat.json reset, Cloud/GET guards, RowsMemo preservation, and multi-station auto-flush.");
  } finally {
    nodeSql.close();
  }
});
