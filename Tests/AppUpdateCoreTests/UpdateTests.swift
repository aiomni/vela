import XCTest
import CryptoKit
@testable import AppUpdateCore

final class UpdateTests: XCTestCase {
    func testVersionsNeverDowngradeOrTreatPrereleasesAsStable() {
        XCTAssertLessThan(AppVersion("v0.0.9")!, AppVersion("0.0.10")!)
        XCTAssertEqual(AppVersion("v1.2.3"), AppVersion("1.2.3"))
        for value in ["1.0", "1.2.3-beta.1", "-1.2.3", "1.2.3.4", "1/2/3", "999999999999999999999999999999.0.0"] {
            XCTAssertNil(AppVersion(value))
        }
        XCTAssertNil(try ReleaseUpdate.parse(release(), currentVersion: "0.0.4"))
        XCTAssertNil(try ReleaseUpdate.parse(release(), currentVersion: "0.0.5"))
    }

    func testSelectsSignedAssetAndRejectsUntrustedMetadata() throws {
        let selected = try XCTUnwrap(ReleaseUpdate.parse(release(), currentVersion: "0.0.3"))
        XCTAssertEqual(selected.version, "0.0.4")
        XCTAssertTrue(selected.assetURL.path.hasSuffix("-locally-signed.zip"))
        for changes: [String: Any] in [
            ["name": "Vela-0.0.4-macOS-arm64-unsigned.zip"],
            ["browser_download_url": "https://example.invalid/update.zip"],
            ["browser_download_url": "http://github.com/aiomni/vela/releases/download/v0.0.4/update.zip"],
            ["digest": "sha256:invalid"], ["size": 0], ["size": ReleaseUpdate.maximumArchiveSize + 1], ["state": "new"]
        ] {
            XCTAssertThrowsError(try ReleaseUpdate.parse(release(changes), currentVersion: "0.0.3"))
        }
        XCTAssertThrowsError(try ReleaseUpdate.parse(release(draft: true), currentVersion: "0.0.3"))
        XCTAssertThrowsError(try ReleaseUpdate.parse(release(prerelease: true), currentVersion: "0.0.3"))
    }

    func testArchiveDigestDetectsTruncationAndTampering() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("update.zip"), data = Data("signed archive fixture".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let update = ReleaseUpdate(version: "0.0.4", assetURL: URL(string: "https://github.com")!, digest: digest, size: data.count)
        try data.write(to: file)
        XCTAssertNoThrow(try update.verifyArchive(at: file))
        try Data("altered archive bytes".utf8).write(to: file)
        XCTAssertThrowsError(try update.verifyArchive(at: file))
        try data.dropLast().write(to: file)
        XCTAssertThrowsError(try update.verifyArchive(at: file))
    }

    func testArchivePathsCannotEscapeExtractionDirectory() throws {
        XCTAssertNoThrow(try UpdateInstaller.validateArchiveEntries("Vela.app/\nVela.app/Contents/MacOS/Vela\n__MACOSX/Vela.app/._Contents\n"))
        for entry in ["/Vela.app/file", "Vela.app/../../outside", "Vela.app/Contents/../outside", "Other.app/file", "Vela.app\\..\\file", ""] {
            XCTAssertThrowsError(try UpdateInstaller.validateArchiveEntries(entry))
        }
    }

    func testExpansionSizeIsBoundedBeforeExtractingTheArchive() throws {
        XCTAssertNoThrow(try UpdateInstaller.validateArchiveSummary("150 files, 123456789 bytes uncompressed, 30000000 bytes compressed: 76.0%"))
        XCTAssertThrowsError(try UpdateInstaller.validateArchiveSummary("2 files, 1073741825 bytes uncompressed, 100 bytes compressed"))
        XCTAssertThrowsError(try UpdateInstaller.validateArchiveSummary("unexpected output"))
    }

    func testCleanupNeverRemovesAnArbitraryCandidateDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("incoming/Vela.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        UpdateInstaller.discardCandidate(app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testUnsignedBundleCannotEstablishAnUpdateIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try UpdateSigningIdentity.read(from: directory))
    }

    func testFailedRelaunchRestoresOldApplication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("Vela.app"), staged = directory.appendingPathComponent("new.app"), backup = directory.appendingPathComponent("backup.app")
        try Data("old app".utf8).write(to: old)
        try Data("new app".utf8).write(to: staged)
        XCTAssertThrowsError(try UpdateInstaller.replaceApplication(staged: staged, destination: old) { installed in
            XCTAssertEqual(try Data(contentsOf: installed), Data("new app".utf8))
            throw UpdateError.processFailed
        })
        XCTAssertEqual(try Data(contentsOf: old), Data("old app".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testSuccessfulReplacementRelaunchesAtOriginalPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("Vela.app"), staged = directory.appendingPathComponent("new.app"), backup = directory.appendingPathComponent("backup.app")
        try Data("old app".utf8).write(to: old)
        try Data("new app".utf8).write(to: staged)
        var launched: URL?
        try UpdateInstaller.replaceApplication(staged: staged, destination: old) { launched = $0 }
        XCTAssertEqual(launched, old)
        XCTAssertEqual(try Data(contentsOf: old), Data("new app".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vela-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func release(_ changes: [String: Any] = [:], draft: Bool = false, prerelease: Bool = false) -> Data {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let name = "Vela-0.0.4-macOS-\(architecture)-locally-signed.zip"
        var asset: [String: Any] = ["name": name, "browser_download_url": "https://github.com/aiomni/vela/releases/download/v0.0.4/\(name)", "size": 100, "state": "uploaded", "digest": "sha256:" + String(repeating: "a", count: 64)]
        asset.merge(changes) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": "v0.0.4", "draft": draft, "prerelease": prerelease, "assets": [asset]])
    }
}
