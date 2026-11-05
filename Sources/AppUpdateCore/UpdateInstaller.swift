import Foundation
import Security
import CryptoKit
import Darwin

public struct UpdateSigningIdentity {
    let requirement: SecRequirement
    let certificateHash: Data

    private static func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code else { throw UpdateError.invalidSignature }
        return code
    }

    private static func certificate(_ code: SecStaticCode) throws -> Data {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw UpdateError.invalidSignature }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }

    public static func read(from app: URL) throws -> Self {
        let code = try staticCode(app)
        var requirement: SecRequirement?
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { throw UpdateError.invalidSignature }
        return Self(requirement: requirement, certificateHash: try certificate(code))
    }

    public func validate(_ app: URL) throws {
        let code = try Self.staticCode(app)
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess,
              try Self.certificate(code) == certificateHash else { throw UpdateError.invalidSignature }
    }
}

public enum UpdateInstaller {
    public static func validateLocation(_ app: URL) throws {
        let path = app.standardizedFileURL.path
        guard app.pathExtension == "app", !path.hasPrefix("/Volumes/"),
              !path.contains("/AppTranslocation/"), !path.contains("/Contents/Applications/"),
              app.resolvingSymlinksInPath().path == path,
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: path) else { throw UpdateError.unsupportedLocation }
    }

    public static func validateArchiveEntries(_ listing: String) throws {
        let entries = listing.split(whereSeparator: \.isNewline)
        guard !entries.isEmpty, entries.count < 100_000 else { throw UpdateError.invalidDownload }
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.hasPrefix("/"), !components.contains(".."), !entry.contains("\\"),
                  components.first == "Vela.app" || components.first == "__MACOSX" else {
                throw UpdateError.invalidDownload
            }
        }
    }

    public static func validateArchiveSummary(_ summary: String) throws {
        let pattern = try NSRegularExpression(pattern: #"(\d+) bytes uncompressed"#)
        guard let match = pattern.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let range = Range(match.range(at: 1), in: summary),
              let bytes = Int64(summary[range]), bytes > 0, bytes <= 1024 * 1024 * 1024 else {
            throw UpdateError.invalidDownload
        }
    }

    public static func validateBundle(_ app: URL, version: String, identity: UpdateSigningIdentity) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "app.aiomni.awakepet",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              bundle.executableURL?.lastPathComponent == "Vela" else { throw UpdateError.invalidBundle }
        guard let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else {
            throw UpdateError.invalidBundle
        }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard (1...3).contains(parts.count), minimum.split(separator: ".").count == parts.count,
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0)) else { throw UpdateError.invalidBundle }
        let root = app.resolvingSymlinksInPath().path + "/"
        let items = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = items?.nextObject() as? URL {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                guard item.resolvingSymlinksInPath().path.hasPrefix(root) else { throw UpdateError.invalidBundle }
            }
        }
        try identity.validate(app)
        let controller = app.appendingPathComponent("Contents/Applications/VelaConnect.app")
        guard Bundle(url: controller)?.bundleIdentifier == "app.aiomni.awakepet.remoteviewer",
              Bundle(url: controller)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError.invalidBundle
        }
        guard try UpdateSigningIdentity.read(from: controller).certificateHash == identity.certificateHash else {
            throw UpdateError.invalidSignature
        }
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.processFailed }
        return String(decoding: data, as: UTF8.self)
    }

    // The temporary updater waits for the ordinary app shutdown, including remote/display recovery.
    public static func install(candidate: URL, destination: URL, parentPID: Int32) throws {
        let deadline = Date().addingTimeInterval(120)
        while kill(parentPID, 0) == 0 {
            guard Date() < deadline else { throw UpdateError.appStillRunning }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try validateLocation(destination)
        let identity = try UpdateSigningIdentity.read(from: destination)
        guard let version = Bundle(url: candidate)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let incoming = AppVersion(version),
              let installed = Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let current = AppVersion(installed), incoming > current else { throw UpdateError.invalidBundle }
        try validateBundle(candidate, version: version, identity: identity)
        let parent = destination.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".Vela-update-\(UUID().uuidString).app")
        do {
            try FileManager.default.copyItem(at: candidate, to: staged)
            try validateBundle(staged, version: version, identity: identity)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        try replaceApplication(staged: staged, destination: destination) { app in
            _ = try run("/usr/bin/open", ["-n", app.path])
        }
        discardCandidate(candidate)
    }

    public static func discardCandidate(_ candidate: URL) {
        let extracted = candidate.deletingLastPathComponent()
        let directory = extracted.deletingLastPathComponent()
        guard candidate.lastPathComponent == "Vela.app", extracted.lastPathComponent == "extracted",
              directory.lastPathComponent.hasPrefix("Vela-update-"),
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func replaceApplication(staged: URL, destination: URL, relaunch: (URL) throws -> Void) throws {
        func exchange() throws {
            let result = staged.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    renameatx_np(AT_FDCWD, source!, AT_FDCWD, target!, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else { throw UpdateError.processFailed }
        }
        // Exchange both directories atomically: the installed path always contains a complete app.
        do { try exchange() }
        catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        do { try relaunch(destination) }
        catch {
            // If rollback itself fails, retain the old app at the staged path for recovery.
            try exchange()
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        try? FileManager.default.removeItem(at: staged)
    }
}
