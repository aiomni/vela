import XCTest
import RemoteCore
@testable import RemoteServer

final class RemotePrivacyIntentTests: XCTestCase {
    func testAutomaticModeRequiresLockOrAllPhysicalDisplaysAsleep() {
        for locked in [false, true] {
            for asleep in [false, true] {
                var intent = RemotePrivacyIntent()
                XCTAssertEqual(intent.requiresIsolation(token: "auto", mode: .lockedOrAsleep, locked: locked, physicalDisplaysAsleep: asleep), locked || asleep)
                XCTAssertFalse(intent.requiresIsolation(token: "off", mode: .off, locked: locked, physicalDisplaysAsleep: asleep))
                XCTAssertTrue(intent.requiresIsolation(token: "always", mode: .always, locked: locked, physicalDisplaysAsleep: asleep))
            }
        }
    }

    func testDiscoveringPrivateDisplayCannotFallBackOnOfferOrRetry() {
        var intent = RemotePrivacyIntent()
        XCTAssertTrue(intent.requiresIsolation(token: "controller", mode: .lockedOrAsleep, locked: false, physicalDisplaysAsleep: true))
        XCTAssertTrue(intent.requiresIsolation(token: "controller", mode: .lockedOrAsleep, locked: false, physicalDisplaysAsleep: false))
        XCTAssertTrue(intent.requiresIsolation(token: "controller", mode: .off, locked: false, physicalDisplaysAsleep: false))
        XCTAssertFalse(intent.requiresIsolation(token: "other", mode: .off, locked: false, physicalDisplaysAsleep: false))
        intent.expire { _ in false }
        XCTAssertFalse(intent.requiresIsolation(token: "controller", mode: .off, locked: false, physicalDisplaysAsleep: false))
    }

    func testRestoreOverrideAppliesOnlyToCurrentControllerUntilEnd() {
        var intent = RemotePrivacyIntent()
        XCTAssertTrue(intent.requiresIsolation(token: "controller", mode: .always, locked: true, physicalDisplaysAsleep: true))
        intent.allowPhysicalDisplays(for: "controller")
        XCTAssertFalse(intent.requiresIsolation(token: "controller", mode: .always, locked: true, physicalDisplaysAsleep: true))
        XCTAssertTrue(intent.requiresIsolation(token: "other", mode: .always, locked: true, physicalDisplaysAsleep: true))
        intent.endConnection()
        XCTAssertTrue(intent.requiresIsolation(token: "controller", mode: .always, locked: true, physicalDisplaysAsleep: true))
    }
}
