import Foundation
import VideoToolbox
import WebRTC

/// Upstream's macOS Objective-C factory advertises level 3.1 unconditionally.
/// That limit is too small for a Retina desktop and VT can silently emit no frames.
/// Probe the hardware encoder, advertise its desktop profile, and still respect the
/// level negotiated with the receiver when sizing capture frames.
enum DesktopH264 {
    static let maximumLevel: String = {
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 3840, height: 2160,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { return "1f" }
        defer { VTCompressionSessionInvalidate(session) }
        let supported = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_5_2)
        return supported == noErr ? "34" : "1f"
    }()
    static var codecs: [RTCVideoCodecInfo] {
        ["640c", "42e0"].map { prefix in
            RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": prefix + maximumLevel,
                "packetization-mode": "1", "level-asymmetry-allowed": "1"])
        }
    }
}
final class DesktopEncoderFactory: NSObject, RTCVideoEncoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { DesktopH264.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard info.name == "H264" else { return nil }
        return RTCVideoEncoderH264(codecInfo: info)
    }
}
final class DesktopDecoderFactory: NSObject, RTCVideoDecoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { DesktopH264.codecs }
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? { info.name == "H264" ? RTCVideoDecoderH264() : nil }
}

public struct H264CaptureLimit: Sendable {
    public let frameMacroblocks: Int
    public let macroblocksPerSecond: Int
    public init(level: Int) {
        switch level {
        case 52...: frameMacroblocks = 36864; macroblocksPerSecond = 2073600
        case 51: frameMacroblocks = 36864; macroblocksPerSecond = 983040
        case 50: frameMacroblocks = 22080; macroblocksPerSecond = 589824
        case 42: frameMacroblocks = 8704; macroblocksPerSecond = 522240
        case 40...41: frameMacroblocks = 8192; macroblocksPerSecond = 245760
        case 32: frameMacroblocks = 5120; macroblocksPerSecond = 216000
        default: frameMacroblocks = 3600; macroblocksPerSecond = 108000
        }
    }
    public func dimensions(width: Int, height: Int, quality: DesktopQuality) -> (width: Int, height: Int, fps: Int) {
        let landscape = width >= height
        let maxWidth = landscape ? quality.maximumWidth : quality.maximumHeight
        let maxHeight = landscape ? quality.maximumHeight : quality.maximumWidth
        var scale = min(1, Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        var w = max(2, Int(Double(width) * scale) / 2 * 2)
        var h = max(2, Int(Double(height) * scale) / 2 * 2)
        func macroblocks() -> Int { ((w + 15) / 16) * ((h + 15) / 16) }
        while macroblocks() > frameMacroblocks {
            scale *= 0.97
            w = max(2, Int(Double(width) * scale) / 2 * 2)
            h = max(2, Int(Double(height) * scale) / 2 * 2)
        }
        return (w, h, max(1, min(quality.fps, macroblocksPerSecond / macroblocks())))
    }
}
