import XCTest
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
