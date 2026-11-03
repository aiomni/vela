import Foundation
import Darwin

public struct RemoteConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var port = 8443
    public var listenOnAllInterfaces = false
    public var authenticationMode = RemoteAuthenticationMode.customPassword
    public var systemAccount: RemoteSystemAccount?
    public var password: PasswordVerifier?
    public var generation = UUID().uuidString
    public var disconnectGeneration = 0
    public var batteryFloor = 20
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, port, password, generation, disconnectGeneration, batteryFloor
        case authenticationMode, systemAccount, listenOnAllInterfaces
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        port = try c.decode(Int.self, forKey: .port)
        listenOnAllInterfaces = try c.decodeIfPresent(Bool.self, forKey: .listenOnAllInterfaces) ?? false
        password = try c.decodeIfPresent(PasswordVerifier.self, forKey: .password)
        generation = try c.decode(String.self, forKey: .generation)
        disconnectGeneration = try c.decode(Int.self, forKey: .disconnectGeneration)
        batteryFloor = try c.decode(Int.self, forKey: .batteryFloor)
        // Only an absent legacy field migrates. Null/unknown modes fail closed.
        authenticationMode = c.contains(.authenticationMode)
            ? try c.decode(RemoteAuthenticationMode.self, forKey: .authenticationMode) : .customPassword
        systemAccount = try c.decodeIfPresent(RemoteSystemAccount.self, forKey: .systemAccount)
    }
    public mutating func selectAuthentication(_ mode: RemoteAuthenticationMode, account: RemoteSystemAccount? = nil) throws {
        if mode == .macOSAccount {
            guard let account else { throw RemoteError.message("Confirm the local system account first.") }
            try account.validate()
            systemAccount = account
        } else { systemAccount = nil }
        authenticationMode = mode
        // Selecting a mode never enables remote access. Switching back without a saved password stops it.
        if mode == .customPassword && password == nil { enabled = false }
        generation = UUID().uuidString
        try validate()
    }
    public func validate() throws {
        guard (1024...65535).contains(port) else { throw RemoteError.message("The port must be an integer from 1024 to 65535.") }
        switch authenticationMode {
        case .customPassword:
            guard !enabled || password != nil else { throw RemoteError.message("Set an access password first.") }
        case .macOSAccount:
            guard let systemAccount else { throw RemoteError.message("Select a system account on the host Mac.") }
            try systemAccount.validate()
        }
        if let password { try password.validate() }
        guard (5...80).contains(batteryFloor) else { throw RemoteError.message("Invalid low battery threshold.") }
    }
}

public enum RemoteError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public struct RemoteHostStatus: Codable, Sendable {
    public var state = "stopped"
    public var message = "Remote control is off"
    public var addresses: [String] = []
    public var screenPermission = false
    public var inputPermission = false
    public var connected = false
    public var fingerprint: String?
    public var updated = Date()
    public var pid = Int32(0)
    public init() {}
}

/// Persistent remote settings and status. Never contains plaintext passwords or tokens.
public struct RemoteFiles: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }
    public static func defaultDirectory(applicationSupport: URL? = nil) -> URL {
        let support = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("AwakePet/RemoteControl", isDirectory: true)
        // Reuse the old store in place so settings, certificate trust, and the runtime lock survive renaming.
        // Prefer it even if a new directory exists: two versions must never own different locks.
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return support.appendingPathComponent("Vela/RemoteControl", isDirectory: true)
    }
    public var configurationURL: URL { directory.appendingPathComponent("configuration.json") }
    public var statusURL: URL { directory.appendingPathComponent("status.json") }
    public var certificateURL: URL { directory.appendingPathComponent("server.crt") }
    public var keyURL: URL { directory.appendingPathComponent("server.key") }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public func load() throws -> RemoteConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            var initial = RemoteConfiguration()
            initial.generation = "unconfigured"
            return initial
        }
        let value = try JSONDecoder().decode(RemoteConfiguration.self, from: Data(contentsOf: configurationURL))
        try value.validate()
        return value
    }
    public func save(_ configuration: RemoteConfiguration) throws {
        try configuration.validate()
        try prepare()
        try write(configuration, to: configurationURL)
    }
    public func status() -> RemoteHostStatus? {
        guard let data = try? Data(contentsOf: statusURL),
              let value = try? JSONDecoder().decode(RemoteHostStatus.self, from: data),
              Date().timeIntervalSince(value.updated) < 6 else { return nil }
        return value
    }
    public func writeStatus(_ status: RemoteHostStatus) throws { try write(status, to: statusURL) }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum LocalNetwork {
    public static func isUnicastIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let bytes = octets.compactMap { UInt8($0) }
        guard bytes.count == 4, bytes.map(String.init).joined(separator: ".") == value else { return false }
        return bytes[0] > 0 && bytes[0] != 127 && bytes[0] < 224
    }
    static func includes(interface: String, address: String, allInterfaces: Bool) -> Bool {
        isUnicastIPv4(address) && (allInterfaces || interface.hasPrefix("en") || interface.hasPrefix("bridge"))
    }
    public static func addresses(allInterfaces: Bool = false) -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: Set<String> = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            // Enumerate real reachable addresses for the UI, certificate and Host
            // validation. The HTTPS bind address is configured independently.
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if includes(interface: name, address: ip, allInterfaces: allInterfaces) { result.insert(ip) }
            }
        }
        return result.sorted()
    }
}
