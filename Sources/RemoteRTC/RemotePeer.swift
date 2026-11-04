import Foundation
import WebRTC
import RemoteCore

/// All signaling is main-actor confined. libwebrtc delegate calls are marshalled here.
@MainActor
public final class RemotePeer: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: DesktopEncoderFactory(), decoderFactory: DesktopDecoderFactory())
    }()
    public private(set) var activeVideoCodec: String?
    private var activeVideoParameters: [String: String]?
    private var negotiatedVideo: (name: String, parameters: [String: String]) {
        let description = connection.localDescription?.type == .answer ? connection.localDescription :
            connection.remoteDescription?.type == .answer ? connection.remoteDescription : connection.localDescription
        let section = (description?.sdp ?? "").components(separatedBy: "m=video ").dropFirst().first?.components(separatedBy: "\r\nm=").first ?? ""
        let lines = section.components(separatedBy: "\r\n")
        let payload = lines.first?.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
        let name = lines.first { $0.hasPrefix("a=rtpmap:\(payload) ") }?.split(separator: " ").last?.split(separator: "/").first.map(String.init) ?? "H264"
        let fmtp = lines.first { $0.hasPrefix("a=fmtp:\(payload) ") }?.components(separatedBy: " ").dropFirst().joined(separator: " ") ?? ""
        return (name, Self.parseVideoParameters(fmtp))
    }
    private static func parseVideoParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for field in text.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        return result
    }
    public var videoCodec: String { activeVideoCodec ?? negotiatedVideo.name }
    public private(set) var connection: RTCPeerConnection!
    public private(set) var videoSource: RTCVideoSource?
    public private(set) var remoteVideo: RTCVideoTrack?
    public private(set) var localCandidates: [RemoteICECandidate] = []
    public private(set) var closed = false
    public private(set) var connectionState: RTCPeerConnectionState = .new
    public var captureLimit: H264CaptureLimit {
        let parameters = activeVideoParameters ?? negotiatedVideo.parameters
        if videoCodec == "H265" { return H264CaptureLimit(hevcLevel: Int(parameters["level-id"] ?? "93") ?? 93) }
        let profile = parameters["profile-level-id"] ?? "42e01f"
        return H264CaptureLimit(level: Int(profile.suffix(2), radix: 16) ?? 31)
    }
    public let frameIdentity = DesktopFrameIdentity()
    public var onEnhancement: ((Data) -> Void)?
    public var onInput: ((Data, Bool) -> Void)?
    public var onState: ((RTCPeerConnectionState) -> Void)?
    public var onVideo: ((RTCVideoTrack) -> Void)?
    public var onCandidate: ((RemoteICECandidate) -> Void)?
    public var onMessage: ((Data) -> Void)?
    private var channels: [String: RTCDataChannel] = [:]
    private var sender: RTCRtpSender?
    private var lastMaximumBitrate: Int?

    public convenience init(sendingVideo: Bool, allowHEVC: Bool = false) throws {
        try self.init(sendingVideo: sendingVideo, allowHEVC: allowHEVC, encoderFactory: nil)
    }
    init(sendingVideo: Bool, allowHEVC: Bool, encoderFactory: RTCVideoEncoderFactory?) throws {
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = [] // LAN only: no third-party discovery or relay traffic.
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        _ = Self.factory // Initialize SSL once before constructing per-peer codec observers.
        let factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory ?? DesktopEncoderFactory(hevc: allowHEVC, identity: sendingVideo ? frameIdentity : nil),
            decoderFactory: DesktopDecoderFactory(hevc: allowHEVC, identity: sendingVideo ? nil : frameIdentity))
        guard let connection = factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw RemoteError.message("Unable to initialize WebRTC.")
        }
        self.connection = connection
        if sendingVideo {
            let source = factory.videoSource(forScreenCast: true)
            videoSource = source
            let track = factory.videoTrack(with: source, trackId: "desktop")
            sender = connection.add(track, streamIds: ["desktop"])
        } else {
            let setup = RTCRtpTransceiverInit()
            setup.direction = .recvOnly
            _ = connection.addTransceiver(of: .video, init: setup)
            let reliable = RTCDataChannelConfiguration()
            reliable.isOrdered = true
            if let channel = connection.dataChannel(forLabel: "control", configuration: reliable) { install(channel) }
            let pointer = RTCDataChannelConfiguration()
            pointer.isOrdered = false
            pointer.maxRetransmits = 0
            if let channel = connection.dataChannel(forLabel: "pointer", configuration: pointer) { install(channel) }
            let enhancement = RTCDataChannelConfiguration(); enhancement.isOrdered = false
            if let channel = connection.dataChannel(forLabel: "enhancement", configuration: enhancement) { install(channel) }
        }
        if allowHEVC {
            let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            let ordered = capabilities.filter { $0.name.uppercased() == "H265" } + capabilities.filter { $0.name.uppercased() != "H265" }
            for transceiver in connection.transceivers where transceiver.mediaType == .video {
                try transceiver.setCodecPreferences(ordered, error: ())
            }
        }
    }

    public func makeOffer() async throws -> String {
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: error ?? RemoteError.message("Unable to create a connection offer.")) }
            }
        }
        try await setLocal(description)
        return description.sdp
    }

    public func answer(offer: String) async throws -> String {
        try await setRemote(RTCSessionDescription(type: .offer, sdp: offer))
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: error ?? RemoteError.message("Unable to create a connection answer.")) }
            }
        }
        try await setLocal(description)
        configureBitrate(maximum: 16_000_000, fps: 60)
        return description.sdp
    }

    public func accept(answer: String) async throws { try await setRemote(RTCSessionDescription(type: .answer, sdp: answer)) }

    private func setLocal(_ sdp: RTCSessionDescription) async throws {
        guard !closed else { throw RemoteError.message("Connection closed.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private func setRemote(_ sdp: RTCSessionDescription) async throws {
        guard !closed else { throw RemoteError.message("Connection closed.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    public func add(_ candidate: RemoteICECandidate) async throws {
        guard !closed, candidate.candidate.utf8.count < 4096, candidate.sdpMLineIndex >= 0,
              candidate.sdpMLineIndex < 8 else { throw RemoteError.message("Invalid network candidate address.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.add(RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex,
                                          sdpMid: candidate.sdpMid)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    public func configureBitrate(maximum: Int, fps: Int) {
        guard let sender else { return }
        if lastMaximumBitrate != maximum {
            // Align the transport ceiling with the encoding ceiling without forcing
            // a bandwidth estimate or imposing a minimum on a congested network.
            if connection.setBweMinBitrateBps(nil, currentBitrateBps: nil, maxBitrateBps: NSNumber(value: maximum)) {
                lastMaximumBitrate = maximum
            }
        }
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: maximum)
            encoding.maxFramerate = NSNumber(value: fps)
        }
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        sender.parameters = parameters
    }
    public func diagnostics() async -> [[String: String]] {
        guard !closed else { return [] }
        let statistics: [[String: String]] = await withCheckedContinuation { continuation in
            connection.statistics { report in
                let allowed = ["outbound-rtp", "inbound-rtp", "remote-inbound-rtp", "media-source", "codec", "candidate-pair", "transport"]
                let values = report.statistics.values.filter { allowed.contains($0.type) }.map { stat in
                    var values = stat.values.mapValues { String(describing: $0) }
                    if stat.type == "candidate-pair" {
                        let safe = ["state", "nominated", "currentRoundTripTime", "availableOutgoingBitrate", "bytesSent", "bytesReceived"]
                        values = values.filter { safe.contains($0.key) }
                    }
                    if stat.type == "transport" {
                        let safe = ["selectedCandidatePairId", "dtlsState", "bytesSent", "bytesReceived"]
                        values = values.filter { safe.contains($0.key) }
                    }
                    values["id"] = stat.id
                    values["type"] = stat.type
                    return values
                }
                continuation.resume(returning: values)
            }
        }
        if !closed {
            let stream = statistics.first { ($0["type"] == "outbound-rtp" || $0["type"] == "inbound-rtp") && ($0["kind"] == "video" || $0["mediaType"] == "video") }
            if let codecID = stream?["codecId"], let codec = statistics.first(where: { $0["type"] == "codec" && $0["id"] == codecID }),
               let mime = codec["mimeType"], let name = mime.split(separator: "/").last {
                activeVideoCodec = String(name).uppercased()
                if let fmtp = codec["sdpFmtpLine"], !fmtp.isEmpty { activeVideoParameters = Self.parseVideoParameters(fmtp) }
                else { activeVideoParameters = negotiatedVideo.name.uppercased() == activeVideoCodec ? negotiatedVideo.parameters : [:] }
            }
        }
        return statistics
    }
    public func send(_ data: Data, pointer: Bool = false) -> Bool {
        guard !closed, let channel = channels[pointer ? "pointer" : "control"],
              channel.readyState == .open, channel.bufferedAmount < 65536 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    public var enhancementReady: Bool { channels["enhancement"]?.readyState == .open }
    public func sendEnhancement(_ data: Data) -> Bool {
        guard !closed, data.count <= 16384, let channel = channels["enhancement"], channel.readyState == .open,
              channel.bufferedAmount < 32768, (channels["control"]?.bufferedAmount ?? 0) < 4096 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    public func sendInput(_ input: RemoteInput) {
        guard input.validate(), let data = try? JSONEncoder().encode(input) else { return }
        _ = send(data, pointer: input.type == "pointer" && input.action == "move")
    }
    public func close() {
        guard !closed else { return }
        closed = true
        frameIdentity.observe(nil)
        for channel in channels.values { channel.delegate = nil; channel.close() }
        channels.removeAll()
        connection.delegate = nil
        connection.close()
        videoSource = nil
        remoteVideo = nil
    }
    private func install(_ channel: RTCDataChannel) {
        guard ["control", "pointer", "enhancement"].contains(channel.label), channels[channel.label] == nil else { channel.close(); return }
        channels[channel.label] = channel
        channel.delegate = self
    }
}

extension RemotePeer: RTCPeerConnectionDelegate {
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let value = RemoteICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.localCandidates.count < 128 else { return }
            self.localCandidates.append(value)
            self.onCandidate?(value)
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in guard let self, !self.closed else { return }; self.install(dataChannel) }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.connectionState = newState
            self.onState?(newState)
        }
    }
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.remoteVideo = track
            self.onVideo?(track)
        }
    }
}
extension RemotePeer: RTCDataChannelDelegate {
    nonisolated public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.data.count <= 16384 else { return }
        let data = buffer.data
        let pointer = dataChannel.label == "pointer"
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            if dataChannel.label == "enhancement" { self.onEnhancement?(data); return }
            self.onInput?(data, pointer)
            self.onMessage?(data)
        }
    }
}
