import AppKit
import ScreenCaptureKit
import CoreMedia
import WebRTC
import RemoteCore

public enum DesktopQuality: String, CaseIterable, Codable, Sendable {
    case smooth, clear, native
    public var maximumWidth: Int { switch self { case .smooth: 1920; case .clear: 2560; case .native: 3840 } }
    public var maximumHeight: Int { switch self { case .smooth: 1080; case .clear: 1440; case .native: 2160 } }
    public var fps: Int { self == .smooth ? 60 : 30 }
    public var bitrate: Int { switch self { case .smooth: 16_000_000; case .clear: 24_000_000; case .native: 48_000_000 } }
}

/// ScreenCaptureKit hands its CVPixelBuffer directly to libwebrtc's VideoToolbox encoder.
/// No PNG/JPEG intermediate or CPU image conversion is used.
private final class DesktopFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let source: RTCVideoSource
    let capturer: RTCVideoCapturer
    let onError: (String) -> Void
    let queue = DispatchQueue(label: "Vela.remote.frames", qos: .userInteractive)
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var latest: CVPixelBuffer?
    private var lastSubmitted: TimeInterval = 0
    private var heartbeat: DispatchSourceTimer?
    private var stopped = false
    private var acceptFramesAfter: TimeInterval = 0
    var diagnostics: [String: Int] { lock.lock(); defer { lock.unlock() }; return counters }
    private func count(_ key: String) { lock.lock(); counters[key, default: 0] += 1; lock.unlock() }
    init(source: RTCVideoSource, onError: @escaping (String) -> Void) {
        self.source = source; self.capturer = RTCVideoCapturer(delegate: source); self.onError = onError
    }
    func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let latest = self.latest, ProcessInfo.processInfo.systemUptime - self.lastSubmitted >= 0.9 else { return }
            self.submit(latest, timestamp: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
            self.count("idleRefresh")
        }
        heartbeat = timer; timer.resume()
    }
    func stop() { queue.sync { stopped = true; heartbeat?.cancel(); heartbeat = nil; latest = nil } }
    func beginSessionTransition() {
        queue.sync {
            latest = nil
            // Drop compositor frames queued around the lock-state notification.
            acceptFramesAfter = ProcessInfo.processInfo.systemUptime + 0.5
            lock.lock(); counters["readyFrames"] = 0; lock.unlock()
        }
    }
    deinit { heartbeat?.cancel() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped else { return }
        count("received")
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { count("invalid"); return }
        count("status_\(status)")
        guard status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard ProcessInfo.processInfo.systemUptime >= acceptFramesAfter else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let nanoseconds = CMTimeConvertScale(timestamp, timescale: 1_000_000_000, method: .default).value
        latest = pixelBuffer
        submit(pixelBuffer, timestamp: nanoseconds)
        count("readyFrames")
    }
    private func submit(_ pixelBuffer: CVPixelBuffer, timestamp: Int64) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: timestamp)
        source.capturer(capturer, didCapture: frame)
        lastSubmitted = ProcessInfo.processInfo.systemUptime
        count("submitted")
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        count("captureErrors")
        queue.async { self.stopped = true; self.latest = nil; self.heartbeat?.cancel(); self.heartbeat = nil }
        onError(error.localizedDescription)
    }
}

@MainActor
public final class DesktopCapture {
    private var stream: SCStream?
    private var output: DesktopFrameOutput?
    private var generation = UUID()
    public private(set) var displayID: CGDirectDisplayID?
    private var format: [String: Int] = [:]
    public var onError: ((String) -> Void)?
    public var diagnostics: [String: Int] { (output?.diagnostics ?? [:]).merging(format) { _, format in format } }
    public var isRunning: Bool { stream != nil && (output?.diagnostics["captureErrors"] ?? 0) == 0 }
    public func beginSessionTransition() { output?.beginSessionTransition() }
    public init() {}
    public static func pixelDimensions(displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        // CGDisplayPixelsWide/High describe the scaled desktop on Retina displays.
        // The mode's pixel dimensions describe the actual screen-capture backing size.
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID))
    }
    public static func displays() async throws -> [RemoteDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let size = pixelDimensions(displayID: display.displayID)
            return RemoteDisplay(id: display.displayID, name: display.displayID == CGMainDisplayID() ? "Main Display" : "Display \(display.displayID)",
                                 width: size.width, height: size.height)
        }
    }
    public static func displayMetadata() -> [RemoteDisplay] {
        // Enumerating display modes does not need an active capture stream and
        // remains available while the user is at the system lock/login screen.
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let size = pixelDimensions(displayID: id)
            return RemoteDisplay(id: id, name: id == CGMainDisplayID() ? "Main Display" : "Display \(id)", width: size.width, height: size.height)
        }
    }
    public func waitForFirstFrame() async throws {
        let generation = self.generation
        for _ in 0..<60 {
            guard self.generation == generation, isRunning else { throw RemoteError.message("Capture canceled or interrupted.") }
            if (output?.diagnostics["readyFrames"] ?? 0) > 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RemoteError.message("The display has not provided a new frame yet.")
    }
    public func start(source: RTCVideoSource, displayID: UInt32, quality: DesktopQuality, limit: H264CaptureLimit = .init(level: 31)) async throws {
        await stop()
        let generation = self.generation
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard self.generation == generation else { throw RemoteError.message("Capture canceled.") }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RemoteError.message("The display disconnected or no display is available for capture.")
        }
        let pixels = Self.pixelDimensions(displayID: displayID)
        let nativeWidth = pixels.width
        let nativeHeight = pixels.height
        guard nativeWidth > 0, nativeHeight > 0 else { throw RemoteError.message("Display dimensions unavailable.") }
        let dimensions = limit.dimensions(width: nativeWidth, height: nativeHeight, quality: quality)
        let config = SCStreamConfiguration()
        config.width = dimensions.width
        config.height = dimensions.height
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(dimensions.fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = false
        config.excludesCurrentProcessAudio = true
        source.adaptOutputFormat(toWidth: Int32(dimensions.width), height: Int32(dimensions.height), fps: Int32(dimensions.fps))
        let output = DesktopFrameOutput(source: source) { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.onError?(message)
            }
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        output.startHeartbeat()
        self.output = output; self.stream = stream; self.displayID = displayID
        format = ["sourceWidth": nativeWidth, "sourceHeight": nativeHeight,
                  "width": dimensions.width, "height": dimensions.height, "fps": dimensions.fps,
                  "maximumBitrate": quality.bitrate]
        do {
            try await stream.startCapture()
            guard self.generation == generation else {
                output.stop(); try? await stream.stopCapture()
                throw RemoteError.message("Capture canceled.")
            }
        } catch {
            output.stop()
            if self.generation == generation { self.output = nil; self.stream = nil; self.displayID = nil; self.format = [:] }
            throw error
        }
    }
    public func stop() async {
        let old = stream
        generation = UUID()
        stream = nil; displayID = nil; format = [:]
        output?.stop(); output = nil
        if let old { try? await old.stopCapture() }
    }
}
