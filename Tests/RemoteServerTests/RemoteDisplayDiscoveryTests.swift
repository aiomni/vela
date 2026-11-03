import XCTest
import RemoteCore
@testable import RemoteServer

final class RemoteDisplayDiscoveryTests: XCTestCase {
    @MainActor
    func testSleepingDisplayAppearsAfterPreparationWithoutAnExistingPeer() async throws {
        let display = RemoteDisplay(id: 7, name: "fixture", width: 1920, height: 1080)
        var reads = 0, preparations = 0, waits = 0
        let result = try await RemoteDisplayDiscovery.discover(
            read: { reads += 1; return reads < 4 ? [] : [display] },
            needsPreparation: { $0.isEmpty }, prepare: { preparations += 1 },
            mayContinue: { true }, pause: { waits += 1 })
        XCTAssertEqual(result, [display])
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(waits, 3)
    }

    @MainActor
    func testExistingAwakeDisplayDoesNotRequestPowerActivity() async throws {
        let display = RemoteDisplay(id: 8, name: "fixture", width: 1920, height: 1080)
        let result = try await RemoteDisplayDiscovery.discover(
            read: { [display] }, needsPreparation: { _ in false },
            prepare: { XCTFail("An awake display must not be woken again") },
            mayContinue: { true }, pause: { XCTFail("No delay needed") })
        XCTAssertEqual(result, [display])
    }

    @MainActor
    func testSessionRevocationDuringWakeStopsDiscovery() async {
        var allowed = true, reads = 0
        do {
            _ = try await RemoteDisplayDiscovery.discover(
                read: { reads += 1; return [] }, needsPreparation: { _ in true }, prepare: {},
                mayContinue: { allowed }, pause: { allowed = false })
            XCTFail("Discovery must stop when authentication or console access changes")
        } catch { XCTAssertEqual(reads, 1) }
    }

    @MainActor
    func testUnavailableSessionDoesNotRequestPowerActivity() async {
        do {
            _ = try await RemoteDisplayDiscovery.discover(
                read: { XCTFail("Must validate before reading"); return [] },
                needsPreparation: { _ in true }, prepare: { XCTFail("Must not wake an unavailable session") },
                mayContinue: { false }, pause: {})
            XCTFail("Expected unavailable session")
        } catch {}
    }

    @MainActor
    func testMissingDisplaysHaveBoundedRetriesAndNoFabricatedDisplay() async {
        var waits = 0
        do {
            _ = try await RemoteDisplayDiscovery.discover(
                read: { [] }, needsPreparation: { _ in true }, prepare: {},
                mayContinue: { true }, pause: { waits += 1 })
            XCTFail("An empty topology must not become a successful connection")
        } catch { XCTAssertEqual(waits, 12) }
    }
}
