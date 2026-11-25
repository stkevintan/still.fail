import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createServer, connect, type Socket } from "node:net";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import type { ChildProcess } from "node:child_process";
import type { HelperApp } from "../src/helper/app.ts";
import type { Frame, ScreenView } from "../src/screens/source.ts";
import {
  AnnexBParser,
  type BrowserVideoEncoder,
  FfmpegVideoEncoder,
  H264FrameQueue,
  H264ScreenViewWrapper,
  HelperVideoEncoder,
  MAX_QUEUED_FRAMES,
  buildAvcC,
  createBrowserVideoEncoder,
  packAvccNalus,
  setFfmpegProbeForTest,
} from "../src/browser/video-encode.ts";

function fakeJpeg(width: number, height: number, fill = 0): Uint8Array {
  const app0 = [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00];
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1];
  return Uint8Array.from([0xff, 0xd8, ...app0, ...sof, fill, 0xff, 0xd9]);
}

function sendHelperFrame(socket: Socket, kind: number, payload: Buffer) {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(payload.length, 1);
  socket.write(Buffer.concat([head, payload]));
}

test("buildAvcC produces valid AVCDecoderConfigurationRecord for High and Baseline profiles", () => {
  // High profile (profile_idc = 100 = 0x64) includes 4-byte chroma/bitdepth extension.
  const highSps = Uint8Array.from([0x67, 0x64, 0x00, 0x28, 0xac, 0xd9]);
  const pps = Uint8Array.from([0x68, 0xeb, 0xe3, 0xcb]);
  const avccHigh = buildAvcC(highSps, pps);
  assert.equal(avccHigh[0], 1);
  assert.equal(avccHigh[1], 0x64);
  assert.equal(avccHigh[2], 0x00);
  assert.equal(avccHigh[3], 0x28);
  assert.equal(avccHigh[4], 0xff);
  assert.equal(avccHigh[5], 0xe1);
  assert.equal((avccHigh[6]! << 8) | avccHigh[7]!, highSps.length);
  assert.equal(avccHigh.length, 11 + highSps.length + pps.length + 4);
  assert.deepEqual([...avccHigh.subarray(avccHigh.length - 4)], [0xfd, 0xf8, 0xf8, 0x00]);

  // Baseline profile (profile_idc = 66 = 0x42) omits High profile extension.
  const baseSps = Uint8Array.from([0x67, 0x42, 0xc0, 0x1f, 0xaa]);
  const avccBase = buildAvcC(baseSps, pps);
  assert.equal(avccBase[1], 0x42);
  assert.equal(avccBase.length, 11 + baseSps.length + pps.length);
});

test("packAvccNalus writes 4-byte big-endian length prefixes", () => {
  const n1 = Uint8Array.from([0x65, 0x88, 0x01]);
  const n2 = Uint8Array.from([0x41, 0x9a]);
  const packed = packAvccNalus([n1, n2]);
  assert.equal(packed.length, 4 + 3 + 4 + 2);
  const view = new DataView(packed.buffer, packed.byteOffset, packed.byteLength);
  assert.equal(view.getUint32(0, false), 3);
  assert.deepEqual([...packed.subarray(4, 7)], [0x65, 0x88, 0x01]);
  assert.equal(view.getUint32(7, false), 2);
  assert.deepEqual([...packed.subarray(11, 13)], [0x41, 0x9a]);
});

test("AnnexBParser handles chunk splits, extracts avcC, emits IDR/P AVCC units, and detects SPS changes", () => {
  const sps1 = Uint8Array.from([0x67, 0x64, 0x00, 0x28, 0x01]);
  const pps1 = Uint8Array.from([0x68, 0xee, 0x3c, 0x80]);
  const idr1 = Uint8Array.from([0x65, 0x88, 0x84, 0x01, 0x02]);
  const p1 = Uint8Array.from([0x41, 0x9a, 0x22, 0x33]);
  const sps2 = Uint8Array.from([0x67, 0x64, 0x00, 0x2a, 0x02]); // new resolution SPS
  const idr2 = Uint8Array.from([0x65, 0x88, 0x99]);

  const sc4 = Uint8Array.from([0, 0, 0, 1]);
  const sc3 = Uint8Array.from([0, 0, 1]);
  const stream = Buffer.concat([sc4, sps1, sc4, pps1, sc4, idr1, sc3, p1, sc4, sps2, sc4, pps1, sc4, idr2]);

  const parser = new AnnexBParser();
  const units = [];
  // Feed 2 bytes at a time to exercise arbitrary split boundaries across start codes.
  for (let i = 0; i < stream.length; i += 2) {
    units.push(...parser.push(stream.subarray(i, Math.min(stream.length, i + 2))));
  }
  units.push(...parser.flush());

  assert.equal(units.length, 3);
  // Frame 1: IDR with initial avcC
  assert.equal(units[0]!.key, true);
  assert.deepEqual(units[0]!.avcc, buildAvcC(sps1, pps1));
  assert.deepEqual(units[0]!.data, packAvccNalus([idr1]));
  // Frame 2: P-frame without repeated avcC
  assert.equal(units[1]!.key, false);
  assert.equal(units[1]!.avcc, undefined);
  assert.deepEqual(units[1]!.data, packAvccNalus([p1]));
  // Frame 3: IDR with updated avcC after SPS change
  assert.equal(units[2]!.key, true);
  assert.deepEqual(units[2]!.avcc, buildAvcC(sps2, pps1));
  assert.deepEqual(units[2]!.data, packAvccNalus([idr2]));
});

test("HelperVideoEncoder speaks frames.encode protocol: config, IDR/P, bitrate, static keyframe, and resize", async () => {
  const receivedControls: any[] = [];
  const receivedFrames: { ts: number; bytes: number }[] = [];
  const avcc1 = buildAvcC(Uint8Array.from([0x67, 0x64, 0x00, 0x28, 0x01]), Uint8Array.from([0x68, 0xee]));
  const avcc2 = buildAvcC(Uint8Array.from([0x67, 0x64, 0x00, 0x2a, 0x02]), Uint8Array.from([0x68, 0xee]));

  const serverSockets: Socket[] = [];
  const server = createServer((sock) => {
    serverSockets.push(sock);
    let headerDone = false;
    let carry: Buffer = Buffer.alloc(0);
    let lastTs = 0;
    let count = 0;

    sock.on("data", (chunk: Buffer) => {
      carry = Buffer.concat([carry, chunk]);
      if (!headerDone) {
        const nl = carry.indexOf(10);
        if (nl < 0) return;
        const req = JSON.parse(carry.subarray(0, nl).toString("utf8"));
        assert.equal(req.op, "frames.encode");
        assert.equal(req.codec, "h264");
        carry = carry.subarray(nl + 1);
        headerDone = true;
        sendHelperFrame(sock, 1, Buffer.from(JSON.stringify({ ok: true, codec: "h264", encoder: "VideoToolbox H.264 (hardware, low latency)", hardware: true })));
      }
      while (carry.length >= 5) {
        const len = carry.readUInt32BE(1);
        if (carry.length < 5 + len) return;
        const kind = carry[0]!;
        const payload = carry.subarray(5, 5 + len);
        carry = carry.subarray(5 + len);
        if (kind === 1) {
          const ts = Number(payload.readBigUInt64BE(0));
          const jpeg = payload.subarray(8);
          lastTs = ts;
          count++;
          receivedFrames.push({ ts, bytes: jpeg.length });
          if (count === 1) {
            sendHelperFrame(sock, 2, Buffer.from(JSON.stringify({ codec: "h264", width: 1280, height: 720, avcc: Buffer.from(avcc1).toString("base64") })));
            const out = Buffer.alloc(9 + 4);
            out[0] = 1; // keyframe
            out.writeBigUInt64BE(BigInt(ts), 1);
            out.writeUInt32BE(0xdeadbeef, 9);
            sendHelperFrame(sock, 3, out);
          } else if (count === 2) {
            const out = Buffer.alloc(9 + 4);
            out[0] = 0; // P-frame
            out.writeBigUInt64BE(BigInt(ts), 1);
            out.writeUInt32BE(0x11223344, 9);
            sendHelperFrame(sock, 3, out);
          } else {
            // Simulate resize on 3rd frame -> new config + IDR
            sendHelperFrame(sock, 2, Buffer.from(JSON.stringify({ codec: "h264", width: 1920, height: 1080, avcc: Buffer.from(avcc2).toString("base64") })));
            const out = Buffer.alloc(9 + 4);
            out[0] = 1;
            out.writeBigUInt64BE(BigInt(ts), 1);
            out.writeUInt32BE(0x55667788, 9);
            sendHelperFrame(sock, 3, out);
          }
        } else if (kind === 2) {
          const ctrl = JSON.parse(payload.toString("utf8"));
          receivedControls.push(ctrl);
          if (ctrl.keyframe === true) {
            // Static page IDR re-encode
            lastTs += 1;
            const out = Buffer.alloc(9 + 4);
            out[0] = 1;
            out.writeBigUInt64BE(BigInt(lastTs), 1);
            out.writeUInt32BE(0xcafebabe, 9);
            sendHelperFrame(sock, 3, out);
          }
        }
      }
    });
  });

  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;

  const fakeHelper = {
    request: async (op: any) => (op.op === "hello" ? { ok: true, capabilities: ["screen", "encode"] } : {}),
    connect: async (op: any) => {
      const s = connect({ host: "127.0.0.1", port });
      await new Promise<void>((r) => s.once("connect", r));
      s.write(`${JSON.stringify(op)}\n`);
      return s;
    },
  } as unknown as HelperApp;

  const enc = await createBrowserVideoEncoder({ helper: fakeHelper, width: 1280, height: 720, bitrate: 3_000_000, fps: 30 });
  assert.ok(enc instanceof HelperVideoEncoder);
  assert.deepEqual(enc.info(), { encoder: "VideoToolbox H.264 (hardware, low latency)", hardware: true });

  enc.pushJpeg(fakeJpeg(1280, 720, 1), 1000);
  const f1 = (await enc.next())!;
  assert.equal(f1.key, true);
  assert.equal(f1.ts, 1000);
  assert.deepEqual(f1.config, { codec: "h264", width: 1280, height: 720, description: avcc1 });

  enc.pushJpeg(fakeJpeg(1280, 720, 2), 34_333);
  const f2 = (await enc.next())!;
  assert.equal(f2.key, false);
  assert.equal(f2.config, undefined);

  // Static page keyframe request -> IDR emitted without new JPEG
  enc.setBitrate(2_500_000);
  enc.requestKeyframe();
  const fKey = (await enc.next())!;
  assert.equal(fKey.key, true);
  assert.equal(fKey.ts, 34_334);

  // Resolution change -> new config + IDR
  enc.pushJpeg(fakeJpeg(1920, 1080, 3), 67_000);
  const f3 = (await enc.next())!;
  assert.equal(f3.key, true);
  assert.deepEqual(f3.config, { codec: "h264", width: 1920, height: 1080, description: avcc2 });

  enc.close();
  assert.equal(await enc.next(), null);
  assert.ok(receivedControls.some((c) => c.bitrate === 2_500_000));
  assert.ok(receivedControls.some((c) => c.keyframe === true));
  assert.equal(receivedFrames.length, 3);

  for (const s of serverSockets) s.destroy();
  server.close();
});

test("FfmpegVideoEncoder restarts cleanly on resolution change and static keyframe request", async () => {
  const spawns: string[][] = [];
  const sps = Uint8Array.from([0x67, 0x64, 0x00, 0x28, 0x01]);
  const pps = Uint8Array.from([0x68, 0xee, 0x3c, 0x80]);
  const idr = Uint8Array.from([0x65, 0x88, 0x01, 0x02]);
  const pframe = Uint8Array.from([0x41, 0x9a, 0x03, 0x04]);
  const sc4 = Uint8Array.from([0, 0, 0, 1]);

  let spawnCount = 0;
  const mockSpawn = (args: string[]): ChildProcess => {
    spawns.push(args);
    spawnCount++;
    const stdin = new PassThrough();
    const stdout = new PassThrough();
    const child = Object.assign(new EventEmitter(), {
      stdin,
      stdout,
      kill: () => {
        child.emit("exit", 0);
        return true;
      },
    }) as unknown as ChildProcess;

    let frameIdx = 0;
    stdin.on("data", () => {
      frameIdx++;
      if (frameIdx === 1) {
        // First frame after spawn emits SPS + PPS + IDR
        stdout.write(Buffer.concat([sc4, sps, sc4, pps, sc4, idr]));
      } else {
        stdout.write(Buffer.concat([sc4, pframe]));
      }
    });
    return child;
  };

  let now = 10_000;
  const enc = new FfmpegVideoEncoder({ width: 1280, height: 720, bitrate: 4_000_000, fps: 30, now: () => now, spawn: mockSpawn });

  // Frame 1: spawns ffmpeg, emits config + IDR
  enc.pushJpeg(fakeJpeg(1280, 720, 1), 1000);
  const f1 = (await enc.next())!;
  assert.equal(spawnCount, 1);
  assert.equal(f1.key, true);
  assert.equal(f1.config?.codec, "h264");
  assert.equal(f1.config?.width, 1280);
  assert.equal(f1.config?.height, 720);
  assert.deepEqual(f1.config?.description, buildAvcC(sps, pps));

  // Frame 2 (same size): reuses persistent ffmpeg process, emits P-frame
  enc.pushJpeg(fakeJpeg(1280, 720, 2), 34_000);
  const f2 = (await enc.next())!;
  assert.equal(spawnCount, 1, "persistent ffmpeg process must not restart on every frame");
  assert.equal(f2.key, false);
  assert.equal(f2.config, undefined);

  // Static page requestKeyframe(): restarts ffmpeg and re-feeds cached last JPEG -> IDR
  enc.requestKeyframe();
  const fKey = (await enc.next())!;
  assert.equal(spawnCount, 2);
  assert.equal(fKey.key, true);
  assert.equal(fKey.config?.codec, "h264");

  // Resolution change (odd height 675 clamped to even 674): restarts ffmpeg -> new config + IDR
  now += 5_000;
  enc.pushJpeg(fakeJpeg(960, 675, 3), 70_000);
  const f3 = (await enc.next())!;
  assert.equal(spawnCount, 3);
  assert.equal(f3.key, true);
  assert.equal(f3.config?.width, 960);
  assert.equal(f3.config?.height, 674);

  enc.close();
  assert.equal(await enc.next(), null);
});

test("createBrowserVideoEncoder falls back to null when neither helper encode nor ffmpeg is available", async () => {
  const noEncodeHelper = {
    request: async () => ({ ok: true, capabilities: ["screen", "files"] }),
  } as unknown as HelperApp;

  setFfmpegProbeForTest(async () => false);
  try {
    const enc = await createBrowserVideoEncoder({ helper: noEncodeHelper, width: 1280, height: 720 });
    assert.equal(enc, null);
  } finally {
    setFfmpegProbeForTest(null);
  }
});

test("H264ScreenViewWrapper transcodes JPEG ScreenView into H.264 and forwards controls", async () => {
  let innerClosed = false;
  let pushed = 0;
  let lastRate = 0;
  let keyframes = 0;
  const jpegQueue: (Frame | null)[] = [
    { config: { codec: "jpeg", width: 800, height: 600 }, key: true, ts: 100, data: fakeJpeg(800, 600, 1) },
    null,
  ];
  const inner: ScreenView = {
    next: async () => jpegQueue.shift() ?? null,
    keyframe: () => {},
    input: async () => {},
    video: () => ({ capture: "Custom" }),
    close: () => {
      innerClosed = true;
    },
  };
  const outFrames: Frame[] = [];
  let waiter: ((f: Frame | null) => void) | null = null;
  let encClosed = false;
  const fakeEncoder: BrowserVideoEncoder = {
    pushJpeg: (_data, ts) => {
      pushed++;
      const f: Frame = { config: { codec: "h264", width: 800, height: 600, description: Uint8Array.from([1, 0x64, 0, 0x28]) }, key: true, ts, data: Uint8Array.from([0, 0, 0, 2, 0x65, 0x88]) };
      if (waiter) {
        const w = waiter;
        waiter = null;
        w(f);
      } else {
        outFrames.push(f);
      }
    },
    setBitrate: (bps) => (lastRate = bps),
    requestKeyframe: () => keyframes++,
    next: () => {
      const f = outFrames.shift();
      if (f) return Promise.resolve(f);
      if (encClosed) return Promise.resolve(null);
      return new Promise((r) => (waiter = r));
    },
    info: () => ({ encoder: "Mock H.264", hardware: true }),
    close: () => {
      encClosed = true;
      const w = waiter;
      waiter = null;
      w?.(null);
    },
  };

  const wrapped = new H264ScreenViewWrapper(inner, fakeEncoder);
  const f = (await wrapped.next())!;
  assert.equal(f.config?.codec, "h264");
  assert.equal(pushed, 1);
  assert.deepEqual(wrapped.video(), { capture: "Custom", encoder: "Mock H.264", hardware: true });
  wrapped.rate(2_000_000);
  wrapped.keyframe();
  assert.equal(lastRate, 2_000_000);
  assert.equal(keyframes, 1);
  wrapped.close();
  assert.equal(innerClosed, true);
  assert.equal(encClosed, true);
});

test("H264FrameQueue bounds latency to MAX_QUEUED_FRAMES (4), drops broken P-frames, preserves config, and truncates to newer IDR", async () => {
  assert.equal(MAX_QUEUED_FRAMES, 4);
  const cfg = { codec: "h264" as const, width: 1280, height: 720, description: Uint8Array.from([1, 0x64, 0, 0x28]) };
  let keyframeAsks = 0;
  const q = new H264FrameQueue(() => keyframeAsks++);

  // 1. Fill queue with 1 IDR (carrying config) + 3 P-frames, then overflow with a 4th P-frame.
  q.push({ config: cfg, key: true, ts: 1, data: Uint8Array.from([1]) });
  q.push({ key: false, ts: 2, data: Uint8Array.from([2]) });
  q.push({ key: false, ts: 3, data: Uint8Array.from([3]) });
  q.push({ key: false, ts: 4, data: Uint8Array.from([4]) });
  assert.equal(keyframeAsks, 0);

  // Overflow with P-frame: must clear queue, request keyframe, and drop subsequent orphan P-frames until IDR!
  q.push({ key: false, ts: 5, data: Uint8Array.from([5]) });
  assert.equal(keyframeAsks, 1);
  q.push({ key: false, ts: 6, data: Uint8Array.from([6]) }); // orphan P-frame -> dropped

  // Recovery IDR arrives without config: must carry forward the preserved config!
  q.push({ key: true, ts: 7, data: Uint8Array.from([7]) });
  const recovered = (await q.next())!;
  assert.equal(recovered.key, true);
  assert.equal(recovered.ts, 7);
  assert.deepEqual(recovered.config, cfg, "preserved config must be attached to recovery IDR");

  // 2. Overflow when incoming frame is itself an IDR: truncates old queue cleanly without extra keyframe ask.
  q.push({ key: true, ts: 10, data: Uint8Array.from([10]) });
  q.push({ key: false, ts: 11, data: Uint8Array.from([11]) });
  q.push({ key: false, ts: 12, data: Uint8Array.from([12]) });
  q.push({ key: false, ts: 13, data: Uint8Array.from([13]) });
  q.push({ key: true, ts: 14, data: Uint8Array.from([14]) });
  assert.equal(keyframeAsks, 1, "no extra keyframe request needed when incoming frame is IDR");
  const latestIdr = (await q.next())!;
  assert.equal(latestIdr.ts, 14);
  assert.equal(latestIdr.key, true);

  q.close();
  assert.equal(await q.next(), null);
});
