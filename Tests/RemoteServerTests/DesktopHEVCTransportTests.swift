import XCTest
import Foundation
import CoreVideo
import WebRTC
import RemoteCore
@testable import RemoteRTC

final class DesktopHEVCTransportTests: XCTestCase {
    func testHardwareAdapterRoundTrip() async throws {
        let capability = await DesktopHEVC.capability.value
        guard capability.hardwareEncoder && capability.hardwareDecoder else { throw XCTSkip("Hardware HEVC is unavailable") }
        let encoder = DesktopHEVCEncoder(), decoder = DesktopHEVCDecoder()
        defer { _ = encoder.release(); _ = decoder.release() }
        let received = expectation(description: "direct hardware HEVC adapter round trip")
        let sink = HEVCFrameSink(expectation: received)
        decoder.setCallback { sink.renderFrame($0) }
        let report = HEVCAdapterReport()
        let decodedCall = expectation(description: "decoder call returned")
        encoder.setCallback { image, _ in
            report.recordEncoded(image.buffer)
            let status = decoder.decode(image, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0)
            report.recordDecode(status)
            decodedCall.fulfill()
            return status == 0
        }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H265"; settings.width = 1280; settings.height = 720
        settings.startBitrate = 4000; settings.maxFramerate = 30
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 4), 0, encoder.lastError ?? "")
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 96, CVPixelBufferGetBytesPerRow(buffer) * 720); CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1_000_000_000)
        frame.timeStamp = 90000
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]), 0)
        await fulfillment(of: [received, decodedCall], timeout: 5)
        XCTAssertGreaterThan(report.bytes, 0)
        XCTAssertEqual(report.decodeStatus, 0)
        XCTAssertEqual(sink.size.0, 1280)
    }
    @MainActor
    func testHardwareHEVCOverEncryptedWebRTCPeers() async throws {
        let capability = await DesktopHEVC.capability.value
        guard capability.hardwareEncoder && capability.hardwareDecoder else { throw XCTSkip("Hardware HEVC is unavailable") }
        XCTAssertTrue(capability.available)
        let host = try RemotePeer(sendingVideo: true, allowHEVC: true)
        let viewer = try RemotePeer(sendingVideo: false, allowHEVC: true)
        defer { host.close(); viewer.close() }
        let received = expectation(description: "hardware HEVC decoded through RTP")
        let control = expectation(description: "control remains responsive during HEVC")
        host.onInput = { data, pointer in
            if !pointer, (try? JSONDecoder().decode(RemoteInput.self, from: data).type) == "release" { control.fulfill() }
        }
        let sink = HEVCFrameSink(expectation: received)
        viewer.onVideo = { $0.add(sink) }
        let offer = try await viewer.makeOffer()
        XCTAssertTrue(offer.contains("H265/90000"))
        let answer = try await host.answer(offer: offer)
        XCTAssertEqual(host.videoCodec, "H265")
        try await viewer.accept(answer: answer)
        var hi = 0, vi = 0
        for _ in 0..<100 {
            let hc = host.localCandidates, vc = viewer.localCandidates
            for c in hc.dropFirst(hi) { try await viewer.add(c) }
            for c in vc.dropFirst(vi) { try await host.add(c) }
            hi = hc.count; vi = vc.count
            if host.connectionState == .connected && viewer.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(host.connectionState, .connected)
        let source = try XCTUnwrap(host.videoSource)
        source.adaptOutputFormat(toWidth: 3840, height: 2160, fps: 30)
        host.configureBitrate(maximum: 24_000_000, fps: 30)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!, stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<2160 {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            row.initialize(repeating: 0xff404040, count: 1920)
            row.advanced(by: 1920).initialize(repeating: 0xffc0c0c0, count: 1920)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let capturer = RTCVideoCapturer(delegate: source)
        for index in 0..<60 {
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
            if index == 15 { viewer.sendInput(RemoteInput(type: "release")) }
            try await Task.sleep(for: .milliseconds(33))
        }
        await fulfillment(of: [received, control], timeout: 5)
        XCTAssertEqual(sink.size.0, 3840); XCTAssertEqual(sink.size.1, 2160)
        // Simulate the source adapter resizing before SCK has supplied its resized backing buffer.
        source.adaptOutputFormat(toWidth: 1920, height: 1080, fps: 30)
        for _ in 0..<150 {
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
            try await Task.sleep(for: .milliseconds(33))
            if sink.size == (1920, 1080) { break }
        }
        XCTAssertEqual(sink.size.0, 1920); XCTAssertEqual(sink.size.1, 1080)
        XCTAssertGreaterThan(sink.contrast ?? 0, 60, "Hardware decode and live scaling must preserve synthetic image contrast")
        let outgoing = await host.diagnostics(), incoming = await viewer.diagnostics()
        let summary = (outgoing + incoming).filter { ["codec", "outbound-rtp", "inbound-rtp"].contains($0["type"] ?? "") }.map { $0.filter { ["type", "mimeType", "encoderImplementation", "decoderImplementation", "framesEncoded", "framesDecoded", "codecId"].contains($0.key) } }
        XCTAssertTrue(outgoing.contains { $0["mimeType"]?.lowercased() == "video/h265" }, "Codec evidence: \(summary)")
        XCTAssertTrue(outgoing.contains { $0["encoderImplementation"] == "VideoToolboxHEVC" && (Int($0["framesEncoded"] ?? "0") ?? 0) > 0 })
        XCTAssertTrue(incoming.contains { $0["decoderImplementation"] == "VideoToolboxHEVC" && (Int($0["framesDecoded"] ?? "0") ?? 0) > 0 })
    }
    func testHEVCProfilesAndNegotiatedLevelLimits() {
        XCTAssertTrue(DesktopHEVCFormat.accepts(DesktopHEVCFormat.info))
        XCTAssertTrue(DesktopHEVCFormat.accepts(RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1", "level-id": "180"])))
        XCTAssertFalse(DesktopHEVCFormat.accepts(RTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "2", "level-id": "156"])))
        XCTAssertFalse(DesktopHEVCFormat.accepts(RTCVideoCodecInfo(name: "H265", parameters: ["tx-mode": "MRST", "level-id": "156"])))
        XCTAssertFalse(DesktopHEVCFormat.accepts(RTCVideoCodecInfo(name: "H265", parameters: ["level-id": "999"])))
        for level in [30,60,63,90,93,120,123,150,153,156] {
            let limit = H264CaptureLimit(hevcLevel: level)
            let size = limit.dimensions(width: 3840, height: 2160, quality: .native)
            let blocks = ((size.width + 15) / 16) * ((size.height + 15) / 16)
            XCTAssertLessThanOrEqual(blocks, limit.frameMacroblocks)
            XCTAssertLessThanOrEqual(blocks * size.fps, limit.macroblocksPerSecond)
        }
    }
    func testMalformedHEVCAccessUnitsAreRejected() {
        for bytes: [UInt8] in [[],[0,0,0,1],[0,0,1,0x80,1],[0,0,1,2,0],[1,2,3,4]] {
            XCTAssertNil(DesktopHEVCFormat.nalUnits(Data(bytes)))
        }
    }
    @MainActor
    func testH264FallbackWhenOnlyOnePeerSupportsHEVC() async throws {
        try await fallback(hostHEVC: true, viewerHEVC: false)
        try await fallback(hostHEVC: false, viewerHEVC: true)
    }
    @MainActor
    func testH264FallbackAfterHEVCEncoderInitializationFailure() async throws {
        try await fallback(hostHEVC: true, viewerHEVC: true, failingEncoder: true)
    }
    @MainActor
    private func fallback(hostHEVC: Bool, viewerHEVC: Bool, failingEncoder: Bool = false) async throws {
        let host = try RemotePeer(sendingVideo: true, allowHEVC: hostHEVC, encoderFactory: failingEncoder ? UnavailableHEVCFactory() : nil)
        let viewer = try RemotePeer(sendingVideo: false, allowHEVC: viewerHEVC)
        defer { host.close(); viewer.close() }
        let received = expectation(description: "fallback H264 frame")
        let sink = HEVCFrameSink(expectation: received)
        viewer.onVideo = { $0.add(sink) }
        try await viewer.accept(answer: host.answer(offer: viewer.makeOffer()))
        var hi = 0, vi = 0
        for _ in 0..<100 {
            let hc = host.localCandidates, vc = viewer.localCandidates
            for c in hc.dropFirst(hi) { try await viewer.add(c) }
            for c in vc.dropFirst(vi) { try await host.add(c) }
            hi = hc.count; vi = vc.count
            if host.connectionState == .connected && viewer.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let source = try XCTUnwrap(host.videoSource)
        source.adaptOutputFormat(toWidth: 640, height: 360, fps: 30)
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 96, CVPixelBufferGetBytesPerRow(buffer) * 360); CVPixelBufferUnlockBaseAddress(buffer, [])
        let capturer = RTCVideoCapturer(delegate: source)
        for _ in 0..<30 {
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
            try await Task.sleep(for: .milliseconds(33))
        }
        await fulfillment(of: [received], timeout: 4)
        let outgoing = await host.diagnostics(), incoming = await viewer.diagnostics()
        XCTAssertEqual(host.videoCodec, "H264"); XCTAssertEqual(viewer.videoCodec, "H264")
        XCTAssertTrue(outgoing.contains { $0["mimeType"]?.lowercased() == "video/h264" })
        XCTAssertTrue(incoming.contains { $0["decoderImplementation"] == "VideoToolbox" })
    }

}

private final class HEVCFrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var dimensions = (0,0)
    private var received = false
    private var lumaContrast: Int?
    var contrast: Int? { lock.withLock { lumaContrast } }
    var size: (Int,Int) { lock.withLock { dimensions } }
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        var contrast: Int?
        if let pixels = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer, CVPixelBufferGetPlaneCount(pixels) > 0 {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self) {
                let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * CVPixelBufferGetHeight(pixels) / 2
                contrast = Int(y[row + CVPixelBufferGetWidth(pixels) * 3 / 4]) - Int(y[row + CVPixelBufferGetWidth(pixels) / 4])
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        lock.lock(); lumaContrast = contrast; dimensions = (Int(frame.width),Int(frame.height)); let first = !received; received = true; lock.unlock()
        if first { expectation.fulfill() }
    }
}

private final class HEVCAdapterReport: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, status = -999
    var bytes: Int { lock.withLock { count } }
    var decodeStatus: Int { lock.withLock { status } }
    func recordEncoded(_ data: Data) { lock.withLock { count = data.count } }
    func recordDecode(_ value: Int) { lock.withLock { status = value } }
}

private final class UnavailableHEVCFactory: NSObject, RTCVideoEncoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { [DesktopHEVCFormat.info] + DesktopH264.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        info.name == "H265" ? UnavailableHEVCEncoder() : RTCVideoEncoderH264(codecInfo: info)
    }
}
private final class UnavailableHEVCEncoder: NSObject, RTCVideoEncoder {
    func setCallback(_ callback: RTCVideoEncoderCallback?) {}
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int { -1 }
    func release() -> Int { 0 }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int { -1 }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { -1 }
    func implementationName() -> String { "UnavailableHEVCTestEncoder" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
}
