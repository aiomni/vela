import XCTest
import Foundation
import CoreVideo
import ImageIO
import WebRTC
import RemoteCore
import RemoteRTC
@testable import RemoteServer

/// Optional local browser harness. Generates synthetic pixels, never captures a desktop.
final class DesktopBrowserTransportTests: XCTestCase {
    @MainActor
    func testSyntheticBrowserTransport() async throws {
        guard let raw = ProcessInfo.processInfo.environment["VELA_SYNTHETIC_BROWSER_PORT"], let port = Int(raw),
              let output = ProcessInfo.processInfo.environment["VELA_SYNTHETIC_BROWSER_INFO"] else {
            throw XCTSkip("Set VELA_SYNTHETIC_BROWSER_PORT and VELA_SYNTHETIC_BROWSER_INFO for the isolated browser harness")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-synthetic-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RemoteFiles(directory: directory)
        _ = try RemoteCertificate.prepare(files: files, addresses: ["127.0.0.1"])
        let hevc = ProcessInfo.processInfo.environment["VELA_SYNTHETIC_BROWSER_HEVC"] == "1"
        let width = hevc ? 3840 : 1280, height = hevc ? 2160 : 720
        if hevc { let capability = await DesktopHEVC.capability.value; XCTAssertTrue(capability.available) }
        let peer = try RemotePeer(sendingVideo: true, allowHEVC: hevc)
        peer.frameIdentity.observe { _ in }
        let server = RemoteHTTPS()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let completion = SyntheticCompletion()
        try await server.start(addresses: ["127.0.0.1"], port: port, files: files) { request in
            await Task { @MainActor in do { switch (request.method, request.path) {
            case ("POST", "/offer"):
                struct Offer: Decodable { let sdp: String }
                let offer = try JSONDecoder().decode(Offer.self, from: request.body)
                let answer = try await peer.answer(offer: offer.sdp)
                peer.videoSource?.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 30)
                return .json(["sdp": answer])
            case ("POST", "/candidate"):
                let candidate = try JSONDecoder().decode(RemoteICECandidate.self, from: request.body)
                try await peer.add(candidate); return .json(["ok": true])
            case ("GET", "/candidates"): return .json(peer.localCandidates)
            case ("GET", "/statistics"): return .json(await peer.diagnostics())
            case ("POST", "/complete"): completion.completed = true; return .json(["ok": true])
            case ("GET", "/lossless.js"), ("GET", "/frame-identity-worker.js"), ("GET", "/client-core.js"):
                return .init(body: try Data(contentsOf: root.appendingPathComponent("Sources/RemoteServer/Web\(request.path)")), contentType: "text/javascript")
            default: return .error("Unknown synthetic fixture route.", status: 404)
            } } catch { return .error("Synthetic fixture operation failed.", status: 400) } }.value
        }
        try JSONSerialization.data(withJSONObject: ["port": port, "certificate": files.certificateURL.path, "hevc": hevc, "width": width, "height": height]).write(to: URL(fileURLWithPath: output))
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let png = NSMutableData()
        let provider = CGDataProvider(data: Data(repeating: 100, count: 64 * 64 * 4) as CFData)!
        let image = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let chunk: [String: Any] = ["type": "tile", "epoch": "synthetic-browser", "version": 1,
            "width": width, "height": height, "x": 0, "y": 0, "tileWidth": 64, "tileHeight": 64,
            "part": 0, "count": 1, "data": (png as Data).base64EncodedString()]
        let packet = try JSONSerialization.data(withJSONObject: chunk)
        let deadline = ProcessInfo.processInfo.systemUptime + 50
        var sent = 0
        while !completion.completed && ProcessInfo.processInfo.systemUptime < deadline {
            if peer.connectionState == .connected, let source = peer.videoSource {
                let timestamp = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                peer.frameIdentity.capture(nanoseconds: timestamp, marker: DesktopFrameMarker(epoch: "synthetic-browser", version: 1, width: width, height: height))
                source.capturer(RTCVideoCapturer(delegate: source), didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: timestamp))
                if hevc { sent += 1 } else if peer.sendEnhancement(packet) { sent += 1 }
            }
            try await Task.sleep(for: .milliseconds(33))
        }
        if hevc {
            let statistics = await peer.diagnostics()
            XCTAssertEqual(peer.videoCodec, "H265")
            XCTAssertTrue(statistics.contains { $0["encoderImplementation"] == "VideoToolboxHEVC" && (Int($0["framesEncoded"] ?? "0") ?? 0) > 0 },
                "Synthetic codec evidence: \(statistics.filter { $0["type"] == "outbound-rtp" || $0["type"] == "codec" })")
        }
        peer.close(); await server.stop()
        XCTAssertTrue(completion.completed, "Browser did not acknowledge a synchronized enhancement")
        XCTAssertGreaterThan(sent, 0)
    }
}

@MainActor
private final class SyntheticCompletion { var completed = false }
