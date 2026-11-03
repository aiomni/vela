import AppKit
import Darwin
import RemoteCore

public struct DesktopSessionSnapshot: Codable, Equatable, Sendable {
    public let available: Bool
    public let onConsole: Bool
    public let loginDone: Bool
    public let locked: Bool
    public var state: String { !available ? "unavailable" : locked ? "locked" : onConsole ? "local" : "detached" }
    public static func current() -> Self {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return .init(available: false, onConsole: false, loginDone: false, locked: true)
        }
        return .init(available: true,
                     onConsole: dictionary[kCGSessionOnConsoleKey as String] as? Bool ?? false,
                     loginDone: dictionary[kCGSessionLoginDoneKey as String] as? Bool ?? false,
                     locked: dictionary["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }
}

@MainActor
public enum DesktopSession {
    private static let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY | RTLD_LOCAL)
    public static var canDetach: Bool { framework.flatMap { dlsym($0, "SACSwitchToLoginWindow") } != nil }
    public static func detachFromConsole(allowLocked: Bool = false) throws {
        let snapshot = DesktopSessionSnapshot.current()
        guard snapshot.available, snapshot.loginDone, snapshot.onConsole, allowLocked || !snapshot.locked else {
            throw RemoteError.message("Only the current unlocked local session can enter a private session.")
        }
        guard let framework, let symbol = dlsym(framework, "SACSwitchToLoginWindow") else {
            throw RemoteError.message("This system does not support detaching from the local console.")
        }
        let invoke = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        let result = invoke()
        guard result == 0 else { throw RemoteError.message("The system could not switch to the login screen (\(result)).") }
    }
    public static func lockScreen() throws {
        guard let framework, let symbol = dlsym(framework, "SACLockScreenImmediate") else {
            throw RemoteError.message("This system does not support lock requests.")
        }
        let result = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()
        guard result == 0 else { throw RemoteError.message("The system could not lock the screen (\(result)).") }
    }
    public static func sleepPhysicalDisplays() async throws {
        // This is a one-time display sleep request, not a system sleep or a
        // persistent change to the user's power/lock preferences.
        let success = await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
            catch { return false }
        }.value
        guard success else { throw RemoteError.message("The system did not accept the display sleep request.") }
    }
}
