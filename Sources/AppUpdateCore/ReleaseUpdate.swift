import Foundation
import CryptoKit

public struct AppVersion: Comparable, Sendable, Equatable {
    public let components: [Int]
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public enum UpdateError: Error {
    case invalidRelease, noSignedAsset, invalidDownload, invalidSignature, invalidBundle
    case unsupportedLocation, processFailed, appStillRunning, rateLimited
}

public struct ReleaseUpdate: Sendable, Equatable {
    public let version: String
    public let assetURL: URL
    public let digest: String
    public let size: Int
    public static let maximumArchiveSize = 256 * 1024 * 1024

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
            let size: Int
            let state: String
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    public static func parse(_ data: Data, currentVersion: String) throws -> Self? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let latest = AppVersion(release.tag_name), let current = AppVersion(currentVersion),
              release.tag_name.hasPrefix("v") else { throw UpdateError.invalidRelease }
        guard latest > current else { return nil }
        let version = String(release.tag_name.dropFirst())
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        for mode in ["signed", "locally-signed"] {
            let name = "Vela-\(version)-macOS-\(architecture)-\(mode).zip"
            if let asset = release.assets.first(where: { $0.name == name && $0.state == "uploaded" }) {
                let expected = "https://github.com/aiomni/vela/releases/download/\(release.tag_name)/\(name)"
                guard asset.browser_download_url.absoluteString == expected,
                      asset.size > 0, asset.size <= maximumArchiveSize,
                      let digest = asset.digest, digest.hasPrefix("sha256:"),
                      digest.count == 71,
                      digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw UpdateError.invalidRelease
                }
                return Self(version: version, assetURL: asset.browser_download_url,
                            digest: String(digest.dropFirst(7)), size: asset.size)
            }
        }
        throw UpdateError.noSignedAsset
    }

    public func verifyArchive(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            count += data.count
            guard count <= size else { throw UpdateError.invalidDownload }
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == size, actual == digest else { throw UpdateError.invalidDownload }
    }
}

private final class UpdateNetworkPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let hosts = ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        completionHandler(request.url?.scheme == "https" && hosts.contains(request.url?.host ?? "") ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ReleaseUpdate.maximumArchiveSize || totalBytesExpectedToWrite > ReleaseUpdate.maximumArchiveSize {
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public actor ReleaseUpdateService {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: UpdateNetworkPolicy(), delegateQueue: nil)
    }

    public func check(currentVersion: String) async throws -> ReleaseUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/aiomni/vela/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Vela-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, [403, 429].contains(http.statusCode) {
            throw UpdateError.rateLimited
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 2 * 1024 * 1024 else { throw UpdateError.invalidRelease }
        return try ReleaseUpdate.parse(data, currentVersion: currentVersion)
    }

    public func prepare(_ update: ReleaseUpdate, installedApp: URL) async throws -> URL {
        try UpdateInstaller.validateLocation(installedApp)
        let identity = try UpdateSigningIdentity.read(from: installedApp)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Vela-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let (download, response) = try await session.download(from: update.assetURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url?.scheme == "https" else { throw UpdateError.invalidDownload }
            let archive = directory.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: download, to: archive)
            try update.verifyArchive(at: archive)
            let listing = try UpdateInstaller.run("/usr/bin/tar", ["-tf", archive.path])
            try UpdateInstaller.validateArchiveEntries(listing)
            let summary = try UpdateInstaller.run("/usr/bin/zipinfo", ["-t", archive.path])
            try UpdateInstaller.validateArchiveSummary(summary)
            let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
            _ = try UpdateInstaller.run("/usr/bin/tar", ["-xf", archive.path, "-C", extracted.path, "--no-same-owner", "Vela.app"])
            let candidate = extracted.appendingPathComponent("Vela.app", isDirectory: true)
            try UpdateInstaller.validateBundle(candidate, version: update.version, identity: identity)
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
