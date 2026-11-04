import Foundation
import Darwin
import RemoteNetworkBridge

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
    /// Routed IPv6 only: link-local addresses require an interface scope on each controller.
    public static func canonicalIPv6(_ value: String) -> String? {
        guard !value.utf8.contains(0) else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public static func isUnicastIPv6(_ value: String) -> Bool {
        guard let canonical = canonicalIPv6(value) else { return false }
        var address = in6_addr()
        _ = inet_pton(AF_INET6, canonical, &address)
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        return canonical != "::" && canonical != "::1" && bytes[0] != 0xff &&
            !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) &&
            !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff)
    }
    public static func authority(address: String, port: Int) -> String {
        "\(address.contains(":") ? "[\(address)]" : address):\(port)"
    }
    public static func allowsAuthority(_ authority: String, addresses: [String], port: Int) -> Bool {
        let suffix = ":\(port)"
        guard authority.hasSuffix(suffix) else { return false }
        let host = String(authority.dropLast(suffix.count))
        if host.hasPrefix("["), host.hasSuffix("]"),
           let canonical = canonicalIPv6(String(host.dropFirst().dropLast())) {
            return (addresses + ["::1"]).contains { canonicalIPv6($0) == canonical }
        }
        guard !host.contains(":") else { return false }
        return (addresses + ["127.0.0.1", "localhost"]).contains(host.lowercased())
    }
    struct InterfaceAddress {
        let interface: String
        let address: String
        var ipv6Flags: Int32? = nil
    }
    static func includes(interface: String, address: String, allInterfaces: Bool, ipv6Flags: Int32? = nil) -> Bool {
        guard allInterfaces || interface.hasPrefix("en") || interface.hasPrefix("bridge") else { return false }
        if isUnicastIPv4(address) { return true }
        guard isUnicastIPv6(address), let ipv6Flags else { return false }
        // Temporary source addresses must not rotate the server certificate or remembered-device binding.
        let excluded = IN6_IFF_NOTREADY | IN6_IFF_DETACHED | IN6_IFF_ANYCAST | IN6_IFF_CLAT46 |
            IN6_IFF_TEMPORARY | IN6_IFF_DEPRECATED
        return ipv6Flags & excluded == 0
    }
    static func addresses(from entries: [InterfaceAddress], allInterfaces: Bool = false) -> [String] {
        Set(entries.filter {
            includes(interface: $0.interface, address: $0.address, allInterfaces: allInterfaces, ipv6Flags: $0.ipv6Flags)
        }.map { canonicalIPv6($0.address) ?? $0.address }).sorted()
    }
    static func ipv6Flags(socketFD: Int32, interface: String, address: sockaddr_in6) -> Int32? {
        var flags: Int32 = 0
        var address = address
        guard VelaIPv6AddressFlags(socketFD, interface, &address, &flags) == 0 else { return nil }
        return flags
    }
    public static func addresses(allInterfaces: Bool = false) -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        let ipv6Socket = socket(AF_INET6, SOCK_DGRAM, 0)
        defer { if ipv6Socket >= 0 { close(ipv6Socket) } }
        var entries: [InterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
            // Enumerate real reachable addresses for the UI, certificate and Host
            // validation. The HTTPS bind address is configured independently.
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                var ipv6Flags: Int32?
                if address.pointee.sa_family == UInt8(AF_INET6), ipv6Socket >= 0 {
                    ipv6Flags = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        Self.ipv6Flags(socketFD: ipv6Socket, interface: name, address: $0.pointee)
                    }
                }
                entries.append(InterfaceAddress(interface: name, address: ip, ipv6Flags: ipv6Flags))
            }
        }
        return addresses(from: entries, allInterfaces: allInterfaces)
    }
}
