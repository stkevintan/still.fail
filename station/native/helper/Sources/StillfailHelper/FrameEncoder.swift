// Hardware H.264 encoder for arbitrary JPEG frames (`frames.encode`): decodes each JPEG with ImageIO into a pooled
// BGRA CVPixelBuffer and encodes it with VideoToolbox into length-prefixed AVCC H.264. Requires no Screen Recording
// permission — pure image-to-video transcoding for remote browser tabs.
//
// After the JSON request line (`{ token, op: "frames.encode", codec: "h264", width?, height?, bitrate?, fps? }`),
// the connection carries Channel frames both ways:
//   in   1 frame     8 bytes timestamp (µs, big-endian), then JPEG bytes
//        2 control   JSON { bitrate?: Int, keyframe?: Bool, close?: Bool }
//   out  1 info      JSON { ok: true, codec: "h264", encoder: String, hardware: Bool } or { error: String }
//        2 config    JSON { codec: "h264", width: Int, height: Int, avcc: <base64> } (before first frame & on resize)
//        3 video     1 byte flags (bit 0: keyframe), 8 bytes timestamp (µs, big-endian), then AVCC payload
//        4 error     JSON { error: String }
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

final class FrameEncoder {
  static let maxFrameBytes = 16 << 20
  static let defaultBitrate = 4_000_000
  static let minBitrate = 200_000
  static let maxBitrate = 25_000_000
  static let defaultFps = 30
  static let ratePeak = 1.15
  static let vbvWindowSec = 0.25

  let channel: Channel
  let queue = DispatchQueue(label: "fail.still.helper.frame-encoder", qos: .userInteractive)

  private var session: VTCompressionSession?
  private var sessionSize = (0, 0)
  private var pool: CVPixelBufferPool?
  private var poolSize = (0, 0)
  private var bitrate: Int
  private let fps: Int
  private var encoderName = ""
  private var isHardware = true
  private var lastAvcc = Data()
  private var forceKey = true
  private var lastBuffer: CVPixelBuffer?
  private var pendingJpeg: (Data, Int64)?
  private var lastTs: Int64 = 0
  private var ended = false
  private var encoding = false

  private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  private let colorProperties: [(CFString, CFString)] = [
    (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
    (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB),
    (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
  ]

  private let colorAttachments: [(CFString, CFString)] = [
    (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
    (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
    (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
  ]

  init(channel: Channel, options: [String: Any]) {
    self.channel = channel
    let rawBitrate = (options["bitrate"] as? NSNumber)?.intValue ?? FrameEncoder.defaultBitrate
    self.bitrate = min(FrameEncoder.maxBitrate, max(FrameEncoder.minBitrate, rawBitrate))
    let rawFps = (options["fps"] as? NSNumber)?.intValue ?? FrameEncoder.defaultFps
    self.fps = min(60, max(1, rawFps))
    let initW = Self.even((options["width"] as? NSNumber)?.intValue ?? 0)
    let initH = Self.even((options["height"] as? NSNumber)?.intValue ?? 0)
    if initW >= 16 && initH >= 16 {
      _ = queue.sync { makeSession(initW, initH) }
    }
  }

  private static func even(_ v: Int) -> Int {
    v <= 0 ? 0 : max(2, v & ~1)
  }

  func run() {
    let info: [String: Any] = queue.sync {
      if encoderName.isEmpty {
        // Probe capability with a tiny session only if no initial dimensions were given.
        if makeSession(64, 64) {
          invalidateSession()
        } else {
          return ["error": "no H.264 encoder available"]
        }
      }
      return ["ok": true, "codec": "h264", "encoder": encoderName, "hardware": isHardware]
    }
    channel.sendJSON(1, info)
    if info["error"] != nil { return }

    while let (kind, payload) = channel.message(limit: FrameEncoder.maxFrameBytes) {
      switch kind {
      case 1:
        guard payload.count > 8 else { continue }
        let ts = payload.withUnsafeBytes { Int64(bitPattern: UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))) }
        let jpeg = payload.subarray(in: 8..<payload.count)
        queue.async { [self] in
          if ended { return }
          if encoding {
            // Single-slot latest-frame overwrite: drop stale intermediate JPEGs instead of queueing latency.
            pendingJpeg = (jpeg, ts)
            return
          }
          handleJpeg(jpeg, ts: ts)
        }
      case 2:
        guard let control = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { continue }
        if (control["close"] as? Bool) == true {
          stop()
          return
        }
        let nextBitrate = (control["bitrate"] as? NSNumber)?.intValue
        let wantKey = (control["keyframe"] as? Bool) == true
        queue.async { [self] in
          if ended { return }
          if let nextBitrate {
            updateBitrate(nextBitrate)
          }
          if wantKey {
            requestKeyframe()
          }
        }
      default:
        break
      }
    }
    stop()
  }

  private func stop() {
    queue.sync {
      if ended { return }
      ended = true
      invalidateSession()
      pool = nil
      poolSize = (0, 0)
      lastBuffer = nil
      pendingJpeg = nil
    }
  }

  private func invalidateSession() {
    if let s = session {
      VTCompressionSessionInvalidate(s)
    }
    session = nil
    sessionSize = (0, 0)
    lastAvcc = Data()
  }

  private func updateBitrate(_ bits: Int) {
    let clamped = min(FrameEncoder.maxBitrate, max(FrameEncoder.minBitrate, bits))
    bitrate = clamped
    if let s = session {
      Self.applyRate(s, clamped)
    }
  }

  private func requestKeyframe() {
    forceKey = true
    if encoding { return }
    if let pending = pendingJpeg {
      pendingJpeg = nil
      handleJpeg(pending.0, ts: pending.1)
      return
    }
    // If idle with a cached pixel buffer (static browser page), immediately re-encode an IDR frame.
    if let buffer = lastBuffer {
      let ts = lastTs + 1
      lastTs = ts
      encode(buffer, ts: ts)
    }
  }

  private func handleJpeg(_ jpeg: Data, ts: Int64) {
    guard let buffer = decodeJpeg(jpeg) else { return }
    lastBuffer = buffer
    let clampedTs = max(lastTs + 1, ts)
    lastTs = clampedTs
    encode(buffer, ts: clampedTs)
  }

  /// Decode JPEG bytes via Apple ImageIO into a reused BGRA CVPixelBuffer from `pool`.
  private func decodeJpeg(_ jpeg: Data) -> CVPixelBuffer? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let w = Self.even(image.width)
    let h = Self.even(image.height)
    guard w >= 2, h >= 2 else { return nil }

    if pool == nil || poolSize != (w, h) {
      let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: w,
        kCVPixelBufferHeightKey: h,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      ]
      pool = nil
      guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
      poolSize = (w, h)
    }
    guard let pool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
      let ctx = CGContext(
        data: base,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: srgbSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else { return nil }
    ctx.interpolationQuality = (w == image.width && h == image.height) ? .none : .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    for (key, value) in colorAttachments {
      CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
    return buffer
  }

  /// Adaptive max QP by target bitrate (aligned with Track 3): crisp text on healthy links,
  /// relaxes QP ceiling on weak links (< 1.5 Mbps) so VideoToolbox stays within target bitrate.
  static func maxQP(for bits: Int) -> Int {
    if bits >= 3_000_000 { return 38 }
    if bits >= 1_500_000 { return 42 }
    return 48
  }

  private static func applyRate(_ session: VTCompressionSession, _ bits: Int) {
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bits as CFTypeRef)
    // Tight VBV: DataRateLimits = [bytesAllowedInWindow, windowSeconds].
    let bytesInWindow = max(16_384.0, (Double(bits) / 8.0) * ratePeak * vbvWindowSec)
    let limits = [NSNumber(value: bytesInWindow), NSNumber(value: vbvWindowSec)] as CFArray
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    if #available(macOS 13.0, *) {
      VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: maxQP(for: bits) as CFTypeRef)
    }
  }

  private func makeSession(_ width: Int, _ height: Int) -> Bool {
    invalidateSession()
    let lowLatency: [CFString: Any] = [
      kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    let hardware: [CFString: Any] = [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    let tries: [(String, Bool, [CFString: Any])] = [
      ("VideoToolbox H.264 (hardware, low latency)", true, lowLatency),
      ("VideoToolbox H.264 (hardware)", true, hardware),
      ("VideoToolbox H.264 (software)", false, [:]),
    ]
    let profiles: [CFString] = [
      kVTProfileLevel_H264_High_AutoLevel,
      kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
      kVTProfileLevel_H264_Main_AutoLevel,
      kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
      kVTProfileLevel_H264_Baseline_AutoLevel,
    ]

    for (name, hw, spec) in tries {
      var made: VTCompressionSession?
      let status = VTCompressionSessionCreate(
        allocator: nil,
        width: Int32(width),
        height: Int32(height),
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: spec as CFDictionary,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &made
      )
      guard status == noErr, let made else { continue }
      let set = { (key: CFString, value: Any) in VTSessionSetProperty(made, key: key, value: value as CFTypeRef) }
      _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
      _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
      _ = set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
      for p in profiles where set(kVTCompressionPropertyKey_ProfileLevel, p) == noErr { break }
      Self.applyRate(made, bitrate)
      _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
      // Explicit large GOP (~1h / 999999 frames): on Apple Silicon VideoToolbox, leaving these unset or 0
      // falls back to a 0.5-2s automatic IDR interval; explicit large values yield true on-demand keyframes.
      _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 999_999)
      _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600)
      for (key, value) in colorProperties { _ = set(key, value) }
      VTCompressionSessionPrepareToEncodeFrames(made)
      session = made
      sessionSize = (width, height)
      encoderName = name
      isHardware = hw
      forceKey = true
      return true
    }
    return false
  }

  private func encode(_ buffer: CVPixelBuffer, ts: Int64) {
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    if session == nil || sessionSize != (w, h) {
      guard makeSession(w, h) else {
        channel.sendJSON(4, ["error": "failed to create H.264 encoder session for \(w)x\(h)"])
        return
      }
    }
    guard let current = session else { return }
    let key = forceKey
    forceKey = false
    encoding = true
    let props: CFDictionary? = key ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary) : nil
    // Fixed clamped frame duration avoids VFR first-frame bitrate explosion.
    let duration = CMTime(value: 1, timescale: Int32(fps))
    let status = VTCompressionSessionEncodeFrame(
      current,
      imageBuffer: buffer,
      presentationTimeStamp: CMTime(value: ts, timescale: 1_000_000),
      duration: duration,
      frameProperties: props,
      infoFlagsOut: nil
    ) { [weak self] status, _, sample in
      guard let self else { return }
      self.queue.async { self.encoded(status, sample, ts, askedKey: key) }
    }
    if status != noErr {
      encoding = false
      forceKey = forceKey || key
    }
  }

  private func encoded(_ status: OSStatus, _ sample: CMSampleBuffer?, _ ts: Int64, askedKey: Bool) {
    encoding = false
    if ended { return }
    defer {
      if !ended, !encoding, let next = pendingJpeg {
        pendingJpeg = nil
        handleJpeg(next.0, ts: next.1)
      }
    }
    guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
      forceKey = forceKey || askedKey
      return
    }
    if let format = CMSampleBufferGetFormatDescription(sample),
      let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
      let avcC = atoms["avcC"] as? Data, avcC != lastAvcc
    {
      lastAvcc = avcC
      let dims = CMVideoFormatDescriptionGetDimensions(format)
      channel.sendJSON(2, [
        "codec": "h264",
        "width": Int(dims.width),
        "height": Int(dims.height),
        "avcc": avcC.base64EncodedString(),
      ])
    }
    var key = true
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
      let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool
    {
      key = !notSync
    }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { return }
    var payload = Data(count: 9 + length)
    payload[0] = key ? 1 : 0
    var be = UInt64(bitPattern: ts).bigEndian
    payload.replaceSubrange(1..<9, with: Data(bytes: &be, count: 8))
    payload.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress! + 9)
    }
    channel.send(3, payload)
  }
}

private extension Data {
  func subarray(in range: Range<Int>) -> Data {
    Data(self[range])
  }
}
