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
    let hevc: Bool
    let identity: DesktopFrameIdentity?
    init(hevc: Bool = false, identity: DesktopFrameIdentity? = nil) { self.hevc = hevc; self.identity = identity }
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        (hevc ? [DesktopHEVCFormat.info] : []) + DesktopH264.codecs
    }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        if hevc && info.name.uppercased() == "H265" { return DesktopHEVCFormat.accepts(info) ? DesktopHEVCEncoder(info: info) : nil }
        guard info.name == "H264" else { return nil }
        let encoder = RTCVideoEncoderH264(codecInfo: info)
        return identity.map { DesktopTrackedEncoder(encoder, identity: $0) } ?? encoder
    }
}
final class DesktopDecoderFactory: NSObject, RTCVideoDecoderFactory {
    let hevc: Bool
    let identity: DesktopFrameIdentity?
    init(hevc: Bool = false, identity: DesktopFrameIdentity? = nil) { self.hevc = hevc; self.identity = identity }
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        (hevc ? [DesktopHEVCFormat.info] : []) + DesktopH264.codecs
    }
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        if hevc && info.name.uppercased() == "H265" { return DesktopHEVCFormat.accepts(info) ? DesktopHEVCDecoder() : nil }
        guard info.name == "H264" else { return nil }
        let decoder = RTCVideoDecoderH264()
        return identity.map { DesktopTrackedDecoder(decoder, identity: $0) } ?? decoder
    }
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
    /// Conservative macroblock equivalents of the HEVC main-tier luma limits.
    public init(hevcLevel: Int) {
        let limits: (Int, Int)
        switch hevcLevel {
        case 156...: limits = (8912896, 1069547520)
        case 153: limits = (8912896, 534773760)
        case 150: limits = (8912896, 267386880)
        case 123: limits = (2228224, 133693440)
        case 120: limits = (2228224, 66846720)
        case 93: limits = (983040, 33177600)
        case 90: limits = (552960, 16588800)
        case 63: limits = (245760, 7372800)
        case 60: limits = (122880, 3686400)
        default: limits = (36864, 552960)
        }
        frameMacroblocks = limits.0 / 256; macroblocksPerSecond = limits.1 / 256
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
