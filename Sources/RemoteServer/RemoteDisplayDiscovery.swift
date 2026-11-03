import Foundation
import RemoteCore

/// Display sleep can temporarily remove every active display from CoreGraphics.
/// Prepare the framebuffer before requiring a display ID for the WebRTC offer.
@MainActor
enum RemoteDisplayDiscovery {
    static func discover(
        read: () -> [RemoteDisplay],
        needsPreparation: ([RemoteDisplay]) -> Bool,
        prepare: () -> Void,
        mayContinue: () -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) async throws -> [RemoteDisplay] {
        guard mayContinue() else { throw RemoteError.message("The current user session is unavailable or the connection was canceled.") }
        let initial = read()
        if !needsPreparation(initial) { return initial }
        prepare()
        for _ in 0..<12 {
            try await pause()
            guard mayContinue() else { throw RemoteError.message("The current user session is unavailable or the connection was canceled.") }
            let displays = read()
            if !displays.isEmpty { return displays }
        }
        throw RemoteError.message("Displays are still asleep or unavailable. Try connecting again shortly.")
    }
}
