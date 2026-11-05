// An inert signed app fixture: it never starts a host, captures input, or takes power assertions.
import Foundation

@main
struct UpdateFixture {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--download-fixture" {
            let service = ReleaseUpdateService()
            guard let release = try ReleaseUpdate.parse(Data(contentsOf: URL(fileURLWithPath: arguments[3])), currentVersion: "0.0.2") else { throw UpdateError.invalidRelease }
            let candidate = try await service.prepare(release, installedApp: URL(fileURLWithPath: arguments[2]))
            UpdateInstaller.discardCandidate(candidate)
            print("PASS: GitHub release metadata, signed ZIP download, digest verification, extraction, and certificate validation")
        } else if arguments.count == 5, arguments[1] == "--install-fixture", let pid = Int32(arguments[4]) {
            try UpdateInstaller.install(candidate: URL(fileURLWithPath: arguments[2]),
                                        destination: URL(fileURLWithPath: arguments[3]), parentPID: pid)
        } else if arguments.count == 3, arguments[1] == "--validate-fixture" {
            let app = URL(fileURLWithPath: arguments[2])
            let identity = try UpdateSigningIdentity.read(from: app)
            let version = Bundle(url: app)!.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
            try UpdateInstaller.validateBundle(app, version: version, identity: identity)
        } else {
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            try Data(version.utf8).write(to: bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("relaunched-version.txt"))
        }
    }
}
