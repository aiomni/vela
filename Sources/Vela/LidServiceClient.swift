import VelaLocalization
import Foundation
import Darwin
import LidServiceShared

/// One administrator-approved lid session. A detached root watchdog restores
/// normal sleep when this process exits or the session directory is removed.
@MainActor
final class LidServiceClient {
    private var sessionDirectory: URL?
    private var watchdogPID: Int32?
    private var watchdogBirth: String?
    private var authorizationProcess: Process?
    private var changedSetting = false
    private(set) var isHeld = false
    private(set) var lastMessage = L("Not enabled")
    var hasSession: Bool { sessionDirectory != nil || isHeld }
    var hasPendingAuthorization: Bool { authorizationProcess?.isRunning == true }

    // Authorization is requested by macOS for each new session, not installed up front.
    var isAuthorized: Bool { true }

    func open() async -> Bool {
        guard !hasSession else { return isHeld }
        guard let original = await readDisabled() else {
            lastMessage = L("Unable to read current closed-lid sleep settings")
            return false
        }
        if original {
            changedSetting = false
            isHeld = true
            lastMessage = L("Sleep was already disabled. Vela did not change this setting")
            return true
        }

        let directory = URL(fileURLWithPath: "/tmp/vela-lid-\(getuid())-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try LidWatchdogCommand.refreshLease(in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            lastMessage = L("Unable to create the closed-lid session marker")
            return false
        }
        let pid = getpid()
        let command = LidWatchdogCommand.make(pid: pid, directory: directory)
        let prompt = L("Vela will temporarily run /usr/bin/pmset -a disablesleep 1 and restore normal sleep when this closed-lid session ends or Vela quits.")
        let script = "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
        let result = await runAuthorization(script)
        let watchdog = Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let leaseReady = (try? LidWatchdogCommand.refreshLease(in: directory)) != nil
        var watchdogIdentity: String?
        if let watchdog, watchdog > 0 {
            watchdogIdentity = await Self.watchdogIdentity(pid: watchdog, directory: directory)
        }
        guard result.ok, let watchdog, watchdog > 0, leaseReady,
              await readDisabled() == true, let watchdogIdentity else {
            try? FileManager.default.removeItem(at: directory)
            if await readDisabled() == true {
                _ = await runAuthorization("do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
            }
            lastMessage = L("Administrator approval was canceled, or closed-lid settings and recovery monitoring could not be confirmed")
            return false
        }
        sessionDirectory = directory
        watchdogPID = watchdog
        watchdogBirth = watchdogIdentity
        changedSetting = true
        isHeld = true
        lastMessage = L("Closed-lid watch enabled. Normal sleep will be restored on stop or quit")
        return true
    }

    func heartbeat() async -> Bool {
        guard isHeld else { return false }
        if changedSetting, let sessionDirectory {
            do { try LidWatchdogCommand.refreshLease(in: sessionDirectory) }
            catch {
                isHeld = false
                lastMessage = L("Unable to update the closed-lid recovery heartbeat")
                return false
            }
        }
        let setting = await readDisabled()
        let watchdogOK: Bool
        if !changedSetting { watchdogOK = true }
        else if let watchdogPID, let sessionDirectory, let watchdogBirth,
                FileManager.default.fileExists(atPath: sessionDirectory.path) {
            watchdogOK = await Self.watchdogIdentity(pid: watchdogPID, directory: sessionDirectory) == watchdogBirth
        } else { watchdogOK = false }
        let ok = setting == true && watchdogOK
        if !ok {
            isHeld = false
            lastMessage = L("Closed-lid settings or recovery monitoring failed")
        }
        return ok
    }

    func close() async -> Bool {
        guard hasSession else { return true }
        if changedSetting {
            if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
            // The watchdog observes the deleted directory and restores within 2 seconds.
            for _ in 0..<30 {
                if await readDisabled() == false { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if await readDisabled() != false {
                let prompt = L("Vela needs to restore normal closed-lid sleep.")
                let result = await runAuthorization("do shell script \"/usr/bin/pmset -a disablesleep 0\" with prompt \"\(prompt)\" with administrator privileges")
                let restored = await readDisabled() == false
                if !result.ok || !restored {
                    lastMessage = L("Unable to confirm normal closed-lid sleep was restored. Check pmset -g")
                    isHeld = false
                    return false
                }
            }
        }
        let didChangeSetting = changedSetting
        sessionDirectory = nil
        watchdogPID = nil
        watchdogBirth = nil
        changedSetting = false
        isHeld = false
        lastMessage = didChangeSetting ? L("Normal closed-lid sleep restored") : L("Existing closed-lid sleep settings were not changed")
        return true
    }

    func disconnect() {
        if authorizationProcess?.isRunning == true { authorizationProcess?.terminate() }
        authorizationProcess = nil
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
        watchdogPID = nil
        watchdogBirth = nil
        changedSetting = false
        isHeld = false
    }

    func disconnectAndConfirmRestored() async -> Bool {
        let needsCheck = changedSetting || authorizationProcess != nil || sessionDirectory != nil
        disconnect()
        guard needsCheck else { return true }
        for _ in 0..<25 {
            if await readDisabled() == false { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func readDisabled() async -> Bool? {
        let result = await Self.run("/usr/bin/pmset", ["-g"])
        return result.ok ? LidPmsetOutput.sleepDisabled(result.output) : nil
    }

    private func runAuthorization(_ script: String) async -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let result: (ok: Bool, output: String) = await withCheckedContinuation { continuation in
            process.terminationHandler = { completed in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (completed.terminationStatus == 0,
                                                String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
                authorizationProcess = process
            } catch { continuation.resume(returning: (false, "")) }
        }
        if authorizationProcess === process { authorizationProcess = nil }
        return result
    }

    private nonisolated static func watchdogIdentity(pid: Int32, directory: URL) async -> String? {
        let result = await run("/bin/ps", ["-ww", "-p", String(pid), "-o", "lstart=", "-o", "stat=", "-o", "command="])
        guard result.ok else { return nil }
        let fields = result.output.split(maxSplits: 6, omittingEmptySubsequences: true,
                                         whereSeparator: { $0.isWhitespace })
        guard fields.count == 7, !fields[5].hasPrefix("Z"),
              fields[6].contains(directory.path) else { return nil }
        return fields.prefix(5).joined(separator: " ")
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> (ok: Bool, output: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
            } catch { return (false, "") }
        }.value
    }
}
