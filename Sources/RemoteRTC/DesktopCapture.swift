import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import ImageIO
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
    let onError: @Sendable (String) -> Void
    let queue = DispatchQueue(label: "Vela.remote.frames", qos: .userInteractive)
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var latest: CVPixelBuffer?
    private var contentEpoch = UUID().uuidString
    private var contentVersion = 0
    var frameIdentity: DesktopFrameIdentity?
    var losslessMarker: DesktopFrameMarker? {
        queue.sync { latest.map { DesktopFrameMarker(epoch: contentEpoch, version: contentVersion,
            width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) } }
    }
    func losslessSnapshot() -> (CVPixelBuffer, DesktopFrameMarker)? {
        queue.sync {
            guard let latest, CVPixelBufferGetPixelFormatType(latest) == kCVPixelFormatType_32BGRA,
                  ProcessInfo.processInfo.systemUptime - cadence.lastContentChange >= 1.35 else { return nil }
            return (latest, DesktopFrameMarker(epoch: contentEpoch, version: contentVersion,
                width: CVPixelBufferGetWidth(latest), height: CVPixelBufferGetHeight(latest)))
        }
    }
    private var pending: (CVPixelBuffer, Int64, Bool)?
    private var deliveryScheduled = false
    private var cadence = DesktopFrameCadence()
    private var lastTimestamp: Int64 = 0
    private var heartbeat: DispatchSourceTimer?
    private var stopped = false
    private var acceptFramesAfter: TimeInterval = 0
    private var refinementAllowed = true
    let sampleQueue = DispatchQueue(label: "Vela.remote.capture", qos: .userInteractive)
    var diagnostics: [String: Int] { lock.lock(); defer { lock.unlock() }; return counters }
    private func count(_ key: String) { lock.lock(); counters[key, default: 0] += 1; lock.unlock() }
    init(source: RTCVideoSource, onError: @escaping @Sendable (String) -> Void) {
        self.source = source; self.capturer = RTCVideoCapturer(delegate: source); self.onError = onError
    }
    func setRefinementAllowed(_ allowed: Bool) { queue.async { self.refinementAllowed = allowed } }
    func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, let latest = self.latest else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard self.cadence.shouldRepeat(now: now, refinementAllowed: self.refinementAllowed) else { return }
            self.submit(latest, timestamp: Int64(now * 1_000_000_000), repeated: true)
            self.count(self.cadence.isRefining(now: now) && self.refinementAllowed ? "refinementRefresh" : "idleRefresh")
        }
        heartbeat = timer; timer.resume()
    }
    func stop() {
        lock.lock(); stopped = true; pending = nil; lock.unlock()
        queue.sync { heartbeat?.cancel(); heartbeat = nil; latest = nil; cadence = DesktopFrameCadence() }
    }
    func beginSessionTransition() {
        lock.lock(); pending = nil; acceptFramesAfter = ProcessInfo.processInfo.systemUptime + 0.5; lock.unlock()
        queue.sync {
            latest = nil; cadence = DesktopFrameCadence(); contentEpoch = UUID().uuidString; contentVersion = 0; frameIdentity?.reset()
            lock.lock(); counters["readyFrames"] = 0; counters.removeValue(forKey: "lastContentChangeMilliseconds"); lock.unlock()
        }
    }
    deinit { heartbeat?.cancel() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        count("received")
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int else { count("invalid"); return }
        count("status_\(status)")
        guard status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let nanoseconds = CMTimeConvertScale(timestamp, timescale: 1_000_000_000, method: .default).value
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - Double(nanoseconds) / 1_000_000_000
        guard age < 0.25 else { count("staleFramesDropped"); return }
        let dirty = (info[.dirtyRects] as? [CGRect]).map { $0.contains { !$0.isEmpty } } ?? true
        lock.lock()
        guard !stopped, now >= acceptFramesAfter else { lock.unlock(); return }
        if pending != nil { counters["pendingFramesReplaced", default: 0] += 1 }
        pending = (pixelBuffer, nanoseconds, dirty || pending?.2 == true)
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if schedule { queue.async { self.deliverLatest() } }
    }
    private func deliverLatest() {
        lock.lock(); let frame = stopped ? nil : pending; pending = nil; deliveryScheduled = false; lock.unlock()
        guard let (pixelBuffer, timestamp, changed) = frame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - Double(timestamp) / 1_000_000_000 < 0.25 else { count("staleFramesDropped"); return }
        if let latest, CVPixelBufferGetWidth(latest) != CVPixelBufferGetWidth(pixelBuffer) || CVPixelBufferGetHeight(latest) != CVPixelBufferGetHeight(pixelBuffer) {
            contentEpoch = UUID().uuidString; contentVersion = 0; frameIdentity?.reset()
        }
        if changed || latest == nil {
            contentVersion += 1
            cadence.contentChanged(now: now)
            lock.lock(); counters["lastContentChangeMilliseconds"] = Int(now * 1000); lock.unlock()
        }
        latest = pixelBuffer
        submit(pixelBuffer, timestamp: timestamp, repeated: false)
        count("readyFrames")
    }
    private func submit(_ pixelBuffer: CVPixelBuffer, timestamp: Int64, repeated: Bool) {
        lastTimestamp = max(lastTimestamp + 1, timestamp)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: lastTimestamp)
        frameIdentity?.capture(nanoseconds: lastTimestamp, marker: DesktopFrameMarker(epoch: contentEpoch, version: contentVersion,
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)))
        source.capturer(capturer, didCapture: frame)
        cadence.submitted(now: ProcessInfo.processInfo.systemUptime, repeated: repeated)
        count("submitted")
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        count("captureErrors")
        lock.lock(); stopped = true; pending = nil; lock.unlock()
        queue.async { self.latest = nil; self.heartbeat?.cancel(); self.heartbeat = nil }
        onError(error.localizedDescription)
    }
}

@MainActor
public final class DesktopCapture {
    private var stream: SCStream?
    private var output: DesktopFrameOutput?
    private var streamConfiguration: SCStreamConfiguration?
    private var updatingConfiguration = false
    public private(set) var baseDimensions: (width: Int, height: Int, fps: Int)?
    private var generation = UUID()
    public private(set) var displayID: CGDirectDisplayID?
    private var format: [String: Int] = [:]
    public var onError: ((String) -> Void)?
    public var frameIdentity: DesktopFrameIdentity?
    public var losslessMarker: DesktopFrameMarker? { output?.losslessMarker }
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
        baseDimensions = dimensions
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
        output.frameIdentity = frameIdentity
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.sampleQueue)
        output.startHeartbeat()
        self.output = output; self.stream = stream; self.streamConfiguration = config; self.displayID = displayID
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
    public func selectQuality(_ quality: DesktopQuality, limit: H264CaptureLimit) {
        guard let width = format["sourceWidth"], let height = format["sourceHeight"] else { return }
        baseDimensions = limit.dimensions(width: width, height: height, quality: quality)
        format["maximumBitrate"] = quality.bitrate
    }
    /// Workload changes stay on the established capture stream and peer connection.
    public func apply(_ decision: DesktopStreamDecision, lossless: Bool = false) async throws {
        output?.setRefinementAllowed(decision.refinement || decision.tier == 0 && decision.state != "limited")
        guard !updatingConfiguration, let stream, let config = streamConfiguration, let output,
              config.width != decision.width || config.height != decision.height ||
              config.minimumFrameInterval.timescale != Int32(decision.fps) ||
              config.pixelFormat != (lossless ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else { return }
        updatingConfiguration = true
        defer { updatingConfiguration = false }
        let generation = self.generation
        let oldWidth = config.width, oldHeight = config.height, oldInterval = config.minimumFrameInterval
        let oldPixelFormat = config.pixelFormat
        config.pixelFormat = lossless ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.width = decision.width; config.height = decision.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(decision.fps))
        do { try await stream.updateConfiguration(config) }
        catch {
            config.width = oldWidth; config.height = oldHeight; config.minimumFrameInterval = oldInterval; config.pixelFormat = oldPixelFormat
            throw error
        }
        guard self.generation == generation else { return }
        output.source.adaptOutputFormat(toWidth: Int32(decision.width), height: Int32(decision.height), fps: Int32(decision.fps))
        format["width"] = decision.width; format["height"] = decision.height; format["fps"] = decision.fps
    }
    public func losslessTiles() async -> [DesktopLosslessChunk] {
        guard let (pixels, marker) = output?.losslessSnapshot() else { return [] }
        let worker = Task.detached(priority: .utility) { () -> [DesktopLosslessChunk] in
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let image = context.createCGImage(CIImage(cvPixelBuffer: pixels),
                from: CGRect(x: 0, y: 0, width: marker.width, height: marker.height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return [] }
            var packets: [DesktopLosslessChunk] = [], byteCount = 0
            for y in stride(from: 0, to: marker.height, by: 512) {
                for x in stride(from: 0, to: marker.width, by: 512) {
                    if Task.isCancelled { return [] }
                    let width = min(512, marker.width - x), height = min(512, marker.height - y)
                    guard let tile = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { continue }
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(destination, tile, nil)
                    guard CGImageDestinationFinalize(destination), data.length <= 131072 else { continue }
                    byteCount += data.length
                    guard byteCount <= 524288 else { return packets }
                    let bytes = data as Data
                    let count = (bytes.count + 8191) / 8192
                    for part in 0..<count {
                        packets.append(DesktopLosslessChunk(epoch: marker.epoch, version: marker.version,
                            width: marker.width, height: marker.height, x: x, y: y, tileWidth: width, tileHeight: height,
                            part: part, count: count, data: bytes.subdata(in: part * 8192..<min(bytes.count, (part + 1) * 8192))))
                    }
                }
            }
            return packets
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
    public func stop() async {
        let old = stream
        generation = UUID()
        stream = nil; streamConfiguration = nil; baseDimensions = nil; displayID = nil; format = [:]
        output?.stop(); output = nil; frameIdentity?.reset()
        if let old { try? await old.stopCapture() }
    }
}
