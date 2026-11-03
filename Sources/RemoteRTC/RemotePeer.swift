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
    public private(set) var connection: RTCPeerConnection!
    public private(set) var videoSource: RTCVideoSource?
    public private(set) var remoteVideo: RTCVideoTrack?
    public private(set) var localCandidates: [RemoteICECandidate] = []
    public private(set) var closed = false
    public private(set) var connectionState: RTCPeerConnectionState = .new
    public var captureLimit: H264CaptureLimit {
        let profile = sender?.parameters.codecs.first(where: { $0.name == "H264" })?.parameters["profile-level-id"] as? String ?? "42e01f"
        return H264CaptureLimit(level: Int(profile.suffix(2), radix: 16) ?? 31)
    }
    public var onInput: ((Data, Bool) -> Void)?
    public var onState: ((RTCPeerConnectionState) -> Void)?
    public var onVideo: ((RTCVideoTrack) -> Void)?
    public var onCandidate: ((RemoteICECandidate) -> Void)?
    public var onMessage: ((Data) -> Void)?
    private var channels: [String: RTCDataChannel] = [:]
    private var sender: RTCRtpSender?

    public init(sendingVideo: Bool) throws {
        super.init()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = [] // LAN only: no third-party discovery or relay traffic.
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        guard let connection = Self.factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw RemoteError.message("Unable to initialize WebRTC.")
        }
        self.connection = connection
        if sendingVideo {
            let source = Self.factory.videoSource(forScreenCast: true)
            videoSource = source
            let track = Self.factory.videoTrack(with: source, trackId: "desktop")
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
        return await withCheckedContinuation { continuation in
            connection.statistics { report in
                let allowed = ["outbound-rtp", "inbound-rtp", "media-source", "codec"]
                let values = report.statistics.values.filter { allowed.contains($0.type) }.map { stat in
                    var values = stat.values.mapValues { String(describing: $0) }
                    values["type"] = stat.type
                    return values
                }
                continuation.resume(returning: values)
            }
        }
    }
    public func send(_ data: Data, pointer: Bool = false) -> Bool {
        guard !closed, let channel = channels[pointer ? "pointer" : "control"],
              channel.readyState == .open, channel.bufferedAmount < 65536 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    public func sendInput(_ input: RemoteInput) {
        guard input.validate(), let data = try? JSONEncoder().encode(input) else { return }
        _ = send(data, pointer: input.type == "pointer" && input.action == "move")
    }
    public func close() {
        guard !closed else { return }
        closed = true
        for channel in channels.values { channel.delegate = nil; channel.close() }
        channels.removeAll()
        connection.delegate = nil
        connection.close()
        videoSource = nil
        remoteVideo = nil
    }
    private func install(_ channel: RTCDataChannel) {
        guard ["control", "pointer"].contains(channel.label), channels[channel.label] == nil else { channel.close(); return }
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
            self.onInput?(data, pointer)
            self.onMessage?(data)
        }
    }
}
