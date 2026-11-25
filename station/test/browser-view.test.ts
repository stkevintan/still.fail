import assert from "node:assert/strict";
import { createServer, type Socket } from "node:net";
import { test } from "node:test";
import type { Frame } from "../src/screens/source.ts";
import type { Cdp, CdpEvent } from "../src/browser/cdp.ts";
import { FarviewScreen } from "../src/browser/farview-screen.ts";
import type { BrowserVideoEncoder } from "../src/browser/video-encode.ts";
import {
  H264_AUTO_MAX_HEIGHT,
  H264_AUTO_MAX_WIDTH,
  H264_SOURCE_QUALITY,
  JPEG_MIN_QUALITY,
  JPEG_RECAST_COOLDOWN_MS,
  JPEG_SUSTAINED_CONGESTION_MS,
  QUALITY,
  TabView,
  screencastBase,
} from "../src/browser/view.ts";

class FakeCdp implements Cdp {
  sent: { method: string; params: any; sessionId?: string }[] = [];
  answers: Record<string, (params: any) => any> = {};
  #listeners = new Set<(e: CdpEvent) => void>();
  #end!: () => void;
  closed = new Promise<void>((r) => (this.#end = r));
  gone = false;

  async send(method: string, params: object = {}, sessionId?: string) {
    if (this.gone) throw new Error("closed");
    this.sent.push({ method, params, sessionId });
    return this.answers[method]?.(params) ?? {};
  }

  on(listener: (e: CdpEvent) => void) {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  emit(method: string, params: any, sessionId?: string) {
    for (const l of [...this.#listeners]) l({ method, params, sessionId });
  }

  close() {
    this.gone = true;
    this.#end();
  }

  of(method: string) {
    return this.sent.filter((s) => s.method === method);
  }
}

function fakeJpeg(width: number, height: number, fill = 0): Uint8Array {
  const app0 = [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00];
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1];
  return Uint8Array.from([0xff, 0xd8, ...app0, ...sof, fill, 0xff, 0xd9]);
}

const b64 = (data: Uint8Array) => Buffer.from(data).toString("base64");

function makeMockEncoder() {
  const pushed: { bytes: number; ts: number }[] = [];
  const bitrates: number[] = [];
  let keyframeRequests = 0;
  let closed = false;
  let lastTs = 0;
  let sentConfig = false;
  const queue: Frame[] = [];
  let waiter: ((f: Frame | null) => void) | null = null;
  const avcc = Uint8Array.from([1, 0x64, 0x00, 0x28, 0xff, 0xe1, 0, 4, 0x67, 0x64, 0, 0x28, 1, 2, 0x68, 0xee]);

  const emit = (key: boolean, ts: number) => {
    const frame: Frame = {
      ...(!sentConfig ? { config: { codec: "h264" as const, width: 1280, height: 720, description: avcc } } : {}),
      key,
      ts,
      data: Uint8Array.from([0, 0, 0, 3, key ? 0x65 : 0x41, 0x88, ts & 0xff]),
    };
    sentConfig = true;
    if (waiter) {
      const w = waiter;
      waiter = null;
      w(frame);
    } else {
      queue.push(frame);
    }
  };

  const encoder: BrowserVideoEncoder = {
    pushJpeg(data, ts) {
      if (closed) return;
      pushed.push({ bytes: data.length, ts });
      lastTs = ts;
      emit(pushed.length === 1, ts);
    },
    setBitrate(bps) {
      bitrates.push(bps);
    },
    requestKeyframe() {
      keyframeRequests++;
      if (lastTs > 0 && !closed) {
        lastTs += 1;
        emit(true, lastTs);
      }
    },
    next() {
      const f = queue.shift();
      if (f) return Promise.resolve(f);
      if (closed) return Promise.resolve(null);
      return new Promise((r) => (waiter = r));
    },
    info: () => ({ encoder: "VideoToolbox H.264 (hardware, low latency)", hardware: true }),
    close() {
      closed = true;
      const w = waiter;
      waiter = null;
      w?.(null);
    },
  };

  return { encoder, pushed, bitrates, getKeyframes: () => keyframeRequests, isClosed: () => closed, avcc };
}

test("TabView in H.264 mode: outputs H.264 AVCC, pipelines acks, forwards rate() without recasting, and emits static IDR", async () => {
  const cdp = new FakeCdp();
  const mock = makeMockEncoder();
  let now = 10_000;
  const v = new TabView({
    cdp,
    session: "S",
    targetId: "T",
    now: () => now,
    createEncoder: async () => mock.encoder,
  });

  await v.start({ maxWidth: 2560, maxHeight: 1600, codecs: ["h264", "jpeg"], bitrate: 4_000_000, fps: 30 }, { width: 1440, height: 900 });

  // Captures crisp source quality (88) at high bounds instead of locking to 1280x900
  const casts = cdp.of("Page.startScreencast");
  assert.equal(casts.length, 1);
  assert.deepEqual(casts[0]!.params, {
    format: "jpeg",
    quality: H264_SOURCE_QUALITY,
    maxWidth: H264_AUTO_MAX_WIDTH,
    maxHeight: H264_AUTO_MAX_HEIGHT,
    everyNthFrame: 1,
  });
  assert.deepEqual(v.video(), {
    capture: "Chrome screencast",
    encoder: "VideoToolbox H.264 (hardware, low latency)",
    hardware: true,
  });

  // Emit CDP frame BEFORE calling next(): ack must be pipelined immediately!
  cdp.emit("Page.screencastFrame", { data: b64(fakeJpeg(1280, 720, 1)), sessionId: 11, metadata: { deviceWidth: 1440, deviceHeight: 900, timestamp: 1 } }, "S");
  assert.deepEqual(cdp.of("Page.screencastFrameAck").map((s) => s.params.sessionId), [11], "CDP ack is pipelined immediately");

  const f1 = (await v.next())!;
  assert.equal(f1.key, true);
  assert.equal(f1.config?.codec, "h264");
  assert.deepEqual(f1.config?.description, mock.avcc);

  // rate(bps) forwards smoothly to H.264 encoder and NEVER restarts Page.startScreencast
  v.rate(1_500_000);
  now += 3_000;
  v.rate(300_000);
  now += 10_000;
  v.rate(5_000_000);
  assert.deepEqual(mock.bitrates, [1_500_000, 300_000, 5_000_000]);
  assert.equal(cdp.of("Page.startScreencast").length, 1, "H.264 mode must never restart CDP screencast on rate()");

  // Static page keyframe() emits IDR immediately without any new CDP frame
  v.keyframe();
  const fKey = (await v.next())!;
  assert.equal(fKey.key, true);
  assert.equal(mock.getKeyframes(), 1);

  v.close();
  assert.equal(mock.isClosed(), true);
  assert.equal(await v.next(), null);
});

test("TabView in JPEG fallback mode: pipelines acks, avoids 2s quality=45/960x675 storm, and gently steps down only after >=5s congestion", async () => {
  const cdp = new FakeCdp();
  let now = 10_000;
  const v = new TabView({
    cdp,
    session: "S",
    targetId: "T",
    now: () => now,
    createEncoder: async () => null, // force JPEG fallback
  });

  await v.start({ maxWidth: 2560, maxHeight: 1800, codecs: ["h264", "jpeg"] }, { width: 1280, height: 900 });
  const casts = () => cdp.of("Page.startScreencast").map((c) => ({ q: c.params.quality, w: c.params.maxWidth, h: c.params.maxHeight }));
  assert.deepEqual(casts(), [{ q: QUALITY, w: 1280, h: 900 }]);
  assert.deepEqual(v.video(), { capture: "Chrome screencast", encoder: "JPEG" });

  // Pipelined ack immediately on frame arrival (before next() is called)
  cdp.emit("Page.screencastFrame", { data: b64(fakeJpeg(1280, 900, 1)), sessionId: 1, metadata: { deviceWidth: 1280, deviceHeight: 900, timestamp: 1 } }, "S");
  assert.deepEqual(cdp.of("Page.screencastFrameAck").map((s) => s.params.sessionId), [1]);
  const f1 = (await v.next())!;
  assert.equal(f1.config?.codec, "jpeg");

  // Brief congestion (< 5s): must NOT restart screencast!
  v.rate(300_000);
  now += 2_000;
  v.rate(300_000);
  now += 2_500;
  v.rate(300_000);
  assert.equal(casts().length, 1, "no recast during brief < 5s congestion");

  // Sustained severe congestion >= 5s: steps down gently ONCE to quality=72, keeping full 1280x900 bounds (never 45, never 960x675)
  now += JPEG_SUSTAINED_CONGESTION_MS - 4_500;
  v.rate(300_000);
  assert.equal(casts().length, 2);
  assert.deepEqual(casts().at(-1), { q: JPEG_MIN_QUALITY, w: 1280, h: 900 });

  // Recovery before 8s cooldown: does NOT flap
  now += 4_000;
  v.rate(2_000_000);
  assert.equal(casts().length, 2, "cooldown >= 8s prevents flapping");

  // Recovery after >= 8s cooldown: restores baseQuality
  now += JPEG_RECAST_COOLDOWN_MS - 4_000;
  v.rate(2_000_000);
  assert.equal(casts().length, 3);
  assert.deepEqual(casts().at(-1), { q: QUALITY, w: 1280, h: 900 });

  v.close();
});

test("TabView JPEG fallback delivers the final throttled frame once pacing interval elapses after page stops scrolling", async () => {
  const cdp = new FakeCdp();
  let now = 10_000;
  const scheduled: { ms: number; fn: () => void; cancelled: boolean }[] = [];
  const v = new TabView({
    cdp,
    session: "S",
    targetId: "T",
    now: () => now,
    createEncoder: async () => null,
    later: (ms, fn) => {
      const entry = { ms, fn, cancelled: false };
      scheduled.push(entry);
      return () => {
        entry.cancelled = true;
      };
    },
  });

  await v.start({ maxWidth: 1280, maxHeight: 900, codecs: ["jpeg"] }, { width: 1280, height: 900 });
  // Trigger smooth throttling: 400kbps -> 125ms min interval.
  v.rate(400_000);

  // Frame 1 arrives and is delivered immediately.
  cdp.emit("Page.screencastFrame", { data: b64(fakeJpeg(1280, 900, 1)), sessionId: 1, metadata: { deviceWidth: 1280, deviceHeight: 900, timestamp: 1 } }, "S");
  const f1 = (await v.next())!;
  assert.equal(f1.data[f1.data.length - 3], 1);

  // Viewer waits for next frame; page emits final frame 2 only 30ms later, then stops scrolling forever.
  let resolved: Frame | null | undefined;
  const pending = v.next().then((f) => (resolved = f));
  now += 30;
  cdp.emit("Page.screencastFrame", { data: b64(fakeJpeg(1280, 900, 2)), sessionId: 2, metadata: { deviceWidth: 1280, deviceHeight: 900, timestamp: 2 } }, "S");
  await Promise.resolve();
  assert.equal(resolved, undefined, "throttled before 125ms interval elapses");
  assert.equal(scheduled.length, 1);
  assert.equal(scheduled[0]!.ms, 95, "timer scheduled for remaining 95ms");

  // Once the 95ms timer fires with no further CDP frames, the final frame 2 must be delivered!
  now += 95;
  scheduled[0]!.fn();
  const f2 = (await pending)!;
  assert.equal(f2.data[f2.data.length - 3], 2, "final throttled frame must never hang");

  v.close();
});

test("TabView peek mode always stays on JPEG and never starts H.264 encoder", async () => {
  const cdp = new FakeCdp();
  let factoryCalled = false;
  const v = new TabView({
    cdp,
    session: "S",
    targetId: "T",
    now: () => 0,
    createEncoder: async () => {
      factoryCalled = true;
      return makeMockEncoder().encoder;
    },
  });
  await v.start({ maxWidth: 480, maxHeight: 270, codecs: ["h264", "jpeg"], peek: true }, { width: 1280, height: 900 });
  assert.equal(factoryCalled, false);
  assert.deepEqual(v.video(), { capture: "Chrome screencast", encoder: "JPEG" });
  v.close();
});

test("screencastBase scales bounds appropriately for H.264 vs JPEG modes", () => {
  const h264Auto = screencastBase({ maxWidth: 3840, maxHeight: 2160 }, true);
  assert.deepEqual(h264Auto, { bounds: { maxWidth: 2560, maxHeight: 1600 }, quality: 88 });
  const jpegAuto = screencastBase({ maxWidth: 3840, maxHeight: 2160 }, false);
  assert.deepEqual(jpegAuto, { bounds: { maxWidth: 1280, maxHeight: 900 }, quality: 82 });
});

test("FarviewScreen upgrades to H.264 when available and falls back to JPEG for peek or no encoder", async () => {
  const picture = Buffer.from(fakeJpeg(640, 450, 7));
  const heard: any[] = [];
  const sockets: Socket[] = [];
  const server = createServer((s) => {
    sockets.push(s);
    let buf = "";
    s.on("data", (d) => {
      buf += d.toString("latin1");
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const m = JSON.parse(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        heard.push(m);
        if (m.frame) {
          s.write(`${JSON.stringify({ frame: { seq: 1, width: 640, height: 450, format: "jpeg", bytes: picture.length } })}\n`);
          s.write(picture);
        }
      }
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;

  try {
    // 1. H.264 mode
    const mock = makeMockEncoder();
    const screen = new FarviewScreen({ session: "chat:c-fv", port, createEncoder: async () => mock.encoder });
    const view = await screen.open({ maxWidth: 1920, maxHeight: 1080, codecs: ["h264", "jpeg"], bitrate: 3_000_000 });
    const f1 = (await view.next())!;
    assert.equal(f1.config?.codec, "h264");
    assert.deepEqual(f1.config?.description, mock.avcc);
    assert.deepEqual(view.video?.(), { capture: "Farview", encoder: "VideoToolbox H.264 (hardware, low latency)", hardware: true });
    assert.equal(heard.find((m) => m.frame)?.frame.quality, 88);

    view.rate?.(1_200_000);
    assert.deepEqual(mock.bitrates, [1_200_000]);
    view.keyframe();
    const fKey = (await view.next())!;
    assert.equal(fKey.key, true);
    assert.equal(mock.getKeyframes(), 1);
    view.close();
    assert.equal(mock.isClosed(), true);

    // 2. Peek mode -> JPEG fallback
    const peekView = await screen.open({ maxWidth: 480, maxHeight: 270, codecs: ["h264", "jpeg"], peek: true });
    const fp = (await peekView.next())!;
    assert.equal(fp.config?.codec, "jpeg");
    assert.deepEqual(peekView.video?.(), { capture: "Farview" });
    peekView.close();

    screen.close();
  } finally {
    for (const s of sockets) s.destroy();
    server.close();
  }
});
