import Foundation
import CoreMedia
import CoreImage
import VideoToolbox
import WebRTC

/// The pinned WebRTC provides H.265 SDP/RTP support; these adapters provide Apple hardware codecs.
enum DesktopHEVCFormat {
    static let info = RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1", "tier-flag": "0", "level-id": "156", "tx-mode": "SRST"])
    static let maximumAccessUnit = 32 * 1024 * 1024

    static func accepts(_ info: RTCVideoCodecInfo) -> Bool {
        let parameters = info.parameters
        let level = Int(parameters["level-id"] ?? "93") ?? 0
        return info.name.uppercased() == "H265" && (parameters["profile-id"] ?? "1") == "1" &&
            (parameters["tier-flag"] ?? "0") == "0" && (parameters["tx-mode"] ?? "SRST") == "SRST" &&
            [30,60,63,90,93,120,123,150,153,156,180,183,186].contains(level)
    }
    static func maximumBitrate(level: Int) -> Int {
        switch level {
        case 156...: return 60_000_000
        case 153: return 40_000_000
        case 150: return 25_000_000
        case 123: return 20_000_000
        case 120: return 12_000_000
        case 93: return 10_000_000
        case 90: return 6_000_000
        case 63: return 3_000_000
        case 60: return 1_500_000
        default: return 128_000
        }
    }
    static func hardware(_ session: VTSession, key: CFString) -> Bool {
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &value) == noErr else { return false }
        return value?.takeRetainedValue() as? Bool == true
    }

    static func annexB(_ sample: CMSampleBuffer, keyframe: Bool) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= maximumAccessUnit else { return nil }
        var output = Data(), headerLength: Int32 = 0, setCount = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &setCount, nalUnitHeaderLengthOut: &headerLength) == noErr,
              (1...4).contains(headerLength), setCount <= 16 else { return nil }
        if keyframe {
            for index in 0..<setCount {
                var pointer: UnsafePointer<UInt8>?, size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer, size > 0, size <= 65536 else { return nil }
                output.append(contentsOf: [0,0,0,1]); output.append(pointer, count: size)
            }
        }
        // Copy handles non-contiguous CMBlockBuffers without reading past an individual segment.
        var payload = Data(count: length)
        let status = payload.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == noErr else { return nil }
        var cursor = 0
        while cursor < payload.count {
            guard payload.count - cursor >= Int(headerLength) else { return nil }
            var size = 0
            for _ in 0..<headerLength { size = size * 256 + Int(payload[cursor]); cursor += 1 }
            guard size >= 2, size <= payload.count - cursor else { return nil }
            output.append(contentsOf: [0,0,0,1]); output.append(payload.subdata(in: cursor..<(cursor + size))); cursor += size
        }
        return output.count <= maximumAccessUnit ? output : nil
    }

    static func nalUnits(_ data: Data) -> [Data]? {
        guard !data.isEmpty, data.count <= maximumAccessUnit else { return nil }
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], cursor = 0
        while cursor + 3 < bytes.count {
            if bytes[cursor] == 0 && bytes[cursor+1] == 0 && bytes[cursor+2] == 1 { starts.append((cursor, cursor+3)); cursor += 3 }
            else if bytes[cursor] == 0 && bytes[cursor+1] == 0 && bytes[cursor+2] == 0 && bytes[cursor+3] == 1 { starts.append((cursor, cursor+4)); cursor += 4 }
            else { cursor += 1 }
            guard starts.count <= 4096 else { return nil }
        }
        guard !starts.isEmpty, starts[0].0 == 0 else { return nil }
        var units: [Data] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index+1].0 : bytes.count
            guard end - start.1 >= 2, bytes[start.1] & 0x80 == 0, bytes[start.1+1] & 7 != 0 else { return nil }
            units.append(Data(bytes[start.1..<end]))
        }
        return units
    }
}

private final class HEVCCodecInfo: NSObject, RTCCodecSpecificInfo {}

private final class HEVCEncodeFrame {
    let encoder: DesktopHEVCEncoder
    let timestamp: UInt32
    let captureMilliseconds: Int64
    let rotation: RTCVideoRotation
    let width: Int32
    let height: Int32
    init(_ encoder: DesktopHEVCEncoder, frame: RTCVideoFrame) {
        self.encoder = encoder; timestamp = UInt32(bitPattern: frame.timeStamp)
        captureMilliseconds = frame.timeStampNs / 1_000_000; rotation = frame.rotation
        width = frame.width; height = frame.height
    }
}

final class DesktopHEVCEncoder: NSObject, RTCVideoEncoder {
    private var session: VTCompressionSession?
    private let level: Int
    private let limit: H264CaptureLimit
    private var scalePool: CVPixelBufferPool?
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])
    init(info: RTCVideoCodecInfo = DesktopHEVCFormat.info) {
        level = min(156, Int(info.parameters["level-id"] ?? "93") ?? 93)
        limit = H264CaptureLimit(hevcLevel: level)
        super.init()
    }
    private let lock = NSLock()
    private var callback: RTCVideoEncoderCallback?
    private var inFlight = 0
    private var width = 0, height = 0
    private var bitrate = 2_000_000
    private var fps = 30
    private var ratesChanged = false
    private var paused = false
    private var initialized = false
    private(set) var lastError: String?
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
    func implementationName() -> String { "VideoToolboxHEVC" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    func setCallback(_ callback: RTCVideoEncoderCallback?) { lock.lock(); self.callback = callback; lock.unlock() }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        bitrate = max(1, Int(settings.startBitrate)) * 1000
        fps = max(1, min(60, Int(settings.maxFramerate)))
        initialized = true
        return createSession(width: Int(settings.width), height: Int(settings.height)) ? 0 : -1
    }
    private func createSession(width: Int, height: Int) -> Bool {
        closeSession()
        guard width > 0, height > 0, width <= 3840, height <= 3840, width * height <= 3840 * 2160, ((width + 15) / 16) * ((height + 15) / 16) <= limit.frameMacroblocks else { return false }
        var next: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { _, refcon, status, flags, sample in
                guard let refcon else { return }
                let frame = Unmanaged<HEVCEncodeFrame>.fromOpaque(refcon).takeRetainedValue()
                frame.encoder.completed(frame, status: status, flags: flags, sample: sample)
            }, refcon: nil, compressionSessionOut: &next)
        guard status == noErr, let next else { lastError = "create:\(status)"; return false }
        session = next; self.width = width; self.height = height
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(next, key: key, value: value)
            guard status == noErr else { lastError = "property:\(key):\(status)"; closeSession(); return false }
        }
        // Some hardware HEVC encoders do not expose this optional latency hint.
        VTSessionSetProperty(next, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        applyRates()
        let prepared = VTCompressionSessionPrepareToEncodeFrames(next)
        guard prepared == noErr else { lastError = "prepare:\(prepared)"; closeSession(); return false }
        guard DesktopHEVCFormat.hardware(next, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) else { lastError = "hardware"; closeSession(); return false }
        return true
    }
    private func applyRates() {
        guard let session else { return }
        ratesChanged = false
        let target = min(bitrate, DesktopHEVCFormat.maximumBitrate(level: level))
        let blocks = max(1, ((width + 15) / 16) * ((height + 15) / 16))
        let rate = max(1, min(fps, limit.macroblocksPerSecond / blocks))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: target))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: rate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: rate * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [NSNumber(value: min(Double(target) * 1.5, Double(DesktopHEVCFormat.maximumBitrate(level: level))) / 8), 1] as CFArray)
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        paused = bitrateKbit == 0; bitrate = max(1, Int(bitrateKbit)) * 1000
        fps = max(1, min(60, Int(framerate))); ratesChanged = true; return 0
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        guard initialized else { return -1 }
        if paused { return 0 }
        guard let native = frame.buffer as? RTCCVPixelBuffer else { return -1 }
        if width != frame.width || height != frame.height {
            guard createSession(width: Int(frame.width), height: Int(frame.height)) else { return -1 }
        }
        guard let session else { return -1 }
        lock.lock()
        // One outstanding hardware frame bounds latency and keeps format discovery
        // from racing another submission during resolution changes.
        if inFlight >= 1 { lock.unlock(); return 0 }
        inFlight += 1; lock.unlock()
        // VT can synchronously query its encoder service while producing the first
        // format description. Apply rate changes only between completed frames.
        if ratesChanged { applyRates() }
        guard let buffer = adaptedBuffer(native) else {
            lock.lock(); inFlight -= 1; lock.unlock()
            return 0 // Bounded scaling-pool pressure drops a frame instead of breaking the codec.
        }
        let context = Unmanaged.passRetained(HEVCEncodeFrame(self, frame: frame))
        let force = frameTypes.contains { $0.intValue == RTCFrameType.videoFrameKey.rawValue }
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000), duration: CMTime(value: 1, timescale: Int32(fps)),
            frameProperties: force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            sourceFrameRefcon: context.toOpaque(), infoFlagsOut: nil)
        if status != noErr { context.release(); lock.lock(); inFlight -= 1; lock.unlock(); return -1 }
        return 0
    }
    private func adaptedBuffer(_ native: RTCCVPixelBuffer) -> CVPixelBuffer? {
        if !native.requiresCropping(), CVPixelBufferGetWidth(native.pixelBuffer) == width,
           CVPixelBufferGetHeight(native.pixelBuffer) == height { return native.pixelBuffer }
        if scalePool == nil {
            let attributes = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &scalePool) == kCVReturnSuccess else { return nil }
        }
        guard let scalePool else { return nil }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, scalePool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &result) == kCVReturnSuccess, let result else { return nil }
        let crop = CGRect(x: Int(native.cropX), y: CVPixelBufferGetHeight(native.pixelBuffer) - Int(native.cropY) - Int(native.cropHeight),
                          width: Int(native.cropWidth), height: Int(native.cropHeight))
        guard crop.width > 0, crop.height > 0 else { return nil }
        let image = CIImage(cvPixelBuffer: native.pixelBuffer).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / crop.width, y: CGFloat(height) / crop.height))
        imageContext.render(image, to: result, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return result
    }
    private func completed(_ frame: HEVCEncodeFrame, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        lock.lock(); inFlight -= 1; let callback = callback; lock.unlock()
        guard status == noErr, !flags.contains(.frameDropped), let sample, let callback else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        guard let bytes = DesktopHEVCFormat.annexB(sample, keyframe: keyframe) else { return }
        let image = RTCEncodedImage()
        image.buffer = bytes; image.encodedWidth = frame.width; image.encodedHeight = frame.height
        image.timeStamp = frame.timestamp; image.captureTimeMs = frame.captureMilliseconds; image.rotation = frame.rotation
        image.frameType = keyframe ? .videoFrameKey : .videoFrameDelta
        image.qp = -1; image.contentType = .screenshare
        _ = callback(image, HEVCCodecInfo())
    }
    private func closeSession() {
        // Discard obsolete live frames when reconfiguring instead of flushing delayed output.
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; scalePool = nil
    }
    func release() -> Int { initialized = false; closeSession(); return 0 }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}

private final class HEVCDecodeFrame {
    let decoder: DesktopHEVCDecoder
    let timestamp: UInt32
    let nanoseconds: Int64
    let rotation: RTCVideoRotation
    init(_ decoder: DesktopHEVCDecoder, image: RTCEncodedImage) {
        self.decoder = decoder; timestamp = image.timeStamp; rotation = image.rotation
        nanoseconds = min(max(0, image.captureTimeMs), Int64.max / 1_000_000) * 1_000_000
    }
}

final class DesktopHEVCDecoder: NSObject, RTCVideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Int: Data] = [:]
    private let lock = NSLock()
    private var callback: RTCVideoDecoderCallback?
    func implementationName() -> String { "VideoToolboxHEVC" }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { lock.lock(); self.callback = callback; lock.unlock() }
    func startDecode(withNumberOfCores cores: Int32) -> Int { 0 }
    private func createSession() -> Bool {
        guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return false }
        var nextFormat: CMFormatDescription?
        let status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p -> OSStatus in
            let pointers = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [vps.count, sps.count, pps.count]
            return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &nextFormat)
            } }
        } } }
        guard status == noErr, let nextFormat else { return false }
        let size = CMVideoFormatDescriptionGetDimensions(nextFormat)
        guard size.width > 0, size.height > 0, size.width <= 3840, size.height <= 3840,
              Int64(size.width) * Int64(size.height) <= 3840 * 2160 else { return false }
        closeSession()
        var next: VTDecompressionSession?
        var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, refcon, status, flags, pixels, _, _ in
            guard let refcon else { return }
            let frame = Unmanaged<HEVCDecodeFrame>.fromOpaque(refcon).takeRetainedValue()
            guard status == noErr, !flags.contains(.frameDropped), let pixels else { return }
            frame.decoder.completed(frame, pixels: pixels)
        }, decompressionOutputRefCon: nil)
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: nextFormat,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            outputCallback: &record, decompressionSessionOut: &next)
        guard created == noErr, let next else { return false }
        guard DesktopHEVCFormat.hardware(next, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder) else { VTDecompressionSessionInvalidate(next); return false }
        session = next; format = nextFormat
        VTSessionSetProperty(next, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return true
    }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        guard let units = DesktopHEVCFormat.nalUnits(image.buffer) else { return -1 }
        var changed = false, payload = Data(), hasPicture = false
        for unit in units {
            let type = Int((unit[0] >> 1) & 63)
            if (32...34).contains(type) {
                guard unit.count <= 65536 else { return -1 }
                if parameterSets[type] != unit { changed = true; parameterSets[type] = unit }
            } else {
                hasPicture = hasPicture || type <= 31
                var size = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &size) { payload.append(contentsOf: $0) }; payload.append(unit)
            }
        }
        if !hasPicture { return 0 }
        if changed || session == nil { guard createSession() else { return -1 } }
        guard let session, let format else { return -1 }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return -1 }
        guard payload.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }) == noErr else { return -1 }
        var sample: CMSampleBuffer?, size = payload.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(image.timeStamp), timescale: 90000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return -1 }
        let context = Unmanaged.passRetained(HEVCDecodeFrame(self, image: image))
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: context.toOpaque(), infoFlagsOut: nil)
        if status != noErr { context.release(); return -1 }
        return 0
    }
    private func completed(_ frame: HEVCDecodeFrame, pixels: CVPixelBuffer) {
        lock.lock(); let callback = callback; lock.unlock()
        let decoded = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: frame.rotation, timeStampNs: frame.nanoseconds)
        decoded.timeStamp = Int32(bitPattern: frame.timestamp)
        callback?(decoded)
    }
    private func closeSession() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
    }
    func release() -> Int { closeSession(); parameterSets.removeAll(); return 0 }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
