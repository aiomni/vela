import Foundation
import Security
import CryptoKit
import CommonCrypto

public struct PasswordVerifier: Codable, Equatable, Sendable {
    public let salt: Data
    public let digest: Data
    public let iterations: UInt32
    public static let defaultIterations: UInt32 = 600_000

    public init(password: String, iterations: UInt32 = defaultIterations) throws {
        guard password.count >= 10, password.utf8.count <= 1024 else {
            throw RemoteError.message("The access password must have at least 10 characters and at most 1024 bytes.")
        }
        self.salt = try RemoteSecurity.randomBytes(count: 32)
        self.iterations = iterations
        self.digest = try Self.derive(password, salt: salt, iterations: iterations)
        try validate()
    }
    public func validate() throws {
        guard salt.count == 32, digest.count == 32, iterations >= 100_000, iterations <= 2_000_000 else {
            throw RemoteError.message("Password verification data is damaged. Set the access password again.")
        }
    }
    public func verify(_ password: String) -> Bool {
        guard !password.isEmpty, password.utf8.count <= 1024, (try? validate()) != nil,
              let candidate = try? Self.derive(password, salt: salt, iterations: iterations) else { return false }
        return RemoteSecurity.constantTimeEqual(digest, candidate)
    }
    private static func derive(_ password: String, salt: Data, iterations: UInt32) throws -> Data {
        let bytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeBytes { secret in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: Int8.self),
                    bytes.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &output, output.count)
            }
        }
        guard result == kCCSuccess else { throw RemoteError.message("Unable to create a password verifier.") }
        return Data(output)
    }
}

public enum RemoteSecurity {
    public static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw RemoteError.message("System secure random number generation failed.")
        }
        return Data(bytes)
    }
    public static func token() throws -> String { try randomBytes(count: 32).base64EncodedString() }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Monotonic timestamps avoid clock changes bypassing retry delays.
public struct LoginRateLimiter: Sendable {
    private struct Entry: Sendable { var failures = 0; var next: TimeInterval = 0; var touched: TimeInterval = 0 }
    private var entries: [String: Entry] = [:]
    private var recentAttempts: [TimeInterval] = []
    public init() {}
    public mutating func begin(address: String, now: TimeInterval) -> Bool {
        entries = entries.filter { now - $0.value.touched < 3600 }
        recentAttempts.removeAll { now - $0 >= 60 }
        guard recentAttempts.count < 20, now >= (entries[address]?.next ?? 0) else { return false }
        guard entries.count < 1024 || entries[address] != nil else { return false }
        recentAttempts.append(now)
        var entry = entries[address] ?? Entry()
        entry.touched = now
        entries[address] = entry
        return true
    }
    public mutating func finish(address: String, success: Bool, now: TimeInterval) {
        if success { entries.removeValue(forKey: address); return }
        var entry = entries[address] ?? Entry()
        entry.failures = min(entry.failures + 1, 12)
        entry.next = now + (entry.failures < 3 ? 1 : min(300, pow(2, Double(entry.failures - 2))))
        entry.touched = now
        entries[address] = entry
    }
}

public struct SessionRegistry: Sendable {
    private struct Session: Sendable { let issued: TimeInterval; var touched: TimeInterval }
    private var sessions: [String: Session] = [:]
    public let absoluteLifetime: TimeInterval
    public let idleLifetime: TimeInterval
    public init(absoluteLifetime: TimeInterval = 8 * 3600, idleLifetime: TimeInterval = 120) {
        self.absoluteLifetime = absoluteLifetime; self.idleLifetime = idleLifetime
    }
    public mutating func issue(now: TimeInterval) throws -> String {
        expire(now: now)
        guard sessions.count < 8 else { throw RemoteError.message("Session limit reached. Try again later.") }
        let token = try RemoteSecurity.token()
        sessions[RemoteSecurity.hash(Data(token.utf8))] = Session(issued: now, touched: now)
        return token
    }
    public mutating func validate(_ token: String, now: TimeInterval, touch: Bool = true) -> Bool {
        guard token.utf8.count <= 128 else { return false }
        let key = RemoteSecurity.hash(Data(token.utf8))
        guard var session = sessions[key] else { return false }
        guard now - session.issued < absoluteLifetime, now - session.touched < idleLifetime else {
            sessions.removeValue(forKey: key); return false
        }
        if touch { session.touched = now; sessions[key] = session }
        return true
    }
    public mutating func revoke(_ token: String) { sessions.removeValue(forKey: RemoteSecurity.hash(Data(token.utf8))) }
    public mutating func revokeAll() { sessions.removeAll() }
    public mutating func expire(now: TimeInterval) {
        sessions = sessions.filter { now - $0.value.issued < absoluteLifetime && now - $0.value.touched < idleLifetime }
    }
}
