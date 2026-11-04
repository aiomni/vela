import Foundation
import WebRTC

/// H.264 user_data_unregistered SEI survives the sender's randomized RTP offset.
/// Receivers associate the identity with the timestamp of the received access unit.
public enum DesktopH264Identity {
    public static let uuid: [UInt8] = [86,101,108,97,70,114,97,109,101,73,68,45,118,49,0,1]
    public static func sei(_ marker: DesktopFrameMarker) -> Data {
        guard let json = try? JSONEncoder().encode(marker), json.count <= 512 else { return Data() }
        let payload = uuid + json
        var rbsp: [UInt8] = [5]
        var size = payload.count
        while size >= 255 { rbsp.append(255); size -= 255 }
        rbsp.append(UInt8(size)); rbsp += payload; rbsp.append(128)
        var escaped: [UInt8] = [0,0,0,1,6], zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(escaped)
    }
    public static func marker(in data: Data, rtpTimestamp: UInt32) -> DesktopFrameMarker? {
        let bytes = Array(data.prefix(65536))
        var starts: [(Int, Int)] = [], i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 { starts.append((i, i+3)); i += 3 }
            else if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 { starts.append((i, i+4)); i += 4 }
            else { i += 1 }
        }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index+1].0 : bytes.count
            guard start.1 < end, bytes[start.1] & 31 == 6 else { continue }
            var rbsp: [UInt8] = [], zeros = 0
            for byte in bytes[(start.1+1)..<end] {
                if zeros >= 2 && byte == 3 { zeros = 0; continue }
                rbsp.append(byte); zeros = byte == 0 ? zeros + 1 : 0
            }
            var cursor = 0
            while cursor + 2 <= rbsp.count {
                var type = 0, size = 0
                while cursor < rbsp.count && rbsp[cursor] == 255 { type += 255; cursor += 1 }
                guard cursor < rbsp.count else { break }; type += Int(rbsp[cursor]); cursor += 1
                while cursor < rbsp.count && rbsp[cursor] == 255 { size += 255; cursor += 1 }
                guard cursor < rbsp.count else { break }; size += Int(rbsp[cursor]); cursor += 1
                guard size <= rbsp.count - cursor else { break }
                if type == 5, size > 16, size <= 528, Array(rbsp[cursor..<(cursor+16)]) == uuid,
                   var marker = try? JSONDecoder().decode(DesktopFrameMarker.self, from: Data(rbsp[(cursor+16)..<(cursor+size)])) {
                    marker.rtpTimestamp = rtpTimestamp; return marker
                }
                cursor += size
            }
        }
        return nil
    }
}

final class DesktopTrackedDecoder: NSObject, RTCVideoDecoder {
    let decoder: RTCVideoDecoder
    let identity: DesktopFrameIdentity
    init(_ decoder: RTCVideoDecoder, identity: DesktopFrameIdentity) { self.decoder = decoder; self.identity = identity }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { decoder.setCallback(callback) }
    func startDecode(withNumberOfCores cores: Int32) -> Int { decoder.startDecode(withNumberOfCores: cores) }
    func release() -> Int { decoder.release() }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        identity.received(image.buffer, timestamp: image.timeStamp)
        return decoder.decode(image, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }
    func implementationName() -> String { decoder.implementationName() }
}
