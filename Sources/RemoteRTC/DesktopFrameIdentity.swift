import Foundation
import WebRTC

public struct DesktopFrameMarker: Codable, Equatable, Sendable {
    public var type = "frame"
    public let epoch: String
    public let version: Int
    public let width: Int
    public let height: Int
    public var rtpTimestamp: UInt32 = 0
    public init(epoch: String, version: Int, width: Int, height: Int) {
        self.epoch = epoch; self.version = version; self.width = width; self.height = height
    }
}

/// Maps the capture clock to the actual RTP timestamp assigned by libwebrtc.
/// A bounded table also prevents delayed encoder callbacks reviving an old epoch.
public final class DesktopFrameIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [Int64: DesktopFrameMarker] = [:]
    private var encodedFrames: [UInt32: DesktopFrameMarker] = [:]
    private var callback: (@Sendable (DesktopFrameMarker) -> Void)?
    public init() {}
    public func observe(_ callback: (@Sendable (DesktopFrameMarker) -> Void)?) {
        lock.lock(); self.callback = callback; captures.removeAll(); encodedFrames.removeAll(); lock.unlock()
    }
    public func reset() { lock.lock(); captures.removeAll(); encodedFrames.removeAll(); lock.unlock() }
    public func capture(nanoseconds: Int64, marker: DesktopFrameMarker) {
        lock.lock(); defer { lock.unlock() }
        guard callback != nil else { return }
        captures[nanoseconds / 1_000_000] = marker
        if captures.count > 64, let oldest = captures.keys.min() { captures.removeValue(forKey: oldest) }
    }
    func encoding(_ frame: RTCVideoFrame) {
        lock.lock(); defer { lock.unlock() }
        guard var marker = captures[frame.timeStampNs / 1_000_000], marker.width == frame.width, marker.height == frame.height else { return }
        marker.rtpTimestamp = UInt32(bitPattern: frame.timeStamp)
        encodedFrames[marker.rtpTimestamp] = marker
        if encodedFrames.count > 64 { encodedFrames.removeAll(); encodedFrames[marker.rtpTimestamp] = marker }
    }
    func encoded(_ timestamp: UInt32, width: Int32, height: Int32) -> DesktopFrameMarker? {
        lock.lock(); let marker = encodedFrames.removeValue(forKey: timestamp); let callback = self.callback; lock.unlock()
        if let marker, marker.width == width, marker.height == height { callback?(marker); return marker }
        return nil
    }
    func received(_ data: Data, timestamp: UInt32) {
        lock.lock(); let callback = self.callback; lock.unlock()
        guard callback != nil, let marker = DesktopH264Identity.marker(in: data, rtpTimestamp: timestamp) else { return }
        callback?(marker)
    }
}

final class DesktopTrackedEncoder: NSObject, RTCVideoEncoder {
    let encoder: RTCVideoEncoder
    let identity: DesktopFrameIdentity
    init(_ encoder: RTCVideoEncoder, identity: DesktopFrameIdentity) { self.encoder = encoder; self.identity = identity }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        encoder.setCallback(callback.map { callback in { [identity] image, info in
            if let marker = identity.encoded(image.timeStamp, width: image.encodedWidth, height: image.encodedHeight) {
                image.buffer = DesktopH264Identity.sei(marker) + image.buffer
            }
            return callback(image, info)
        } })
    }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        encoder.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func release() -> Int { encoder.release() }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        identity.encoding(frame)
        return encoder.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { encoder.setBitrate(bitrateKbit, framerate: framerate) }
    func implementationName() -> String { encoder.implementationName() }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { encoder.scalingSettings() }
    var resolutionAlignment: Int { encoder.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { encoder.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { encoder.supportsNativeHandle }
}
