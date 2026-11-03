import Foundation
import Darwin
import OpenDirectory

public enum RemoteAuthenticationMode: String, Codable, Sendable, CaseIterable {
    case customPassword
    case macOSAccount
}

/// Public account identifiers only. Never contains a password or directory credential.
public struct RemoteSystemAccount: Codable, Equatable, Sendable {
    public let uid: UInt32
    public let generatedUID: UUID
    public let shortName: String

    public init(uid: UInt32, generatedUID: UUID, shortName: String) {
        self.uid = uid; self.generatedUID = generatedUID; self.shortName = shortName
    }
    public func validate() throws {
        guard uid != 0, uid != UInt32.max, !shortName.isEmpty, shortName.utf8.count <= 256,
              !shortName.contains("/"), !shortName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteError.message("Invalid system account identity. Select the authentication method again in Settings.")
        }
    }
}

/// Injected in tests; the production implementation uses Apple's OpenDirectory API.
public protocol RemoteAccountDirectory: Sendable {
    func currentAccount() throws -> RemoteSystemAccount
    func authenticationAllowed(for account: RemoteSystemAccount) throws
    func verifyPassword(_ password: String, for account: RemoteSystemAccount) throws
}

public struct MacOSAccountDirectory: RemoteAccountDirectory {
    public init() {}

    private func record() throws -> (ODRecord, RemoteSystemAccount) {
        let uid = getuid()
        guard uid != 0, uid == geteuid() else {
            throw RemoteError.message("System authentication supports only the current standard user's local account.")
        }
        // Reentrant lookup: login validation and periodic policy checks can run concurrently.
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let name = try buffer.withUnsafeMutableBufferPointer { storage -> String in
            guard getpwuid_r(uid, &user, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let rawName = user.pw_name else {
                throw RemoteError.message("Unable to read the current local account identity.")
            }
            return String(cString: rawName)
        }
        // Never use the search node: a network/directory account must not become a fallback.
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: name,
                                    attributes: [kODAttributeTypeUniqueID, kODAttributeTypeGUID, kODAttributeTypeRecordName])
        let ids = try record.values(forAttribute: kODAttributeTypeUniqueID) as? [String]
        let guids = try record.values(forAttribute: kODAttributeTypeGUID) as? [String]
        guard ids?.count == 1, let rawUID = ids?.first, UInt32(rawUID) == uid,
              guids?.count == 1, let rawGUID = guids?.first, let guid = UUID(uuidString: rawGUID),
              let shortName = record.recordName else {
            throw RemoteError.message("Unable to confirm a stable local account identity. System authentication is disabled.")
        }
        let account = RemoteSystemAccount(uid: uid, generatedUID: guid, shortName: shortName)
        try account.validate()
        return (record, account)
    }
    public func currentAccount() throws -> RemoteSystemAccount { try record().1 }
    private func boundRecord(_ account: RemoteSystemAccount) throws -> ODRecord {
        let (record, current) = try record()
        guard current == account else { throw RemoteError.message("The system authentication account changed. Select the authentication method again on the host Mac.") }
        return record
    }
    public func authenticationAllowed(for account: RemoteSystemAccount) throws {
        try boundRecord(account).authenticationAllowed()
    }
    public func verifyPassword(_ password: String, for account: RemoteSystemAccount) throws {
        // verifyPassword also evaluates the account/password authentication policies.
        // Do not log OpenDirectory errors or persist the supplied password.
        try boundRecord(account).verifyPassword(password)
    }
}

public struct RemoteAuthenticator: Sendable {
    private let directory: any RemoteAccountDirectory
    public init(directory: any RemoteAccountDirectory = MacOSAccountDirectory()) { self.directory = directory }

    public func selectableSystemAccount() throws -> RemoteSystemAccount {
        let account = try directory.currentAccount()
        try account.validate()
        try directory.authenticationAllowed(for: account)
        return account
    }
    public func validate(_ configuration: RemoteConfiguration) throws {
        try configuration.validate()
        guard configuration.authenticationMode == .macOSAccount else { return }
        guard let account = configuration.systemAccount else { throw RemoteError.message("Select a system account on the host Mac.") }
        do {
            try account.validate()
            guard try directory.currentAccount() == account else { throw RemoteError.message("Account mismatch.") }
            try directory.authenticationAllowed(for: account)
        } catch {
            // No directory details, account policy internals, or credentials in status/logs.
            throw RemoteError.message("The bound local account cannot authenticate or its identity changed. Remote access is off. Check the account and authentication settings on the host Mac.")
        }
    }
    public func verify(_ password: String, configuration: RemoteConfiguration) -> Bool {
        guard !password.isEmpty, password.utf8.count <= 1024 else { return false }
        do {
            try validate(configuration)
            switch configuration.authenticationMode {
            case .customPassword: return configuration.password?.verify(password) == true
            case .macOSAccount:
                guard let account = configuration.systemAccount else { return false }
                try directory.verifyPassword(password, for: account)
                try validate(configuration)
                return true
            }
        } catch { return false }
    }

    /// Step-up authentication for operating a user session after a system lock.
    /// This does not change the configured web access password or unlock the console.
    public func verifyCurrentAccountPassword(_ password: String) -> Bool {
        guard !password.isEmpty, password.utf8.count <= 1024 else { return false }
        do {
            let account = try selectableSystemAccount()
            try directory.verifyPassword(password, for: account)
            return try selectableSystemAccount() == account
        } catch { return false }
    }
}
