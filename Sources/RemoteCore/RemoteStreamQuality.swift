import Foundation

public enum RemoteStreamPreference: String, Codable, CaseIterable, Sendable {
    case automatic, text, motion
}

/// Optional fields preserve interoperability with older controllers and hosts.
public struct RemoteStreamFeedback: Codable, Sendable {
    public var lossless: Bool?
    public var preference: RemoteStreamPreference?
    public var viewportWidth: Int?
    public var viewportHeight: Int?
    public var decodeMilliseconds: Double?
    public var droppedFrameRatio: Double?
    public init(preference: RemoteStreamPreference? = nil, lossless: Bool? = nil, viewportWidth: Int? = nil, viewportHeight: Int? = nil,
                decodeMilliseconds: Double? = nil, droppedFrameRatio: Double? = nil) {
        self.lossless = lossless
        self.preference = preference; self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.decodeMilliseconds = decodeMilliseconds; self.droppedFrameRatio = droppedFrameRatio
    }
    public var isValid: Bool {
        (viewportWidth.map { (1...16384).contains($0) } ?? true) &&
        (viewportHeight.map { (1...16384).contains($0) } ?? true) &&
        (decodeMilliseconds.map { $0.isFinite && (0...10000).contains($0) } ?? true) &&
        (droppedFrameRatio.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
}

public struct DesktopStreamSample: Codable, Sendable {
    public var roundTripSeconds: Double?
    public var availableBitrate: Double?
    public var lossRatio: Double?
    public var encodeMilliseconds: Double?
    public var sendDelayMilliseconds: Double?
    public var decodeMilliseconds: Double?
    public var droppedFrameRatio: Double?
    public var limitation: String?
    public init(roundTripSeconds: Double? = nil, availableBitrate: Double? = nil, lossRatio: Double? = nil,
                encodeMilliseconds: Double? = nil, sendDelayMilliseconds: Double? = nil,
                decodeMilliseconds: Double? = nil, droppedFrameRatio: Double? = nil, limitation: String? = nil) {
        self.roundTripSeconds = roundTripSeconds; self.availableBitrate = availableBitrate; self.lossRatio = lossRatio
        self.encodeMilliseconds = encodeMilliseconds; self.sendDelayMilliseconds = sendDelayMilliseconds
        self.decodeMilliseconds = decodeMilliseconds; self.droppedFrameRatio = droppedFrameRatio; self.limitation = limitation
    }
}

public struct DesktopStreamDecision: Codable, Equatable, Sendable {
    public var state: String
    public var reason: String
    public var tier: Int
    public var width: Int
    public var height: Int
    public var fps: Int
    public var maximumBitrate: Int
    public var refinement: Bool
}

/// The application selects workload; libwebrtc remains the only congestion controller.
/// All deadlines use host monotonic time. Missing statistics never imply congestion.
public struct DesktopQualityController: Sendable {
    public private(set) var tier = 0
    public private(set) var preference: RemoteStreamPreference = .automatic
    private var pressureSince: Double?
    private var healthySince: Double?
    private var lastChange = -Double.infinity
    private var minimumRTT: Double?
    private var lastTime: Double?
    private var reason = "healthy"
    public init() {}
    public mutating func setPreference(_ preference: RemoteStreamPreference) { self.preference = preference }
    public mutating func reset() { self = Self() }

    public mutating func update(now: Double, sample: DesktopStreamSample, moving: Bool,
                                baseWidth: Int, baseHeight: Int, baseFPS: Int, maximumBitrate: Int,
                                viewportWidth: Int? = nil, viewportHeight: Int? = nil,
                                refining: Bool = false) -> DesktopStreamDecision {
        if let lastTime, now < lastTime { reset() }
        lastTime = now
        let fps = max(1, baseFPS)
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        if let rtt = finite(sample.roundTripSeconds), rtt > 0 { minimumRTT = min(minimumRTT ?? rtt, rtt) }
        var viewportScale = 1.0
        if preference == .automatic, let viewportWidth, let viewportHeight, viewportWidth > 0, viewportHeight > 0 {
            viewportScale = min(1, Double(viewportWidth) / Double(max(2, baseWidth)), Double(viewportHeight) / Double(max(2, baseHeight)))
            viewportScale = max(viewportScale, min(1, 640 / Double(max(2, min(baseWidth, baseHeight)))))
        }
        let workloadBudget = Double(maximumBitrate) * viewportScale * viewportScale
        let bandwidthPressure = moving && sample.limitation == "bandwidth" &&
            (finite(sample.availableBitrate).map { $0 < workloadBudget * 0.25 * pow(0.6, Double(tier)) } ?? true)
        let network = (finite(sample.lossRatio) ?? 0) > 0.03 ||
            (finite(sample.sendDelayMilliseconds) ?? 0) > 100 ||
            (finite(sample.roundTripSeconds) ?? 0) > max(0.15, (minimumRTT ?? 0.05) + 0.08) ||
            bandwidthPressure
        let device = moving && ((finite(sample.encodeMilliseconds) ?? 0) > 1000 / Double(fps) * 0.85 ||
            (finite(sample.decodeMilliseconds) ?? 0) > 1000 / Double(fps) * 0.85 ||
            (finite(sample.droppedFrameRatio) ?? 0) > 0.1 || sample.limitation == "cpu")
        let observed = sample.roundTripSeconds != nil || sample.lossRatio != nil || sample.encodeMilliseconds != nil
        if network || device {
            healthySince = nil
            if pressureSince == nil { pressureSince = now }
            reason = device ? "device" : "network"
            if now - (pressureSince ?? now) >= 2, now - lastChange >= 3, tier < 4 {
                tier += 1; lastChange = now; pressureSince = now
            }
        } else {
            pressureSince = nil
            // A low bitrate on a static desktop is normal. Recovery needs measured health,
            // and a bandwidth-limited sender must not oscillate between adjacent tiers.
            let needed = workloadBudget * pow(0.6, Double(max(0, tier - 1))) * 0.25
            let headroom = sample.availableBitrate.map { $0.isFinite && $0 >= needed } ?? moving
            if observed && headroom {
                if healthySince == nil { healthySince = now }
                if tier > 0, now - (healthySince ?? now) >= 6, now - lastChange >= 6 {
                    tier -= 1; lastChange = now; healthySince = now
                }
            } else { healthySince = nil }
            if tier == 0 { reason = "healthy" } else if observed && headroom { reason = "recovering" }
        }
        var scale = viewportScale
        let reduction = preference == .motion ? max(0, tier - 1) : max(0, tier - 2)
        scale *= pow(0.75, Double(reduction))
        let width = max(2, Int(Double(baseWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(baseHeight) * scale) / 2 * 2)
        let targetFPS = max(1, min(fps, tier == 0 ? fps : tier == 1 ? max(15, fps * 2 / 3) : 15))
        let allowedRefinement = refining && tier == 0 && !network && !device
        return DesktopStreamDecision(state: tier > 0 || network || device ? "limited" : allowedRefinement ? "refining" : moving ? "interactive" : "idle",
            reason: reason, tier: tier, width: width, height: height, fps: targetFPS,
            maximumBitrate: maximumBitrate, refinement: allowedRefinement)
    }
}

/// A short refinement window follows content changes; steady state costs one refresh per second.
public struct DesktopFrameCadence: Sendable {
    public private(set) var lastContentChange = -Double.infinity
    public private(set) var lastSubmission = -Double.infinity
    public private(set) var refinementFrames = 0
    public init() {}
    public mutating func contentChanged(now: Double) { lastContentChange = now; refinementFrames = 0 }
    public func isMoving(now: Double) -> Bool { now - lastContentChange < 0.35 }
    public func isRefining(now: Double) -> Bool { (0.35...1.35).contains(now - lastContentChange) && refinementFrames < 12 }
    public func shouldRepeat(now: Double, refinementAllowed: Bool) -> Bool {
        if refinementAllowed && isRefining(now: now) { return now - lastSubmission >= 0.075 }
        return now - lastSubmission >= 1
    }
    public mutating func submitted(now: Double, repeated: Bool) {
        lastSubmission = now
        if repeated && isRefining(now: now) { refinementFrames += 1 }
    }
}
