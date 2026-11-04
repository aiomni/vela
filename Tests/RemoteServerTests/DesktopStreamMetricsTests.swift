import XCTest
import RemoteCore
import RemoteRTC
import CoreGraphics
import ImageIO

final class DesktopStreamMetricsTests: XCTestCase {
    func testMetricsUseIntervalsAndRejectResetCounters() {
        var metrics = DesktopStreamMetrics()
        func frame(_ count: Int, _ seconds: Double) -> [[String: String]] {
            [["id": "video", "type": "outbound-rtp", "kind": "video", "framesEncoded": "\(count)", "totalEncodeTime": "\(seconds)"]]
        }
        XCTAssertNil(metrics.sample(frame(100, 2)).encodeMilliseconds)
        XCTAssertEqual(metrics.sample(frame(110, 2.1)).encodeMilliseconds ?? -1, 10, accuracy: 0.001)
        XCTAssertNil(metrics.sample(frame(1, 0.02)).encodeMilliseconds)
    }
    func testOnlyTheSelectedPairSuppliesBandwidth() {
        var metrics = DesktopStreamMetrics()
        let sample = metrics.sample([
            ["id": "old", "type": "candidate-pair", "state": "succeeded", "nominated": "false", "availableOutgoingBitrate": "1"],
            ["id": "active", "type": "candidate-pair", "state": "succeeded", "nominated": "true", "availableOutgoingBitrate": "20000000", "currentRoundTripTime": "0.02"],
            ["id": "other", "type": "candidate-pair", "state": "succeeded", "nominated": "1", "bytesSent": "10"]
        ])
        XCTAssertEqual(sample.availableBitrate, 20_000_000)
        XCTAssertEqual(sample.roundTripSeconds, 0.02)
    }
    func testVideoTransportSelectsItsPairRatherThanAnUnrelatedNominatedPair() {
        var metrics = DesktopStreamMetrics()
        let sample = metrics.sample([
            ["id": "video", "type": "outbound-rtp", "kind": "video", "transportId": "transport"],
            ["id": "transport", "type": "transport", "selectedCandidatePairId": "video-pair"],
            ["id": "video-pair", "type": "candidate-pair", "state": "succeeded", "nominated": "1", "availableOutgoingBitrate": "10000000"],
            ["id": "other-pair", "type": "candidate-pair", "state": "succeeded", "nominated": "1", "availableOutgoingBitrate": "500000000"]
        ])
        XCTAssertEqual(sample.availableBitrate, 10_000_000)
    }
    @MainActor
    func testNativeLosslessReceiverRejectsOldVersionsAndClearsOnUnmatchedFrames() throws {
        let receiver = DesktopLosslessReceiver()
        var visibleCount = 0
        receiver.onChange = { tiles, _, _ in visibleCount = tiles.count }
        var marker = DesktopFrameMarker(epoch: "fixture", version: 1, width: 1280, height: 720)
        marker.rtpTimestamp = 123
        receiver.marker(marker); receiver.present(timestamp: 123, width: 1280, height: 720)
        let bytes = Data(repeating: 100, count: 16)
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        func packet(version: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "tile", "epoch": "fixture", "version": version,
                "width": 1280, "height": 720, "x": 0, "y": 0, "tileWidth": 2, "tileHeight": 2,
                "part": 0, "count": 1, "data": (data as Data).base64EncodedString()])
        }
        receiver.receive(try packet(version: 2)); XCTAssertEqual(visibleCount, 0)
        receiver.receive(try packet(version: 1)); XCTAssertEqual(visibleCount, 1)
        receiver.present(timestamp: 124, width: 1280, height: 720); XCTAssertEqual(visibleCount, 0)
        receiver.receive(try packet(version: 1)); XCTAssertEqual(visibleCount, 0)
        receiver.reset(); XCTAssertEqual(visibleCount, 0)
    }
    func testInBandIdentitySurvivesEscapingAndUsesReceivedRTPClock() {
        let marker = DesktopFrameMarker(epoch: "fixture", version: 37, width: 1920, height: 1080)
        let stream = DesktopH264Identity.sei(marker) + Data([0,0,0,1,101,1,2,3])
        let decoded = DesktopH264Identity.marker(in: stream, rtpTimestamp: 0xfffffff0)
        XCTAssertEqual(decoded?.version, 37)
        XCTAssertEqual(decoded?.rtpTimestamp, 0xfffffff0)
        XCTAssertNil(DesktopH264Identity.marker(in: Data([0,0,0,1,6,5,255]), rtpTimestamp: 1))
    }
    func testHEVCRequiresHardwareRoundTripAndBothRTCAdapters() async throws {
        let result = await DesktopHEVC.capability.value
        XCTAssertEqual(result.available, result.hardwareRoundTrip && result.rtcEncoder && result.rtcDecoder && result.adapterRoundTrip)
        XCTAssertFalse(result.hardwareRoundTrip && (!result.hardwareEncoder || !result.hardwareDecoder))
        if result.hardwareRoundTrip { XCTAssertTrue(result.adapterRoundTrip, "Hardware availability must validate the actual 4K RTC adapters") }
        if let path = ProcessInfo.processInfo.environment["VELA_CODEC_PROBE_OUTPUT"] {
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: path))
        }
        print("HEVC synthetic probe: hardwareEncoder=\(result.hardwareEncoder), hardwareDecoder=\(result.hardwareDecoder), roundTrip=\(result.hardwareRoundTrip), rtcEncoder=\(result.rtcEncoder), rtcDecoder=\(result.rtcDecoder)")
    }
}
