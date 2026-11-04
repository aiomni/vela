import Foundation
import ImageIO
import WebRTC

public struct DesktopLosslessTile {
    public let x: Int
    public let y: Int
    public let image: CGImage
}

@MainActor
public final class DesktopLosslessReceiver {
    private struct Assembly { var time: Double; var count: Int; var chunks: [Int: Data] = [:] }
    private var markers: [UInt32: DesktopFrameMarker] = [:]
    private var parts: [String: Assembly] = [:]
    private var tiles: [String: DesktopLosslessTile] = [:]
    private var frame: (UInt32, Int, Int)?
    private var current: DesktopFrameMarker?
    public var onChange: (([DesktopLosslessTile], Int, Int) -> Void)?
    public init() {}
    public func reset() {
        markers.removeAll(); parts.removeAll(); tiles.removeAll(); frame = nil; current = nil
        onChange?([], 0, 0)
    }
    public func marker(_ marker: DesktopFrameMarker) {
        if markers.count >= 128 { markers.removeAll() }
        markers[marker.rtpTimestamp] = marker
        if frame?.0 == marker.rtpTimestamp { select() }
    }
    public func present(timestamp: UInt32, width: Int, height: Int) {
        frame = (timestamp, width, height); select()
    }
    private func sameScene(_ a: DesktopFrameMarker, _ b: DesktopFrameMarker) -> Bool {
        a.epoch == b.epoch && a.version == b.version && a.width == b.width && a.height == b.height
    }
    private func select() {
        let next = frame.flatMap { markers[$0.0] }
        if let current, next.map({ sameScene(current, $0) }) != true { tiles.removeAll(); parts.removeAll() }
        current = next
        guard let frame, let next, frame.1 == next.width, frame.2 == next.height else {
            current = nil; onChange?([], 0, 0); return
        }
        onChange?(Array(tiles.values), next.width, next.height)
    }
    public func receive(_ data: Data) {
        guard data.count <= 16384, let packet = try? JSONDecoder().decode(DesktopLosslessChunk.self, from: data),
              packet.type == "tile", let current, packet.epoch == current.epoch, packet.version == current.version,
              packet.width == current.width, packet.height == current.height,
              (2...3840).contains(packet.width), (2...3840).contains(packet.height), packet.width * packet.height <= 3840 * 2160,
              (1...512).contains(packet.tileWidth), (1...512).contains(packet.tileHeight), packet.x >= 0, packet.y >= 0,
              packet.x <= packet.width - packet.tileWidth, packet.y <= packet.height - packet.tileHeight,
              (1...16).contains(packet.count), (0..<packet.count).contains(packet.part), packet.data.count <= 8192 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        parts = parts.filter { now - $0.value.time < 3 }
        let key = "\(packet.x):\(packet.y):\(packet.tileWidth):\(packet.tileHeight)"
        guard tiles[key] == nil, parts[key] != nil || parts.count < 32 else { return }
        var assembly = parts[key] ?? Assembly(time: now, count: packet.count)
        guard assembly.count == packet.count, assembly.chunks[packet.part] == nil else { return }
        assembly.chunks[packet.part] = packet.data
        parts[key] = assembly
        guard assembly.chunks.count == assembly.count else { return }
        parts.removeValue(forKey: key)
        var png = Data()
        for index in 0..<assembly.count { if let chunk = assembly.chunks[index] { png.append(chunk) } }
        guard png.count <= 131072, png.starts(with: [137,80,78,71,13,10,26,10]), let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == packet.tileWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == packet.tileHeight,
              tiles.count < 64, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        tiles[key] = DesktopLosslessTile(x: packet.x, y: packet.y, image: image)
        onChange?(Array(tiles.values), current.width, current.height)
    }
}

public struct DesktopDecodedFrame: @unchecked Sendable {
    public let timestamp: UInt32
    public let width: Int
    public let height: Int
    public let pixels: CVPixelBuffer?
}

/// The marker and displayed frame use the receiver's RTP clock, after transport offset.
public final class DesktopIdentityRenderer: NSObject, RTCVideoRenderer {
    private let target: RTCVideoRenderer
    private let lock = NSLock()
    private var identityEnabled = false
    public func setIdentityEnabled(_ enabled: Bool) { lock.lock(); identityEnabled = enabled; lock.unlock() }
    private let present: @Sendable (DesktopDecodedFrame) -> Void
    public init(target: RTCVideoRenderer, present: @escaping @Sendable (DesktopDecodedFrame) -> Void) {
        self.target = target; self.present = present
    }
    public func setSize(_ size: CGSize) { target.setSize(size) }
    public func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock(); let enabled = identityEnabled; lock.unlock()
        if enabled, let frame {
            present(DesktopDecodedFrame(timestamp: UInt32(bitPattern: frame.timeStamp), width: Int(frame.width), height: Int(frame.height),
                pixels: (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer))
        }
        target.renderFrame(frame)
    }
}
