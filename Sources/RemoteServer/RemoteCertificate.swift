import Foundation
import RemoteCore

public enum RemoteCertificate {
    public static func prepare(files: RemoteFiles, addresses: [String]) throws -> String {
        try files.prepare()
        let metadata = files.directory.appendingPathComponent("certificate-addresses.json")
        let expected = Set(addresses + ["127.0.0.1"]).sorted()
        let saved = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        let exists = FileManager.default.fileExists(atPath: files.certificateURL.path)
        var valid = false
        if exists {
            valid = (try? run(["x509", "-checkend", "604800", "-noout", "-in", files.certificateURL.path])) != nil
        }
        if saved != expected || !valid {
            let config = files.directory.appendingPathComponent("certificate.cnf")
            let san = (["DNS:localhost"] + expected.map { "IP:\($0)" }).joined(separator: ",")
            let contents = """
            [req]
            distinguished_name = dn
            x509_extensions = server
            prompt = no
            [dn]
            CN = Vela Remote Desktop
            [server]
            subjectAltName = \(san)
            basicConstraints = critical,CA:FALSE
            keyUsage = critical,digitalSignature,keyEncipherment
            extendedKeyUsage = serverAuth
            """
            try contents.write(to: config, atomically: true, encoding: .utf8)
            if !FileManager.default.fileExists(atPath: files.keyURL.path) {
                _ = try run(["genrsa", "-out", files.keyURL.path, "3072"])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.keyURL.path)
            }
            let temporary = files.directory.appendingPathComponent("server-new.crt")
            _ = try run(["req", "-new", "-x509", "-sha256", "-days", "365", "-key", files.keyURL.path,
                         "-out", temporary.path, "-config", config.path])
            try Data(contentsOf: temporary).write(to: files.certificateURL, options: .atomic)
            try? FileManager.default.removeItem(at: temporary)
            try JSONEncoder().encode(expected).write(to: metadata, options: .atomic)
        }
        let der = try run(["x509", "-in", files.certificateURL.path, "-outform", "DER"])
        return RemoteSecurity.hash(der)
    }
    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RemoteError.message("Unable to generate or read the remote TLS certificate.") }
        return output
    }
}
