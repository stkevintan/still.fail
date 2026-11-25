// Cross-platform H.264 video encoder for remote browser views (Chrome TabView and FarviewView):
//   1. macOS: still.fail Helper `frames.encode` (ImageIO JPEG decode -> VideoToolbox hardware H.264 AVCC)
//   2. Linux / Windows / fallback: persistent `ffmpeg` (`libx264 -preset ultrafast -tune zerolatency`) with streaming
//      Annex-B -> avcC + AVCC framing
//   3. Graceful fallback: returns null so the caller seamlessly stays on JPEG.
import { type ChildProcess, execFile, spawn } from "node:child_process";
import type { Socket } from "node:net";
import type { HelperApp } from "../helper/app.ts";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import type { Frame, FrameConfig, ScreenView, ScreenVideo } from "../screens/source.ts";
import { sizeOf } from "../sessions/image-size.ts";

export const DEFAULT_BROWSER_BITRATE = 4_000_000;
export const MIN_BROWSER_BITRATE = 200_000;
export const MAX_BROWSER_BITRATE = 25_000_000;
export const DEFAULT_BROWSER_FPS = 30;
const FFMPEG_BITRATE_CHANGE_RATIO = 0.35;
const FFMPEG_RESTART_COOLDOWN_MS = 3_000;
const FFMPEG_AU_FLUSH_MS = 2;
export const MAX_QUEUED_FRAMES = 4;

/**
 * Bounded H.264 output queue that never accumulates > `MAX_QUEUED_FRAMES` of latency and never
 * emits orphan P-frames with broken reference chains after a drop. Preserves any pending `config`
 * across drops so the decoder always receives the latest `avcC` on recovery.
 */
export class H264FrameQueue {
  readonly #max: number;
  readonly #onNeedKeyframe: () => void;
  #queue: Frame[] = [];
  #waiters: ((f: Frame | null) => void)[] = [];
  #awaitingKey = false;
  #droppedConfig: FrameConfig | undefined;
  #closed = false;

  constructor(onNeedKeyframe: () => void, max = MAX_QUEUED_FRAMES) {
    this.#onNeedKeyframe = onNeedKeyframe;
    this.#max = Math.max(1, max);
  }

  push(frame: Frame): void {
    if (this.#closed) return;
    if (this.#awaitingKey) {
      if (!frame.key) {
        if (frame.config) this.#droppedConfig = frame.config;
        return;
      }
      this.#awaitingKey = false;
    }
    const ready: Frame =
      !frame.config && this.#droppedConfig
        ? { ...frame, config: this.#droppedConfig }
        : frame;
    if (ready.config) this.#droppedConfig = undefined;

    const waiter = this.#waiters.shift();
    if (waiter !== undefined) {
      waiter(ready);
      return;
    }

    if (this.#queue.length < this.#max) {
      this.#queue.push(ready);
      return;
    }

    // Queue full: if the new frame is a keyframe, truncate everything older while keeping latest config.
    if (ready.key) {
      let latestCfg = ready.config;
      if (!latestCfg) {
        for (let i = this.#queue.length - 1; i >= 0; i--) {
          if (this.#queue[i]!.config) {
            latestCfg = this.#queue[i]!.config;
            break;
          }
        }
      }
      this.#queue = [latestCfg && !ready.config ? { ...ready, config: latestCfg } : ready];
      return;
    }

    // Otherwise check if there is a newer keyframe inside the queue we can truncate to.
    let lastKeyIdx = -1;
    for (let i = this.#queue.length - 1; i > 0; i--) {
      if (this.#queue[i]!.key) {
        lastKeyIdx = i;
        break;
      }
    }
    if (lastKeyIdx > 0) {
      let droppedCfg: FrameConfig | undefined;
      for (let i = 0; i < lastKeyIdx; i++) {
        if (this.#queue[i]!.config) droppedCfg = this.#queue[i]!.config;
      }
      this.#queue = this.#queue.slice(lastKeyIdx);
      if (droppedCfg && !this.#queue[0]!.config) {
        this.#queue[0] = { ...this.#queue[0]!, config: droppedCfg };
      }
      this.#queue.push(ready);
      return;
    }

    // No newer keyframe to anchor to: clear queue, preserve latest config, drop orphan P-frames until IDR.
    for (const f of this.#queue) {
      if (f.config) this.#droppedConfig = f.config;
    }
    if (ready.config) this.#droppedConfig = ready.config;
    this.#queue.length = 0;
    this.#awaitingKey = true;
    this.#onNeedKeyframe();
  }

  next(): Promise<Frame | null> {
    const queued = this.#queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    if (this.#closed) return Promise.resolve(null);
    return new Promise((resolve) => this.#waiters.push(resolve));
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    for (const w of this.#waiters.splice(0)) w(null);
    this.#queue.length = 0;
    this.#droppedConfig = undefined;
  }
}

export interface BrowserVideoEncoder {
  /** Feed a JPEG picture with timestamp in microseconds. */
  pushJpeg(data: Uint8Array, ts: number): void;
  /** Dynamically adjust target bitrate in bits/s. */
  setBitrate(bps: number): void;
  /** Request an IDR keyframe (re-encodes cached last JPEG if the page is static). */
  requestKeyframe(): void;
  /** Pull the next encoded H.264 AVCC frame, or null when closed/ended. */
  next(): Promise<Frame | null>;
  /** Encoder metadata for ScreenView.video(). */
  info(): { encoder: string; hardware: boolean };
  /** Stop the encoder and release its resources. */
  close(): void;
}

export type BrowserVideoEncoderOptions = {
  helper?: HelperApp | null;
  width?: number;
  height?: number;
  bitrate?: number;
  fps?: number;
  now?: () => number;
  /** Optional factory override for deterministic tests. */
  factory?: BrowserVideoEncoderFactory;
};

export type BrowserVideoEncoderFactory = (options: Omit<BrowserVideoEncoderOptions, "factory">) => Promise<BrowserVideoEncoder | null>;

function clampBitrate(bps: number | undefined): number {
  if (bps === undefined || !Number.isFinite(bps)) return DEFAULT_BROWSER_BITRATE;
  return Math.min(MAX_BROWSER_BITRATE, Math.max(MIN_BROWSER_BITRATE, Math.round(bps)));
}

function clampFps(fps: number | undefined): number {
  if (fps === undefined || !Number.isFinite(fps)) return DEFAULT_BROWSER_FPS;
  return Math.min(60, Math.max(1, Math.round(fps)));
}

function even(n: number): number {
  return n <= 0 ? 0 : Math.max(2, Math.floor(n) & ~1);
}

function jpegDimensions(data: Uint8Array): { width: number; height: number } | null {
  if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) return null;
  const s = sizeOf(data);
  return s ? { width: s[0], height: s[1] } : null;
}

// ---------------------------------------------------------------------------
// Annex-B H.264 -> avcC + AVCC Access Unit parser
// ---------------------------------------------------------------------------

export type ParsedAccessUnit = {
  key: boolean;
  data: Uint8Array;
  avcc?: Uint8Array;
};

/** Build a standard ISO/IEC 14496-15 AVCDecoderConfigurationRecord (`avcC`) from raw SPS & PPS NALUs. */
export function buildAvcC(sps: Uint8Array, pps: Uint8Array): Uint8Array {
  if (sps.length < 4 || pps.length < 1) throw new Error("invalid SPS/PPS for avcC");
  const profile = sps[1]!;
  const hasHighExt = profile === 100 || profile === 110 || profile === 122 || profile === 244;
  const total = 11 + sps.length + pps.length + (hasHighExt ? 4 : 0);
  const out = new Uint8Array(total);
  let i = 0;
  out[i++] = 1; // configurationVersion
  out[i++] = profile; // AVCProfileIndication
  out[i++] = sps[2]!; // profile_compatibility
  out[i++] = sps[3]!; // AVCLevelIndication
  out[i++] = 0xff; // 6 reserved 1s + lengthSizeMinusOne (3 -> 4-byte lengths)
  out[i++] = 0xe1; // 3 reserved 1s + numOfSequenceParameterSets (1)
  out[i++] = (sps.length >> 8) & 0xff;
  out[i++] = sps.length & 0xff;
  out.set(sps, i);
  i += sps.length;
  out[i++] = 1; // numOfPictureParameterSets
  out[i++] = (pps.length >> 8) & 0xff;
  out[i++] = pps.length & 0xff;
  out.set(pps, i);
  i += pps.length;
  if (hasHighExt) {
    // ISO/IEC 14496-15 §5.3.3.1.2 High profile extension for 4:2:0 8-bit.
    out[i++] = 0xfd; // 111111 + chroma_format (1 = 4:2:0)
    out[i++] = 0xf8; // 11111 + bit_depth_luma_minus8 (0)
    out[i++] = 0xf8; // 11111 + bit_depth_chroma_minus8 (0)
    out[i++] = 0x00; // numOfSequenceParameterSetExt
  }
  return out;
}

/** Pack an array of raw NAL units into 4-byte big-endian length-prefixed AVCC format. */
export function packAvccNalus(nalus: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const n of nalus) total += 4 + n.length;
  const out = new Uint8Array(total);
  const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
  let offset = 0;
  for (const n of nalus) {
    view.setUint32(offset, n.length, false);
    offset += 4;
    out.set(n, offset);
    offset += n.length;
  }
  return out;
}

function bytesEqual(a: Uint8Array | null, b: Uint8Array | null): boolean {
  if (a === b) return true;
  if (a === null || b === null || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** Find the next Annex-B start code (`00 00 01` or `00 00 00 01`) at or after `from`. */
function findStartCode(buf: Uint8Array, from: number): { index: number; length: number } | null {
  const end = buf.length - 2;
  for (let i = from; i < end; i++) {
    if (buf[i] === 0 && buf[i + 1] === 0) {
      if (buf[i + 2] === 1) return { index: i, length: 3 };
      if (i + 3 < buf.length && buf[i + 2] === 0 && buf[i + 3] === 1) return { index: i, length: 4 };
    }
  }
  return null;
}

/**
 * Streaming Annex-B H.264 parser that handles arbitrary chunk splits, extracts SPS/PPS into `avcC`,
 * and emits complete Access Units as 4-byte length-prefixed AVCC payloads.
 */
export class AnnexBParser {
  #buf: Uint8Array = new Uint8Array(0);
  #sps: Uint8Array | null = null;
  #pps: Uint8Array | null = null;
  #lastAvcc: Uint8Array | null = null;
  #auNalus: Uint8Array[] = [];
  #auHasVcl = false;
  #auIsKey = false;

  /** Whether a trailing VCL NALU is currently buffered awaiting the next start code or flush(). */
  hasPendingVcl(): boolean {
    if (this.#auHasVcl) return true;
    const sc = findStartCode(this.#buf, 0);
    if (sc === null) return false;
    const start = sc.index + sc.length;
    if (start >= this.#buf.length) return false;
    const nalType = this.#buf[start]! & 0x1f;
    return nalType === 1 || nalType === 5;
  }

  push(chunk: Uint8Array): ParsedAccessUnit[] {
    if (chunk.length === 0) return [];
    if (this.#buf.length === 0) {
      this.#buf = new Uint8Array(chunk);
    } else {
      const merged = new Uint8Array(this.#buf.length + chunk.length);
      merged.set(this.#buf, 0);
      merged.set(chunk, this.#buf.length);
      this.#buf = merged;
    }

    const out: ParsedAccessUnit[] = [];
    const first = findStartCode(this.#buf, 0);
    if (first === null) {
      // Keep at most 3 trailing bytes in case a start code is split across chunks.
      if (this.#buf.length > 3) this.#buf = this.#buf.subarray(this.#buf.length - 3);
      return out;
    }

    let cursor = first;
    for (;;) {
      const bodyStart = cursor.index + cursor.length;
      const next = findStartCode(this.#buf, bodyStart);
      if (next === null) {
        if (cursor.index > 0) this.#buf = this.#buf.slice(cursor.index);
        break;
      }
      const nalu = this.#buf.slice(bodyStart, next.index);
      if (nalu.length > 0) this.#consumeNalu(nalu, out);
      cursor = next;
    }
    return out;
  }

  /** Flush any trailing NALU / Access Unit at end-of-stream or frame-idle boundary. */
  flush(): ParsedAccessUnit[] {
    const out: ParsedAccessUnit[] = [];
    const sc = findStartCode(this.#buf, 0);
    if (sc !== null) {
      const nalu = this.#buf.slice(sc.index + sc.length);
      if (nalu.length > 0) this.#consumeNalu(nalu, out);
    }
    this.#buf = new Uint8Array(0);
    this.#emitAu(out);
    return out;
  }

  #consumeNalu(nalu: Uint8Array, out: ParsedAccessUnit[]) {
    const nalType = nalu[0]! & 0x1f;
    // Non-VCL delimiters or parameter sets after VCL NALUs end the previous Access Unit.
    if (this.#auHasVcl && (nalType === 6 || nalType === 7 || nalType === 8 || nalType === 9)) {
      this.#emitAu(out);
    }
    if (nalType === 7) {
      this.#sps = nalu;
      return;
    }
    if (nalType === 8) {
      this.#pps = nalu;
      return;
    }
    if (nalType === 6 || nalType === 9) return;
    if (nalType === 1 || nalType === 5) {
      // first_mb_in_slice == 0 (exp-Golomb 0 -> MSB bit = 1) starts a new picture when we already have a VCL NALU.
      const firstMbZero = nalu.length >= 2 && (nalu[1]! & 0x80) !== 0;
      if (this.#auHasVcl && firstMbZero) this.#emitAu(out);
      this.#auNalus.push(nalu);
      this.#auHasVcl = true;
      if (nalType === 5) this.#auIsKey = true;
    }
  }

  #emitAu(out: ParsedAccessUnit[]) {
    if (!this.#auHasVcl || this.#auNalus.length === 0) {
      this.#auNalus = [];
      this.#auHasVcl = false;
      this.#auIsKey = false;
      return;
    }
    let avcc: Uint8Array | undefined;
    if (this.#sps !== null && this.#pps !== null) {
      const built = buildAvcC(this.#sps, this.#pps);
      if (!bytesEqual(built, this.#lastAvcc)) {
        this.#lastAvcc = built;
        avcc = built;
      }
    }
    const au: ParsedAccessUnit = {
      key: this.#auIsKey,
      data: packAvccNalus(this.#auNalus),
      ...(avcc ? { avcc } : {}),
    };
    this.#auNalus = [];
    this.#auHasVcl = false;
    this.#auIsKey = false;
    out.push(au);
  }
}

// ---------------------------------------------------------------------------
// Backend 1: macOS still.fail Helper `frames.encode` (VideoToolbox H.264)
// ---------------------------------------------------------------------------

const helperEncodeCaps = new WeakMap<HelperApp, Promise<boolean>>();

export async function helperSupportsEncode(helper: HelperApp): Promise<boolean> {
  let cached = helperEncodeCaps.get(helper);
  if (cached === undefined) {
    cached = helper
      .request({ op: "hello" })
      .then((ans) => Array.isArray(ans?.capabilities) && ans.capabilities.includes("encode"))
      .catch(() => {
        helperEncodeCaps.delete(helper);
        return false;
      });
    helperEncodeCaps.set(helper, cached);
  }
  return cached;
}

function encodeHelperMsg(kind: number, payload: Buffer): Buffer {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

export class HelperVideoEncoder implements BrowserVideoEncoder {
  readonly ready: Promise<void>;
  readonly #socket: Socket;
  readonly #out: H264FrameQueue;
  #carry: Buffer = Buffer.alloc(0);
  #pendingConfig: FrameConfig | undefined;
  #encoderName = "VideoToolbox H.264 (hardware)";
  #hardware = true;
  #closed = false;
  #settle!: { resolve: () => void; reject: (e: Error) => void };
  #settled = false;

  constructor(socket: Socket) {
    this.#socket = socket;
    this.#out = new H264FrameQueue(() => this.requestKeyframe());
    this.ready = new Promise((resolve, reject) => (this.#settle = { resolve, reject }));
    socket.on("data", (chunk: Buffer) => this.#onData(chunk));
    socket.on("error", (err: Error) => {
      if (!this.#settled) {
        this.#settled = true;
        this.#settle.reject(err);
      }
      this.close();
    });
    socket.on("close", () => {
      if (!this.#settled) {
        this.#settled = true;
        this.#settle.reject(new Error("helper frames.encode closed before ready"));
      }
      this.close();
    });
  }

  static async open(helper: HelperApp, opts: { width?: number; height?: number; bitrate?: number; fps?: number }): Promise<HelperVideoEncoder> {
    const socket = await helper.connect({
      op: "frames.encode",
      codec: "h264",
      ...(opts.width ? { width: even(opts.width) } : {}),
      ...(opts.height ? { height: even(opts.height) } : {}),
      bitrate: clampBitrate(opts.bitrate),
      fps: clampFps(opts.fps),
    });
    const enc = new HelperVideoEncoder(socket);
    try {
      await enc.ready;
      return enc;
    } catch (e) {
      enc.close();
      throw e;
    }
  }

  pushJpeg(data: Uint8Array, ts: number): void {
    if (this.#closed || data.length === 0) return;
    const head = Buffer.alloc(8);
    head.writeBigUInt64BE(BigInt(Math.max(0, Math.floor(ts))), 0);
    this.#socket.write(encodeHelperMsg(1, Buffer.concat([head, data])));
  }

  setBitrate(bps: number): void {
    if (this.#closed) return;
    this.#socket.write(encodeHelperMsg(2, Buffer.from(JSON.stringify({ bitrate: clampBitrate(bps) }))));
  }

  requestKeyframe(): void {
    if (this.#closed) return;
    this.#socket.write(encodeHelperMsg(2, Buffer.from(JSON.stringify({ keyframe: true }))));
  }

  next(): Promise<Frame | null> {
    return this.#out.next();
  }

  info(): { encoder: string; hardware: boolean } {
    return { encoder: this.#encoderName, hardware: this.#hardware };
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    try {
      if (!this.#socket.destroyed) {
        this.#socket.write(encodeHelperMsg(2, Buffer.from(JSON.stringify({ close: true }))));
        this.#socket.destroy();
      }
    } catch {}
    this.#out.close();
  }

  #onData(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    while (this.#carry.length >= 5) {
      const length = this.#carry.readUInt32BE(1);
      if (this.#carry.length < 5 + length) return;
      const kind = this.#carry[0]!;
      const payload = this.#carry.subarray(5, 5 + length);
      this.#carry = this.#carry.subarray(5 + length);
      this.#onMessage(kind, payload);
    }
  }

  #onMessage(kind: number, payload: Buffer) {
    switch (kind) {
      case 1: {
        let info: any = null;
        try {
          info = JSON.parse(payload.toString("utf8"));
        } catch {}
        if (!this.#settled) {
          this.#settled = true;
          if (typeof info?.error === "string") {
            this.#settle.reject(new Error(info.error));
          } else {
            if (typeof info?.encoder === "string" && info.encoder !== "") this.#encoderName = info.encoder;
            if (typeof info?.hardware === "boolean") this.#hardware = info.hardware;
            this.#settle.resolve();
          }
        }
        return;
      }
      case 2: {
        let cfg: any = null;
        try {
          cfg = JSON.parse(payload.toString("utf8"));
        } catch {}
        if (cfg && typeof cfg.width === "number" && typeof cfg.height === "number" && typeof cfg.avcc === "string") {
          this.#pendingConfig = {
            codec: "h264",
            width: cfg.width,
            height: cfg.height,
            description: new Uint8Array(Buffer.from(cfg.avcc, "base64")),
          };
        }
        return;
      }
      case 3: {
        if (payload.length < 10) return;
        const key = (payload[0]! & 1) === 1;
        const ts = Number(payload.readBigUInt64BE(1));
        const data = new Uint8Array(payload.subarray(9));
        const frame: Frame = {
          ...(this.#pendingConfig ? { config: this.#pendingConfig } : {}),
          key,
          ts,
          data,
        };
        this.#pendingConfig = undefined;
        this.#deliver(frame);
        return;
      }
      case 4: {
        log.warn("browser", "helper frames.encode error", { error: payload.toString("utf8") });
        this.close();
        return;
      }
    }
  }

  #deliver(frame: Frame) {
    this.#out.push(frame);
  }
}

// ---------------------------------------------------------------------------
// Backend 2: Persistent `ffmpeg` libx264 (Linux / Windows / no-helper fallback)
// ---------------------------------------------------------------------------

let ffmpegProbeCache: Promise<boolean> | null = null;
let ffmpegProbeOverride: (() => Promise<boolean>) | null = null;

/** For tests: override or clear ffmpeg availability probe. */
export function setFfmpegProbeForTest(probe: (() => Promise<boolean>) | null): void {
  ffmpegProbeOverride = probe;
  ffmpegProbeCache = null;
}

export function ffmpegAvailable(): Promise<boolean> {
  if (ffmpegProbeOverride !== null) return ffmpegProbeOverride();
  ffmpegProbeCache ??= new Promise<boolean>((resolve) => {
    // Verify ffmpeg actually has libx264 AND supports -fps_mode (FFmpeg >= 5.1) so older/LGPL builds fall back to JPEG cleanly.
    execFile("ffmpeg", ["-hide_banner", "-encoders"], { timeout: 3_000, maxBuffer: 2 * 1024 * 1024 }, (err, stdout) => {
      if (err || !/\blibx264\b/.test(String(stdout))) return resolve(false);
      execFile("ffmpeg", ["-hide_banner", "-h"], { timeout: 3_000, maxBuffer: 2 * 1024 * 1024 }, (hErr, hOut) => {
        resolve(!hErr && /-fps_mode\b/.test(String(hOut)));
      });
    });
  });
  return ffmpegProbeCache;
}

export type FfmpegSpawn = (args: string[]) => ChildProcess;

export class FfmpegVideoEncoder implements BrowserVideoEncoder {
  readonly #now: () => number;
  readonly #fps: number;
  readonly #spawnFn: FfmpegSpawn;
  #bitrate: number;
  #activeBitrate: number;
  #child: ChildProcess | null = null;
  #parser = new AnnexBParser();
  #width = 0;
  #height = 0;
  #tsQueue: number[] = [];
  #lastOutTs = 0;
  #lastInTs = 0;
  #lastJpeg: Uint8Array | null = null;
  #pendingWrite: Uint8Array | null = null;
  #draining = false;
  #lastRestart = -Infinity;
  #flushTimer: (() => void) | null = null;
  #primeTimer: (() => void) | null = null;
  #emittedForChild = false;
  readonly #out: H264FrameQueue;
  #closed = false;

  constructor(opts: { width?: number; height?: number; bitrate?: number; fps?: number; now?: () => number; spawn?: FfmpegSpawn } = {}) {
    this.#now = opts.now ?? (() => wall.now());
    this.#bitrate = clampBitrate(opts.bitrate);
    this.#activeBitrate = this.#bitrate;
    this.#fps = clampFps(opts.fps);
    this.#width = even(opts.width ?? 0);
    this.#height = even(opts.height ?? 0);
    this.#spawnFn = opts.spawn ?? ((args) => spawn("ffmpeg", args, { stdio: ["pipe", "pipe", "ignore"] }));
    this.#out = new H264FrameQueue(() => this.requestKeyframe());
  }

  static buildArgs(bitrate: number, fps: number): string[] {
    const rate = clampBitrate(bitrate);
    const maxrate = Math.round(rate * 1.15);
    const bufsize = Math.max(65_536, Math.round(rate * 0.25));
    return [
      "-hide_banner",
      "-loglevel",
      "error",
      "-fflags",
      "nobuffer",
      "-flags",
      "low_delay",
      "-probesize",
      "32",
      "-analyzeduration",
      "0",
      "-threads",
      "1",
      "-f",
      "image2pipe",
      "-vcodec",
      "mjpeg",
      "-framerate",
      String(clampFps(fps)),
      "-i",
      "pipe:0",
      "-fps_mode",
      "passthrough",
      "-vf",
      "scale=trunc(iw/2)*2:trunc(ih/2)*2",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-tune",
      "zerolatency",
      "-pix_fmt",
      "yuv420p",
      "-profile:v",
      "high",
      "-bf",
      "0",
      "-g",
      "999999",
      "-b:v",
      String(rate),
      "-maxrate",
      String(maxrate),
      "-bufsize",
      String(bufsize),
      "-flush_packets",
      "1",
      "-f",
      "h264",
      "pipe:1",
    ];
  }

  pushJpeg(data: Uint8Array, ts: number): void {
    if (this.#closed || data.length === 0) return;
    const dims = jpegDimensions(data);
    const w = dims ? even(dims.width) : this.#width;
    const h = dims ? even(dims.height) : this.#height;
    const sizeChanged = dims !== null && (w !== this.#width || h !== this.#height);
    if (dims !== null) {
      this.#width = w;
      this.#height = h;
    }

    this.#lastJpeg = data;
    this.#lastInTs = Math.max(this.#lastInTs + 1, Math.floor(ts));

    const now = this.#now();
    const rateChanged =
      this.#child !== null &&
      Math.abs(this.#bitrate - this.#activeBitrate) / Math.max(1, this.#activeBitrate) >= FFMPEG_BITRATE_CHANGE_RATIO &&
      now - this.#lastRestart >= FFMPEG_RESTART_COOLDOWN_MS;

    if (this.#child === null || sizeChanged || rateChanged) {
      this.#restartProcess();
    }

    this.#writeFrame(data, this.#lastInTs);
  }

  setBitrate(bps: number): void {
    if (this.#closed) return;
    this.#bitrate = clampBitrate(bps);
  }

  requestKeyframe(): void {
    if (this.#closed) return;
    if (this.#lastJpeg === null) return;
    // Cleanly restart ffmpeg and re-feed the cached last JPEG so an IDR + config is emitted even on a static page.
    this.#restartProcess();
    this.#lastInTs += 1;
    this.#writeFrame(this.#lastJpeg, this.#lastInTs);
  }

  next(): Promise<Frame | null> {
    return this.#out.next();
  }

  info(): { encoder: string; hardware: boolean } {
    return { encoder: "ffmpeg libx264 (software)", hardware: false };
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#stopFlushTimer();
    this.#stopPrimeTimer();
    this.#killChild();
    this.#out.close();
  }

  #restartProcess() {
    this.#stopFlushTimer();
    this.#stopPrimeTimer();
    this.#killChild();
    this.#parser = new AnnexBParser();
    this.#tsQueue.length = 0;
    this.#pendingWrite = null;
    this.#draining = false;
    this.#emittedForChild = false;
    this.#activeBitrate = this.#bitrate;
    this.#lastRestart = this.#now();

    const child = this.#spawnFn(FfmpegVideoEncoder.buildArgs(this.#activeBitrate, this.#fps));
    this.#child = child;
    const parser = this.#parser;

    child.stdout?.on("data", (chunk: Buffer) => {
      if (this.#closed || this.#child !== child) return;
      this.#emittedForChild = true;
      this.#stopPrimeTimer();
      this.#stopFlushTimer();
      const aus = parser.push(chunk);
      for (const au of aus) this.#emitAu(au);
      if (parser.hasPendingVcl()) {
        // timer: burst debouncing for trailing Annex-B AU from ffmpeg pipe
        this.#flushTimer = wall.after(FFMPEG_AU_FLUSH_MS, () => {
          this.#flushTimer = null;
          if (this.#closed || this.#child !== child) return;
          for (const au of parser.flush()) this.#emitAu(au);
        });
      }
    });

    child.stdin?.on("error", () => {});
    child.stdin?.on("drain", () => {
      if (this.#closed || this.#child !== child) return;
      this.#draining = false;
      const pending = this.#pendingWrite;
      this.#pendingWrite = null;
      if (pending !== null) this.#writeFrame(pending, ++this.#lastInTs);
    });

    child.once("error", () => {
      if (this.#child === child) {
        this.#child = null;
        if (!this.#emittedForChild) this.close();
      }
    });
    child.once("exit", (code) => {
      if (this.#child === child) {
        this.#stopFlushTimer();
        this.#stopPrimeTimer();
        for (const au of parser.flush()) this.#emitAu(au);
        this.#child = null;
        if (!this.#emittedForChild && code !== 0) this.close();
      }
    });
  }

  #writeFrame(data: Uint8Array, ts: number) {
    const stdin = this.#child?.stdin;
    if (!stdin || stdin.destroyed || !stdin.writable) return;
    if (this.#draining) {
      this.#pendingWrite = data;
      return;
    }
    this.#tsQueue.push(ts);
    const ok = stdin.write(data);
    if (!ok) this.#draining = true;
    // ffmpeg image2pipe mjpeg_parser requires subsequent SOI boundaries to flush the first packet on static pages.
    if (!this.#emittedForChild && this.#primeTimer === null) {
      const child = this.#child;
      // timer: prime ffmpeg image2pipe mjpeg_parser lookahead when a static page sends only one JPEG
      this.#primeTimer = wall.after(20, () => {
        this.#primeTimer = null;
        if (this.#closed || this.#child !== child || this.#emittedForChild || this.#lastJpeg === null) return;
        const s = child?.stdin;
        if (!s || s.destroyed || !s.writable) return;
        s.write(this.#lastJpeg);
        s.write(this.#lastJpeg);
      });
    }
  }

  #emitAu(au: ParsedAccessUnit) {
    const rawTs = this.#tsQueue.shift();
    const ts = Math.max(this.#lastOutTs + 1, rawTs ?? this.#lastOutTs + 1);
    this.#lastOutTs = ts;
    const config: FrameConfig | undefined = au.avcc
      ? {
          codec: "h264",
          width: this.#width || 1280,
          height: this.#height || 720,
          description: au.avcc,
        }
      : undefined;
    const frame: Frame = {
      ...(config ? { config } : {}),
      key: au.key,
      ts,
      data: au.data,
    };
    this.#out.push(frame);
  }

  #stopFlushTimer() {
    this.#flushTimer?.();
    this.#flushTimer = null;
  }

  #stopPrimeTimer() {
    this.#primeTimer?.();
    this.#primeTimer = null;
  }

  #killChild() {
    const child = this.#child;
    this.#child = null;
    if (child === null) return;
    try {
      child.stdin?.end();
    } catch {}
    try {
      child.kill("SIGKILL");
    } catch {}
  }
}

// ---------------------------------------------------------------------------
// Factory: Priority 1 (macOS Helper) -> Priority 2 (ffmpeg) -> Priority 3 (null / JPEG)
// ---------------------------------------------------------------------------

export async function createBrowserVideoEncoder(options: BrowserVideoEncoderOptions): Promise<BrowserVideoEncoder | null> {
  if (options.factory) return options.factory(options);

  // Priority 1: macOS still.fail Helper hardware VideoToolbox encoder.
  if (options.helper) {
    try {
      if (await helperSupportsEncode(options.helper)) {
        return await HelperVideoEncoder.open(options.helper, options);
      }
    } catch (e) {
      log.warn("browser", "helper frames.encode unavailable, falling back", { error: (e as Error).message });
    }
  }

  // Priority 2: persistent ffmpeg libx264 process.
  if (await ffmpegAvailable()) {
    return new FfmpegVideoEncoder(options);
  }

  // Priority 3: no H.264 encoder available -> caller falls back to JPEG.
  return null;
}

// ---------------------------------------------------------------------------
// Generic ScreenView wrapper: transcodes any JPEG ScreenView into H.264 AVCC
// ---------------------------------------------------------------------------

export class H264ScreenViewWrapper implements ScreenView {
  readonly #inner: ScreenView;
  readonly #encoder: BrowserVideoEncoder;
  #closed = false;

  constructor(inner: ScreenView, encoder: BrowserVideoEncoder) {
    this.#inner = inner;
    this.#encoder = encoder;
    void this.#pump();
  }

  async #pump() {
    try {
      while (!this.#closed) {
        const frame = await this.#inner.next();
        if (frame === null || this.#closed) break;
        if (frame.config && frame.config.codec !== "jpeg") {
          // Unexpected non-JPEG frame; close cleanly.
          break;
        }
        this.#encoder.pushJpeg(frame.data, frame.ts);
      }
    } catch {}
    if (!this.#closed) this.close();
  }

  next(): Promise<Frame | null> {
    return this.#encoder.next();
  }

  keyframe(): void {
    this.#encoder.requestKeyframe();
  }

  rate(bitsPerSecond: number): void {
    this.#encoder.setBitrate(bitsPerSecond);
  }

  bounds(maxWidth: number, maxHeight: number, region?: Parameters<NonNullable<ScreenView["bounds"]>>[2]): void {
    this.#inner.bounds?.(maxWidth, maxHeight, region);
  }

  input(event: Parameters<ScreenView["input"]>[0]): Promise<void> {
    return this.#inner.input(event);
  }

  video(): ScreenVideo {
    const base = this.#inner.video?.();
    const enc = this.#encoder.info();
    return { capture: base?.capture ?? "Browser", encoder: enc.encoder, hardware: enc.hardware };
  }

  setClipboard(clip: Parameters<NonNullable<ScreenView["setClipboard"]>>[0], paste: boolean): Promise<void> {
    return this.#inner.setClipboard ? this.#inner.setClipboard(clip, paste) : Promise.resolve();
  }

  watchClipboard(heard: Parameters<NonNullable<ScreenView["watchClipboard"]>>[0]): () => void {
    return this.#inner.watchClipboard ? this.#inner.watchClipboard(heard) : () => {};
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#encoder.close();
    this.#inner.close();
  }
}
