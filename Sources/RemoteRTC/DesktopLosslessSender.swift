import Foundation

public struct DesktopLosslessChunk: Codable, Sendable {
    public var type = "tile"
    public let epoch: String
    public let version: Int
    public let width: Int
    public let height: Int
    public let x: Int
    public let y: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let part: Int
    public let count: Int
    public let data: Data
}

/// Enhancement is opt-in and subordinate to interactive video and control.
/// Small messages and a token budget bound competition on the shared SCTP transport.
@MainActor
public final class DesktopLosslessSender {
    private weak var peer: RemotePeer?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var packets: [Data] = []
    private var offset = 0
    private var deadline = 0.0
    private var tokens = 0.0
    private var rate = 0.0
    private var lastRefill = 0.0
    private var requested: DesktopFrameMarker?
    private var generation = UUID()
    public init() {}
    public func stop() {
        generation = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        peer?.frameIdentity.observe(nil); peer = nil
        packets.removeAll(); offset = 0; requested = nil; tokens = 0; rate = 0
    }
    public func update(capture: DesktopCapture, peer: RemotePeer, enabled: Bool, availableBitrate: Double?) {
        guard enabled, peer.enhancementReady, let bandwidth = availableBitrate, bandwidth.isFinite, bandwidth >= 3_000_000 else { stop(); return }
        if self.peer !== peer {
            stop(); self.peer = peer
            peer.frameIdentity.observe { _ in } // Enables in-band frame identities; no guessed RTP timestamps.
            lastRefill = ProcessInfo.processInfo.systemUptime
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
        }
        rate = min(250_000, bandwidth * 0.1 / 8)
        guard let marker = capture.losslessMarker else { return }
        if let requested, requested != marker {
            generation = UUID()
            task?.cancel(); task = nil; packets.removeAll(); offset = 0; self.requested = nil
        }
        guard task == nil, packets.isEmpty, requested == nil else { return }
        let generation = self.generation
        requested = marker
        task = Task { [weak self, weak peer] in
            let chunks = await capture.losslessTiles()
            guard let self, let peer, !Task.isCancelled, self.generation == generation, self.peer === peer else { return }
            self.task = nil
            guard !chunks.isEmpty, capture.losslessMarker == marker else { self.requested = nil; return }
            self.requested = marker
            self.packets = chunks.compactMap { try? JSONEncoder().encode($0) }
            self.offset = 0; self.deadline = ProcessInfo.processInfo.systemUptime + 5
        }
    }
    private func flush() {
        let now = ProcessInfo.processInfo.systemUptime
        tokens = min(max(16384, rate * 0.2), tokens + max(0, now - lastRefill) * rate); lastRefill = now
        guard now < deadline, let peer else { packets.removeAll(); offset = 0; return }
        while offset < packets.count, Double(packets[offset].count) <= tokens {
            guard peer.sendEnhancement(packets[offset]) else { return }
            tokens -= Double(packets[offset].count); offset += 1
        }
        if offset == packets.count { packets.removeAll(); offset = 0 }
    }
}
