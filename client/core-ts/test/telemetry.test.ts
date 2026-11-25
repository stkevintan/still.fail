// Deterministic tests for D54 + D55 telemetry:
// - `client.error` new native/hang sources, 60s dedup, sanitization, and `client.reports` opt-out
// - `client.metric` strict allowlist, 20%/slow/cut/failed `bar.switch` sampling, `ui.hang_summary` thresholds
// - `chat.send.e2e` root span: ack -> live, POST failure, superseded by next send, 30s timeout, reporting opt-out
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { Core } from "../src/core.ts";
import { parseCall } from "../src/core/calls.ts";
import { SEND_TRACE_TIMEOUT_MS, SendTrace } from "../src/station/send-trace.ts";
import { EXPORT_MS, Tracer } from "../src/trace.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost } from "../src/testing.ts";
import { parseJson } from "../src/util.ts";
import { base, started } from "./station-fixture.ts";

type Attr = { key: string; value: { stringValue?: string; intValue?: string; doubleValue?: number; boolValue?: boolean } };
type Exported = { name: string; status: { code: number }; attributes: Attr[] };

function attrsOf(span: Exported): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  for (const a of span.attributes) {
    if (a.value.stringValue !== undefined) out[a.key] = a.value.stringValue;
    else if (a.value.boolValue !== undefined) out[a.key] = a.value.boolValue;
    else if (a.value.intValue !== undefined) out[a.key] = Number(a.value.intValue);
    else if (a.value.doubleValue !== undefined) out[a.key] = a.value.doubleValue;
  }
  return out;
}

function exportedSpans(bodies: unknown[]): Exported[] {
  return bodies.flatMap((b) =>
    (b as { resourceSpans: { scopeSpans: { spans: Exported[] }[] }[] }).resourceSpans.flatMap((r) =>
      r.scopeSpans.flatMap((x) => x.spans),
    ),
  );
}

test("client.error records new native/hang sources with 60s dedup, sanitization, and respects client.reports", async () => {
  const host = new FakeHost();
  const core = await Core.create(host, { clock: host.time.clock, sample: 1, usage: null, reports: true });
  const bodies: unknown[] = [];
  core.inner.tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  const ui = core.connect();
  try {
    core.receive(ui, { kind: "call", id: 1, call: "client.error", params: { source: "ui_hang", message: "page=Chat stall_ms=2400 passes=2 cause=frame\nsecret" } });
    core.receive(ui, { kind: "call", id: 2, call: "client.error", params: { source: "ui_hang", message: "page=Chat stall_ms=2400 passes=2 cause=frame\nsecret" } });
    core.receive(ui, { kind: "call", id: 3, call: "client.error", params: { source: "native_crash", message: "detected_on_launch" } });
    core.receive(ui, { kind: "call", id: 4, call: "client.error", params: { source: "watchdog_hang", message: "detected_on_launch" } });
    core.receive(ui, { kind: "call", id: 5, call: "client.error", params: { source: "memory_runaway", message: "detected_on_launch" } });
    core.receive(ui, { kind: "call", id: 6, call: "client.error", params: { source: "metric_hang", message: "detected_on_launch" } });
    await host.time.pass(EXPORT_MS + 50, 50);

    let errs = exportedSpans(bodies).filter((s) => s.name === "client.error");
    assert.equal(errs.length, 5, "duplicate ui_hang within 60s is deduplicated");
    assert.equal(attrsOf(errs[0]!)["stillfail.source"], "ui_hang");
    assert.equal(attrsOf(errs[0]!)["stillfail.message"], "page=Chat stall_ms=2400 passes=2 cause=frame secret");
    assert.deepEqual(
      errs.map((s) => attrsOf(s)["stillfail.source"]),
      ["ui_hang", "native_crash", "watchdog_hang", "memory_runaway", "metric_hang"],
    );

    // Turning reporting off suppresses further client.error spans.
    core.receive(ui, { kind: "call", id: 7, call: "client.reports", params: { on: false } });
    await host.time.pass(65_000, 1_000);
    core.receive(ui, { kind: "call", id: 8, call: "client.error", params: { source: "native_crash", message: "detected_on_launch" } });
    await host.time.pass(EXPORT_MS + 50, 50);
    errs = exportedSpans(bodies).filter((s) => s.name === "client.error");
    assert.equal(errs.length, 5, "no span emitted when reporting is off");
  } finally {
    await core.close();
  }
});

test("client.metric enforces strict allowlist, 20%/slow/cut/failed sampling for bar.switch, and thresholds for ui.hang_summary", async () => {
  // Reject unknown metric kind.
  assert.throws(() => parseCall("client.metric", { kind: "unknown", duration_ms: 10 }));

  const host = new FakeHost();
  const core = await Core.create(host, { clock: host.time.clock, sample: 1, usage: null, reports: true });
  const bodies: unknown[] = [];
  core.inner.tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  const ui = core.connect();
  try {
    // 5 fast normal switches: only #0 (n=0, 0%5===0) is sampled (20%).
    for (let i = 0; i < 5; i++) {
      core.receive(ui, {
        kind: "call",
        id: 10 + i,
        call: "client.metric",
        params: {
          kind: "bar_switch",
          duration_ms: 42,
          attrs: {
            from: "chats",
            to: "a".repeat(80), // truncated to 64
            first: true,
            composed_ms: 12,
            secret_text: "must-be-dropped",
            nested: { bad: true },
          },
        },
      });
    }
    // Slow (>=250ms), cut, and failed switches always emit regardless of counter.
    core.receive(ui, { kind: "call", id: 20, call: "client.metric", params: { kind: "bar_switch", duration_ms: 250, attrs: { to: "files" } } });
    core.receive(ui, { kind: "call", id: 21, call: "client.metric", params: { kind: "bar_switch", duration_ms: 20, attrs: { to: "usage", cut: true } } });
    core.receive(ui, { kind: "call", id: 22, call: "client.metric", params: { kind: "bar_switch", duration_ms: 20, attrs: { to: "stations", failed: true } } });

    // ui_hang_summary: below threshold (stalls=0, hangs=2) dropped; stalls>0 or hangs>=3 emitted.
    core.receive(ui, { kind: "call", id: 30, call: "client.metric", params: { kind: "ui_hang_summary", duration_ms: 10000, attrs: { shown_s: 10, hangs: 2, stalls: 0, max_ms: 40 } } });
    core.receive(ui, { kind: "call", id: 31, call: "client.metric", params: { kind: "ui_hang_summary", duration_ms: 20000, attrs: { shown_s: 20, hangs: 1, stalls: 1, max_ms: 120 } } });
    core.receive(ui, { kind: "call", id: 32, call: "client.metric", params: { kind: "ui_hang_summary", duration_ms: 30000, attrs: { shown_s: 30, hangs: 3, stalls: 0, max_ms: 80 } } });

    await host.time.pass(EXPORT_MS + 50, 50);

    const all = exportedSpans(bodies);
    const barSpans = all.filter((s) => s.name === "bar.switch");
    assert.equal(barSpans.length, 4, "1 sampled + slow + cut + failed");
    const firstAttrs = attrsOf(barSpans[0]!);
    assert.equal(firstAttrs["stillfail.from"], "chats");
    assert.equal((firstAttrs["stillfail.to"] as string).length, 64, "string attrs capped at 64 chars");
    assert.equal(firstAttrs["stillfail.secret_text"], undefined, "disallowed attr stripped");
    assert.equal(firstAttrs["stillfail.nested"], undefined, "non-primitive attr stripped");

    const hangSpans = all.filter((s) => s.name === "ui.hang_summary");
    assert.equal(hangSpans.length, 2, "only stalls>0 or hangs>=3 emitted");
    assert.equal(attrsOf(hangSpans[0]!)["stillfail.stalls"], 1);
    assert.equal(attrsOf(hangSpans[1]!)["stillfail.hangs"], 3);

    // Reporting off drops all metrics.
    core.receive(ui, { kind: "call", id: 40, call: "client.reports", params: { on: false } });
    core.receive(ui, { kind: "call", id: 41, call: "client.metric", params: { kind: "bar_switch", duration_ms: 999, attrs: { to: "chats", cut: true } } });
    await host.time.pass(EXPORT_MS + 50, 50);
    assert.equal(exportedSpans(bodies).filter((s) => s.name === "bar.switch").length, 4);
  } finally {
    await core.close();
  }
});

test("SendTrace covers ack->live, failed POST, superseded, 30s timeout, and reporting opt-out", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const tracer = new Tracer(host, runner, 1);
  const bodies: unknown[] = [];
  tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  let reporting = true;
  const st = new SendTrace(tracer, runner, () => host.monotonicMs(), () => reporting);

  try {
    // 1. Normal ack -> live
    const h1 = st.start("ws/st-1", { session: "sess-1", thread: 1 });
    assert.ok(h1);
    await host.time.pass(120, 20);
    h1.acked();
    await host.time.pass(380, 20);
    st.onLive("ws/st-1", "sess-1");

    // 2. POST failure -> error span with outcome=failed
    const h2 = st.start("ws/st-1", { session: "sess-2", thread: 2 });
    assert.ok(h2);
    await host.time.pass(50, 10);
    h2.failed();

    // 3. Superseded by a new send on same session (not marked error)
    const h3 = st.start("ws/st-1", { session: "sess-3", thread: 3 });
    assert.ok(h3);
    await host.time.pass(40, 10);
    h3.acked();
    const h3b = st.start("ws/st-1", { session: "sess-3", thread: 3 });
    assert.ok(h3b);
    await host.time.pass(60, 10);
    h3b.acked();
    await host.time.pass(100, 10);
    st.onLive("ws/st-1", "sess-3");

    // 4. Timeout after 30s -> outcome=timeout
    const h4 = st.start("ws/st-1", { session: "sess-4", thread: 4 });
    assert.ok(h4);
    await host.time.pass(30, 10);
    h4.acked();
    await host.time.pass(SEND_TRACE_TIMEOUT_MS + 100, 500);

    // 5. Reporting off -> returns null, no span
    reporting = false;
    assert.equal(st.start("ws/st-1", { session: "sess-5", thread: 5 }), null);

    await host.time.pass(EXPORT_MS + 100, 100);
    const spans = exportedSpans(bodies).filter((s) => s.name === "chat.send.e2e");
    assert.equal(spans.length, 5);

    const byOutcome = spans.map((s) => ({ status: s.status.code, a: attrsOf(s) }));
    // h1: live
    assert.equal(byOutcome[0]!.status, 1);
    assert.equal(byOutcome[0]!.a["stillfail.station"], "st-1");
    assert.equal(byOutcome[0]!.a["stillfail.outcome"], "live");
    assert.equal(byOutcome[0]!.a["stillfail.ack_ms"], 120);
    assert.equal(byOutcome[0]!.a["stillfail.first_live_ms"], 500);

    // h2: failed
    assert.equal(byOutcome[1]!.status, 2);
    assert.equal(byOutcome[1]!.a["stillfail.outcome"], "failed");

    // h3: superseded (non-error)
    assert.equal(byOutcome[2]!.status, 1);
    assert.equal(byOutcome[2]!.a["stillfail.outcome"], "superseded");

    // h3b: live
    assert.equal(byOutcome[3]!.status, 1);
    assert.equal(byOutcome[3]!.a["stillfail.outcome"], "live");
    assert.equal(byOutcome[3]!.a["stillfail.ack_ms"], 60);
    assert.equal(byOutcome[3]!.a["stillfail.first_live_ms"], 160);

    // h4: timeout
    assert.equal(byOutcome[4]!.status, 1);
    assert.equal(byOutcome[4]!.a["stillfail.outcome"], "timeout");
    assert.equal(byOutcome[4]!.a["stillfail.ack_ms"], 30);
  } finally {
    st.close();
    runner.shutdown();
  }
});

test("SendTrace bindStation re-indexes after MOVED and onEnd fires once on every termination", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const tracer = new Tracer(host, runner, 1);
  const bodies: unknown[] = [];
  tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  const st = new SendTrace(tracer, runner, () => host.monotonicMs(), () => true);

  try {
    let endedMoved = 0;
    const hMoved = st.start("ws/st-1", { session: "sess-m", thread: 10, onEnd: () => { endedMoved++; } });
    assert.ok(hMoved);
    await host.time.pass(40, 10);
    hMoved.bindStation("ws/st-2");
    hMoved.bindThread(20);
    hMoved.acked();
    // Old station live event must not resolve the moved trace.
    st.onLive("ws/st-1", "sess-m");
    assert.equal(endedMoved, 0);
    await host.time.pass(110, 10);
    // New station live event resolves it cleanly.
    st.onLive("ws/st-2", "sess-m");
    assert.equal(endedMoved, 1);

    // onEnd fires on failed, superseded, timeout, and close.
    let endedFailed = 0;
    let endedSuperseded = 0;
    let endedTimeout = 0;
    let endedClosed = 0;

    const hf = st.start("ws/st-1", { session: "sess-f", onEnd: () => { endedFailed++; } });
    hf!.failed();
    assert.equal(endedFailed, 1);

    st.start("ws/st-1", { session: "sess-s", onEnd: () => { endedSuperseded++; } });
    const hs2 = st.start("ws/st-1", { session: "sess-s", onEnd: () => { endedTimeout++; } });
    assert.ok(hs2);
    assert.equal(endedSuperseded, 1);
    await host.time.pass(SEND_TRACE_TIMEOUT_MS + 100, 500);
    assert.equal(endedTimeout, 1);

    st.start("ws/st-1", { session: "sess-c", onEnd: () => { endedClosed++; } });
    st.close();
    assert.equal(endedClosed, 1);

    await host.time.pass(EXPORT_MS + 100, 100);
    const spans = exportedSpans(bodies).filter((s) => s.name === "chat.send.e2e");
    const movedAttrs = attrsOf(spans[0]!);
    assert.equal(movedAttrs["stillfail.station"], "st-2");
    assert.equal(movedAttrs["stillfail.outcome"], "live");
    assert.equal(movedAttrs["stillfail.ack_ms"], 40);
    assert.equal(movedAttrs["stillfail.first_live_ms"], 150);
  } finally {
    st.close();
    runner.shutdown();
  }
});

test("chat.send integration emits chat.send.e2e when live event arrives on station stream", async () => {
  const s = await started({ ...base(), "POST /threads/7/messages": { n: 4 } }, 1, undefined, (f) => {
    f.gate.marks = true;
    f.gate.resumes = true;
  });
  const bodies: unknown[] = [];
  s.core.inner.tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  const ui = s.core.connect();
  try {
    await s.host.time.pass(1_000, 50);
    s.core.receive(ui, {
      kind: "call",
      id: 1,
      call: "chat.send",
      params: { station: "ws/st", thread: 7, text: "hello private message" },
    });
    await s.host.time.pass(200, 20);
    s.push("live", { key: "k1", type: "step", event: { kind: "phase", phase: "thinking" } }, "abcdef.99");
    await s.host.time.pass(EXPORT_MS + 100, 100);

    const e2e = exportedSpans(bodies).filter((x) => x.name === "chat.send.e2e");
    assert.equal(e2e.length, 1);
    const a = attrsOf(e2e[0]!);
    assert.equal(a["stillfail.station"], "st");
    assert.equal(a["stillfail.outcome"], "live");
    assert.equal(typeof a["stillfail.ack_ms"], "number");
    assert.equal(typeof a["stillfail.first_live_ms"], "number");
    // Ensure message content is never leaked into span attributes.
    assert.equal(JSON.stringify(e2e[0]).includes("hello private message"), false);
  } finally {
    await s.core.close();
  }
});
