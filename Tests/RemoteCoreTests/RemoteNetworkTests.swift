import XCTest
import Darwin
@testable import RemoteCore

final class RemoteNetworkTests: XCTestCase {
    func testAllInterfacesAdvertisesRealTunnelAddressesButNeverWildcard() {
        // Synthetic private addresses exercise LAN and tunnel selection.
        XCTAssertFalse(LocalNetwork.includes(interface: "utun4", address: "10.0.0.2", allInterfaces: false))
        XCTAssertTrue(LocalNetwork.includes(interface: "utun4", address: "10.0.0.2", allInterfaces: true))
        XCTAssertTrue(LocalNetwork.includes(interface: "utun5", address: "10.0.0.3", allInterfaces: true))
        XCTAssertTrue(LocalNetwork.includes(interface: "en0", address: "192.168.1.2", allInterfaces: false))
        XCTAssertFalse(LocalNetwork.includes(interface: "en0", address: "0.0.0.0", allInterfaces: true))
        XCTAssertFalse(LocalNetwork.includes(interface: "lo0", address: "127.0.0.1", allInterfaces: true))
    }

    func testRoutedIPv6AndAuthorityValidation() {
        XCTAssertTrue(LocalNetwork.includes(interface: "en0", address: "fd00::2", allInterfaces: false, ipv6Flags: 0))
        XCTAssertFalse(LocalNetwork.includes(interface: "utun4", address: "fd00::2", allInterfaces: false, ipv6Flags: 0))
        XCTAssertTrue(LocalNetwork.includes(interface: "utun4", address: "2001:db8::2", allInterfaces: true, ipv6Flags: 0))
        for address in ["::", "::1", "fe80::2", "fe80::2%en0", "ff02::1", "::ffff:192.168.1.2", "invalid"] {
            XCTAssertFalse(LocalNetwork.isUnicastIPv6(address), address)
        }
        XCTAssertEqual(LocalNetwork.authority(address: "fd00::2", port: 8443), "[fd00::2]:8443")
        XCTAssertTrue(LocalNetwork.allowsAuthority("[FD00:0:0:0:0:0:0:2]:8443", addresses: ["fd00::2"], port: 8443))
        for host in ["[fd00::3]:8443", "[fd00::2]:8444", "fd00::2:8443", "[fd00::2].evil:8443", "user@[fd00::2]:8443"] {
            XCTAssertFalse(LocalNetwork.allowsAuthority(host, addresses: ["fd00::2"], port: 8443), host)
        }
    }

    func testIPv6AddressReadinessAndPrivacyFiltering() {
        let invalidFlags = [IN6_IFF_TENTATIVE, IN6_IFF_DUPLICATED, IN6_IFF_DETACHED,
                            IN6_IFF_ANYCAST, IN6_IFF_CLAT46, IN6_IFF_TEMPORARY, IN6_IFF_DEPRECATED]
        for allInterfaces in [false, true] {
            let stable = LocalNetwork.InterfaceAddress(interface: "en0", address: "fd00::2", ipv6Flags: IN6_IFF_AUTOCONF)
            let ipv4 = LocalNetwork.InterfaceAddress(interface: "en0", address: "192.168.1.2")
            let rejected = invalidFlags.enumerated().map { index, flags in
                LocalNetwork.InterfaceAddress(interface: "en0", address: "fd00::\(index + 10)", ipv6Flags: flags)
            } + [LocalNetwork.InterfaceAddress(interface: "en0", address: "fd00::99")]
            XCTAssertEqual(LocalNetwork.addresses(from: [stable, ipv4] + rejected, allInterfaces: allInterfaces),
                           ["192.168.1.2", "fd00::2"])
        }
        XCTAssertFalse(LocalNetwork.includes(interface: "utun4", address: "fd00::2", allInterfaces: false, ipv6Flags: 0))
        XCTAssertTrue(LocalNetwork.includes(interface: "utun4", address: "fd00::2", allInterfaces: true, ipv6Flags: 0))
        XCTAssertEqual(LocalNetwork.addresses(from: [
            .init(interface: "en0", address: "192.168.1.2"),
            .init(interface: "en0", address: "fd00::2", ipv6Flags: IN6_IFF_DUPLICATED)
        ]), ["192.168.1.2"])
    }

    func testIPv6FlagsQueryReadsKernelAndFailsClosed() throws {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &address.sin6_addr), 1)
        let flags = try XCTUnwrap(LocalNetwork.ipv6Flags(socketFD: descriptor, interface: "lo0", address: address))
        XCTAssertEqual(flags & IN6_IFF_NOTREADY, 0)
        XCTAssertNil(LocalNetwork.ipv6Flags(socketFD: -1, interface: "lo0", address: address))
        XCTAssertNil(LocalNetwork.ipv6Flags(socketFD: descriptor, interface: "vela-no-such-interface", address: address))
    }

    func testAllInterfaceSelectionPersistsAndLegacyRemainsLANOnly() throws {
        var config = RemoteConfiguration()
        config.listenOnAllInterfaces = true
        try config.validate()
        let data = try JSONEncoder().encode(config)
        XCTAssertTrue(try JSONDecoder().decode(RemoteConfiguration.self, from: data).listenOnAllInterfaces)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "listenOnAllInterfaces")
        XCTAssertFalse(try JSONDecoder().decode(RemoteConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).listenOnAllInterfaces)
        legacy["listenOnAllInterfaces"] = "true"
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }
}
