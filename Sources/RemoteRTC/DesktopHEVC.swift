import Foundation
import VideoToolbox
import WebRTC

public struct DesktopHEVCCapability: Codable, Sendable {
    public let hardwareEncoder: Bool
    public let hardwareDecoder: Bool
    public let hardwareRoundTrip: Bool
    public let rtcEncoder: Bool
    public let rtcDecoder: Bool
    public let adapterRoundTrip: Bool
    public var available: Bool { hardwareRoundTrip && rtcEncoder && rtcDecoder && adapterRoundTrip }
    public var diagnostics: [String: Bool] {
        ["hardwareEncoder": hardwareEncoder, "hardwareDecoder": hardwareDecoder,
         "hardwareRoundTrip": hardwareRoundTrip, "rtcEncoder": rtcEncoder, "rtcDecoder": rtcDecoder, "adapterRoundTrip": adapterRoundTrip, "available": available]
    }
}

private final class HEVCProbeOutput {
    let encoded = DispatchSemaphore(value: 0)
    let decoded = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var sample: CMSampleBuffer?
    var decodedFrame = false
}

/// Uses synthetic pixels only. Requiring hardware on both sessions prevents a
/// software fallback from being mistaken for an available low-latency codec.
public enum DesktopHEVC {
    public static let capability = Task.detached(priority: .utility) { probe() }
    private static func probe() -> DesktopHEVCCapability {
        let defaultEncoder = DesktopEncoderFactory(hevc: true)
        let defaultDecoder = DesktopDecoderFactory(hevc: true)
        let enc = defaultEncoder.supportedCodecs().first { $0.name.uppercased() == "H265" }
        let dec = defaultDecoder.supportedCodecs().first { $0.name.uppercased() == "H265" }
        let rtcEncoder = enc.flatMap { defaultEncoder.createEncoder($0) } != nil
        let rtcDecoder = dec.flatMap { defaultDecoder.createDecoder($0) } != nil
        var hardwareEncoder = false, hardwareDecoder = false, roundTrip = false
        let context = HEVCProbeOutput()
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var encoder: VTCompressionSession?
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 256, height: 144,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { refcon, _, status, _, sample in
                guard let refcon else { return }
                let context = Unmanaged<HEVCProbeOutput>.fromOpaque(refcon).takeUnretainedValue()
                context.lock.lock(); if status == noErr { context.sample = sample }; context.lock.unlock()
                context.encoded.signal()
            }, refcon: refcon, compressionSessionOut: &encoder)
        if result == noErr, let encoder {
            defer { VTCompressionSessionInvalidate(encoder) }
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            var hardware: Unmanaged<CFTypeRef>?
            VTSessionCopyProperty(encoder, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: kCFAllocatorDefault, valueOut: &hardware)
            hardwareEncoder = (hardware?.takeRetainedValue() as? Bool) == true
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 256, 144, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
            if let pixels {
                CVPixelBufferLockBaseAddress(pixels, [])
                if let address = CVPixelBufferGetBaseAddress(pixels) {
                    memset(address, 96, CVPixelBufferGetBytesPerRow(pixels) * 144)
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels,
                    presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 30),
                    frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                    sourceFrameRefcon: nil, infoFlagsOut: nil)
                VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                if status == noErr, context.encoded.wait(timeout: .now() + 3) == .success {
                    context.lock.lock(); let sample = context.sample; context.lock.unlock()
                    if let sample, let format = CMSampleBufferGetFormatDescription(sample) {
                        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                            guard let refcon else { return }
                            let context = Unmanaged<HEVCProbeOutput>.fromOpaque(refcon).takeUnretainedValue()
                            context.lock.lock()
                            context.decodedFrame = status == noErr && image.map { CVPixelBufferGetWidth($0) == 256 && CVPixelBufferGetHeight($0) == 144 } == true
                            context.lock.unlock(); context.decoded.signal()
                        }, decompressionOutputRefCon: refcon)
                        var decoder: VTDecompressionSession?
                        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                            imageBufferAttributes: nil, outputCallback: &callback, decompressionSessionOut: &decoder)
                        if status == noErr, let decoder {
                            defer { VTDecompressionSessionInvalidate(decoder) }
                            var hardware: Unmanaged<CFTypeRef>?
                            VTSessionCopyProperty(decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                                  allocator: kCFAllocatorDefault, valueOut: &hardware)
                            hardwareDecoder = (hardware?.takeRetainedValue() as? Bool) == true
                            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
                            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
                            if status == noErr, context.decoded.wait(timeout: .now() + 3) == .success {
                                context.lock.lock(); roundTrip = hardwareEncoder && hardwareDecoder && context.decodedFrame; context.lock.unlock()
                            }
                        }
                    }
                }
            }
        }
        withExtendedLifetime(context) {}
        return DesktopHEVCCapability(hardwareEncoder: hardwareEncoder, hardwareDecoder: hardwareDecoder,
            hardwareRoundTrip: roundTrip, rtcEncoder: rtcEncoder, rtcDecoder: rtcDecoder,
            adapterRoundTrip: roundTrip && probeAdapters())
    }
    /// Validate our complete adapters at the largest advertised desktop size, not just VT session creation.
    private static func probeAdapters() -> Bool {
        let encoder = DesktopHEVCEncoder(), decoder = DesktopHEVCDecoder()
        defer { _ = encoder.release(); _ = decoder.release() }
        let context = HEVCProbeOutput()
        decoder.setCallback { frame in
            context.lock.lock(); context.decodedFrame = frame.width == 3840 && frame.height == 2160; context.lock.unlock()
            context.decoded.signal()
        }
        encoder.setCallback { image, _ in
            let status = decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0)
            context.encoded.signal()
            return status == 0
        }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H265"; settings.width = 3840; settings.height = 2160
        settings.maxFramerate = 30; settings.startBitrate = 8000
        guard encoder.startEncode(with: settings, numberOfCores: 2) == 0 else { return false }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else { return false }
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
            if let address = CVPixelBufferGetBaseAddressOfPlane(pixels, plane) {
                memset(address, plane == 0 ? 96 : 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 1_000_000_000)
        frame.timeStamp = 90000
        guard encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]) == 0,
              context.encoded.wait(timeout: .now() + 3) == .success,
              context.decoded.wait(timeout: .now() + 3) == .success else { return false }
        context.lock.lock(); let success = context.decodedFrame; context.lock.unlock()
        return success
    }

}
