import Foundation
import RemoteCore

/// Computes interval statistics, never lifetime averages or deltas across an SSRC reset.
public struct DesktopStreamMetrics {
    private var previous: [String: [String: String]] = [:]
    public init() {}
    public mutating func sample(_ statistics: [[String: String]]) -> DesktopStreamSample {
        var result = DesktopStreamSample()
        let videoTransportID = statistics.first { $0["type"] == "outbound-rtp" && ($0["kind"] == "video" || $0["mediaType"] == "video") }?["transportId"]
        let transport = statistics.first { $0["type"] == "transport" && $0["id"] == videoTransportID }
        let selected = transport?["selectedCandidatePairId"] ?? statistics.filter {
            $0["type"] == "candidate-pair" && $0["state"] == "succeeded" && ["true", "1"].contains($0["nominated"] ?? "")
        }.max {
            if ($0["availableOutgoingBitrate"] != nil) != ($1["availableOutgoingBitrate"] != nil) { return $0["availableOutgoingBitrate"] == nil }
            return (Double($0["bytesSent"] ?? "0") ?? 0) < (Double($1["bytesSent"] ?? "0") ?? 0)
        }?["id"]
        var next: [String: [String: String]] = [:]
        for stat in statistics {
            let id = stat["id"] ?? ""
            let old = previous[id]
            next[id] = stat
            func number(_ key: String) -> Double? {
                stat[key].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            func delta(_ key: String) -> Double? {
                guard let current = number(key), let before = old?[key].flatMap(Double.init), current >= before else { return nil }
                return current - before
            }
            if stat["type"] == "candidate-pair", stat["id"] == selected {
                result.roundTripSeconds = number("currentRoundTripTime")
                result.availableBitrate = number("availableOutgoingBitrate")
            }
            if stat["type"] == "outbound-rtp", stat["kind"] == "video" || stat["mediaType"] == "video" {
                result.limitation = stat["qualityLimitationReason"]
                if let frames = delta("framesEncoded"), frames > 0 {
                    result.encodeMilliseconds = delta("totalEncodeTime").map { $0 * 1000 / frames }
                }
                if let packets = delta("packetsSent"), packets > 0 {
                    result.sendDelayMilliseconds = delta("totalPacketSendDelay").map { $0 * 1000 / packets }
                }
            }
            if stat["type"] == "remote-inbound-rtp", stat["kind"] == "video" || stat["mediaType"] == "video" {
                result.lossRatio = number("fractionLost")
                if result.roundTripSeconds == nil { result.roundTripSeconds = number("roundTripTime") }
            }
            if stat["type"] == "inbound-rtp", stat["kind"] == "video" || stat["mediaType"] == "video" {
                if let frames = delta("framesDecoded"), frames > 0 {
                    result.decodeMilliseconds = delta("totalDecodeTime").map { $0 * 1000 / frames }
                    if let dropped = delta("framesDropped") { result.droppedFrameRatio = dropped / (frames + dropped) }
                }
            }
        }
        previous = next
        return result
    }
}
