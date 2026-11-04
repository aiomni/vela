import XCTest
@testable import RemoteCore

final class RemoteStreamQualityTests: XCTestCase {
    private func decision(_ controller: inout DesktopQualityController, _ time: Double,
                          sample: DesktopStreamSample = .init(), moving: Bool = true,
                          viewport: (Int, Int)? = nil) -> DesktopStreamDecision {
        controller.update(now: time, sample: sample, moving: moving,
            baseWidth: 3840, baseHeight: 2160, baseFPS: 30, maximumBitrate: 48_000_000,
            viewportWidth: viewport?.0, viewportHeight: viewport?.1)
    }
    func testCongestionDowngradesThenRecoversWithHysteresis() {
        var controller = DesktopQualityController()
        let bad = DesktopStreamSample(lossRatio: 0.08)
        XCTAssertEqual(decision(&controller, 0, sample: bad).tier, 0)
        XCTAssertEqual(decision(&controller, 1, sample: bad).tier, 0)
        let first = decision(&controller, 2, sample: bad)
        XCTAssertEqual(first.tier, 1); XCTAssertEqual(first.fps, 20); XCTAssertEqual(first.width, 3840)
        XCTAssertEqual(decision(&controller, 3, sample: bad).tier, 1)
        XCTAssertEqual(decision(&controller, 5, sample: bad).tier, 2)
        XCTAssertEqual(decision(&controller, 8, sample: bad).tier, 3)
        let good = DesktopStreamSample(roundTripSeconds: 0.02, availableBitrate: 100_000_000, limitation: "bandwidth")
        XCTAssertEqual(decision(&controller, 9, sample: good).tier, 3)
        XCTAssertEqual(decision(&controller, 14, sample: good).tier, 3)
        XCTAssertEqual(decision(&controller, 15, sample: good).tier, 2)
        XCTAssertEqual(decision(&controller, 21, sample: good).tier, 1)
        XCTAssertEqual(decision(&controller, 27, sample: good).tier, 0)
    }
    func testStaticLowBitrateAndMissingMetricsDoNotCauseDowngrade() {
        var controller = DesktopQualityController()
        for time in 0...30 {
            let result = decision(&controller, Double(time), sample: .init(availableBitrate: 100_000, limitation: "bandwidth"), moving: false)
            XCTAssertEqual(result.tier, 0); XCTAssertEqual(result.state, "idle")
        }
        XCTAssertEqual(decision(&controller, 31).tier, 0)
    }
    func testViewportAndExplicitTextPreferencePreserveAspectAndUserChoice() {
        var controller = DesktopQualityController()
        let automatic = decision(&controller, 0, viewport: (1600, 1000))
        XCTAssertEqual(automatic.width, 1600); XCTAssertEqual(automatic.height, 900)
        controller.setPreference(.text)
        XCTAssertEqual(decision(&controller, 1, viewport: (1600, 1000)).width, 3840)
    }
    func testAutomaticViewportDoesNotBudgetAsAFull4KStream() {
        var controller = DesktopQualityController()
        for time in 0...10 {
            let result = decision(&controller, Double(time), sample: .init(roundTripSeconds: 0.02, availableBitrate: 5_000_000, limitation: "bandwidth"), viewport: (1920,1080))
            XCTAssertEqual(result.tier, 0)
        }
    }
    func testRefinementIsBoundedAndDoesNotReplaceIdleHeartbeat() {
        var cadence = DesktopFrameCadence()
        cadence.contentChanged(now: 10); cadence.submitted(now: 10, repeated: false)
        XCTAssertFalse(cadence.shouldRepeat(now: 10.2, refinementAllowed: true))
        for index in 0..<12 {
            let time = 10.36 + Double(index) * 0.08
            XCTAssertTrue(cadence.shouldRepeat(now: time, refinementAllowed: true))
            cadence.submitted(now: time, repeated: true)
        }
        XCTAssertFalse(cadence.isRefining(now: 11.3))
        XCTAssertTrue(cadence.shouldRepeat(now: 12.3, refinementAllowed: false))
        cadence.contentChanged(now: 20)
        XCTAssertTrue(cadence.isMoving(now: 20.1))
        XCTAssertEqual(cadence.refinementFrames, 0)
    }
    func testFeedbackRejectsUnboundedAndNonFiniteValues() {
        XCTAssertTrue(RemoteStreamFeedback().isValid)
        XCTAssertFalse(RemoteStreamFeedback(viewportWidth: 20000).isValid)
        XCTAssertFalse(RemoteStreamFeedback(decodeMilliseconds: .infinity).isValid)
        XCTAssertFalse(RemoteStreamFeedback(droppedFrameRatio: -0.1).isValid)
    }
}
