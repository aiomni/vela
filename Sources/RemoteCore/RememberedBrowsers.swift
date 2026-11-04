import Foundation

/// Browser credentials are random bearer secrets. Only their hashes reach disk.
public struct RememberedBrowsers: Sendable {
    public static let lifetime: TimeInterval = 30 * 24 * 3600
    public let files: RemoteFiles
    private struct Record: Codable {
        let digest: String
        let binding: String
        let issued: Date
        let expires: Date
    }
    public init(files: RemoteFiles) { self.files = files }
    public var url: URL { files.directory.appendingPathComponent("remembered-browsers.json") }

    public static func binding(configuration: RemoteConfiguration, fingerprint: String) throws -> String {
        struct Binding: Encodable {
            let generation: String
            let disconnectGeneration: Int
            let mode: RemoteAuthenticationMode
            let account: RemoteSystemAccount?
            let password: PasswordVerifier?
            let port: Int
            let fingerprint: String
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return RemoteSecurity.hash(try encoder.encode(Binding(generation: configuration.generation,
            disconnectGeneration: configuration.disconnectGeneration, mode: configuration.authenticationMode,
            account: configuration.systemAccount, password: configuration.password, port: configuration.port,
            fingerprint: fingerprint)))
    }

    public func issue(binding: String, replacing token: String?, now: Date = Date()) throws -> String {
        var records = try load().filter { valid($0, binding: binding, now: now) }
        if let token { records.removeAll { $0.digest == digest(token) } }
        guard records.count < 32 else { throw RemoteError.message("Too many remembered browsers. Revoke browser access on the host Mac.") }
        let secret = try RemoteSecurity.token()
        records.append(Record(digest: digest(secret), binding: binding, issued: now,
                              expires: now.addingTimeInterval(Self.lifetime)))
        try save(records)
        return secret
    }
    public func validate(_ token: String, binding: String, now: Date = Date()) throws -> Bool {
        guard Self.isCredential(token) else { return false }
        let key = digest(token)
        return try load().contains { $0.digest == key && valid($0, binding: binding, now: now) }
    }
    public func revoke(_ token: String) throws {
        guard Self.isCredential(token) else { return }
        let records = try load(), key = digest(token)
        if records.contains(where: { $0.digest == key }) { try save(records.filter { $0.digest != key }) }
    }
    private func valid(_ record: Record, binding: String, now: Date) -> Bool {
        record.binding == binding && now >= record.issued && now < record.expires &&
            record.expires.timeIntervalSince(record.issued) <= Self.lifetime
    }
    private func digest(_ token: String) -> String { RemoteSecurity.hash(Data(token.utf8)) }
    private func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536 else { throw RemoteError.message("Invalid browser registry.") }
            let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
            guard records.count <= 32 else { throw RemoteError.message("Invalid browser registry.") }
            return records
        } catch { throw RemoteError.message("Remembered browser data is unavailable.") }
    }
    private func save(_ records: [Record]) throws {
        do {
            try files.prepare()
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw RemoteError.message("Remembered browser data is unavailable.") }
    }
    public static func isCredential(_ token: String) -> Bool {
        guard token.utf8.count == 44, let data = Data(base64Encoded: token) else { return false }
        return data.count == 32 && data.base64EncodedString() == token
    }
}

/// Cookies authorize only the device-resume endpoint, never ordinary control APIs.
public enum RememberedBrowserCookie {
    public static func name(port: Int) -> String { "__Host-vela-browser-\(port)" }
    public static func read(_ header: String?, port: Int) -> String? {
        guard let header, header.utf8.count <= 4096 else { return nil }
        let values = header.split(separator: ";").compactMap { item -> String? in
            let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 && pair[0] == name(port: port) ? String(pair[1]) : nil
        }
        guard values.count == 1, let value = values.first, RememberedBrowsers.isCredential(value) else { return nil }
        return value
    }
    public static func set(_ token: String?, port: Int) -> String {
        let value = token.flatMap { RememberedBrowsers.isCredential($0) ? $0 : nil }
        return "\(name(port: port))=\(value ?? ""); Path=/; Max-Age=\(value == nil ? 0 : Int(RememberedBrowsers.lifetime)); Secure; HttpOnly; SameSite=Strict"
    }
}
