import VelaLocalization
import Foundation
import Darwin

/// Exercises the production command builder without administrator privileges or pmset.
func verifyLidWatchdog() throws {
    let root = URL(fileURLWithPath: "/tmp/vela-watchdog-test-\(UUID().uuidString)")
    let fakePmset = root.appendingPathComponent("pmset")
    let events = root.appendingPathComponent("events")
    let reject = root.appendingPathComponent("reject-enable")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let script = "#!/bin/sh\nif [ \"$3\" = 1 ] && [ -e \(reject.path) ]; then exit 1; fi\n/bin/echo \"$3\" >> \(events.path)\n"
    try script.write(to: fakePmset, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakePmset.path)

    func runCommand(parentPID: Int32, directory: URL, leaseSeconds: Int = 30) throws -> (Int32, String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try LidWatchdogCommand.refreshLease(in: directory)
        let command = LidWatchdogCommand.make(pid: parentPID, directory: directory,
                                              pmset: fakePmset.path, leaseSeconds: leaseSeconds)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(command)\""]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, response)
    }

    func launch(parentPID: Int32, directory: URL, leaseSeconds: Int = 30) throws -> Int32 {
        let (status, response) = try runCommand(parentPID: parentPID, directory: directory,
                                                leaseSeconds: leaseSeconds)
        guard status == 0,
              let pid = Int32(response.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw NSError(domain: "Vela.LidWatchdogTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("Recovery monitor startup handshake failed: {0}", "\(response)")])
        }
        return pid
    }

    func count(_ value: String) -> Int {
        let log = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { $0 == value }.count
    }

    func waitForRestores(_ expected: Int) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if count("0") >= expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func waitForSessionRemoval(_ directory: URL) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: directory.path) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    let stoppedSession = root.appendingPathComponent("stopped")
    let stoppedPID = try launch(parentPID: getpid(), directory: stoppedSession)
    precondition(kill(stoppedPID, 0) == 0 && count("1") == 1)
    try FileManager.default.removeItem(at: stoppedSession)
    precondition(waitForRestores(1), "Stopping the session did not restore sleep")

    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    parent.arguments = ["20"]
    try parent.run()
    let crashedSession = root.appendingPathComponent("parent-exit")
    let crashWatchdog = try launch(parentPID: parent.processIdentifier, directory: crashedSession)
    precondition(kill(crashWatchdog, 0) == 0 && count("1") == 2)
    parent.terminate()
    parent.waitUntilExit()
    precondition(waitForRestores(2), "Parent exit did not restore sleep")
    precondition(waitForSessionRemoval(crashedSession), "Parent exit left its lease directory")

    let refreshedSession = root.appendingPathComponent("refreshed")
    let refreshedWatchdog = try launch(parentPID: getpid(), directory: refreshedSession, leaseSeconds: 3)
    precondition(kill(refreshedWatchdog, 0) == 0 && count("1") == 3)
    for _ in 0..<5 {
        Thread.sleep(forTimeInterval: 1)
        try LidWatchdogCommand.refreshLease(in: refreshedSession)
    }
    precondition(count("0") == 2, "Fresh heartbeat ended an active session")
    try FileManager.default.removeItem(at: refreshedSession)
    precondition(waitForRestores(3), "Stopping a refreshed session did not restore sleep")

    let expiredSession = root.appendingPathComponent("expired")
    let expiredWatchdog = try launch(parentPID: getpid(), directory: expiredSession, leaseSeconds: 3)
    precondition(kill(expiredWatchdog, 0) == 0 && count("1") == 4)
    precondition(waitForRestores(4), "Expired heartbeat did not restore sleep")
    precondition(waitForSessionRemoval(expiredSession), "Expired heartbeat left its lease directory")

    try Data().write(to: reject)
    let failedSession = root.appendingPathComponent("rejected")
    let (failedStatus, _) = try runCommand(parentPID: getpid(), directory: failedSession)
    precondition(failedStatus != 0)
    precondition(count("1") == 4 && count("0") == 4, "Failed enable changed the setting")

    try FileManager.default.removeItem(at: reject)
    let missingParentSession = root.appendingPathComponent("missing-parent")
    let (missingParentStatus, _) = try runCommand(parentPID: Int32.max,
                                                 directory: missingParentSession)
    precondition(missingParentStatus != 0 && count("1") == 4,
                 "Missing parent unexpectedly enabled the setting")
    print("PASS: lid watchdog keeps a refreshed lease, restores on stop/parent exit/timeout, cleans stale sessions, and rejects failed enable or a missing parent")
}
