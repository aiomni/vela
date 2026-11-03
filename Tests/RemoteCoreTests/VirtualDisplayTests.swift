import XCTest
@testable import RemoteCore

final class VirtualDisplayTests: XCTestCase {
    func testPixelDimensionsAndHiDPIPointsAreSeparate() throws {
        let retina = VirtualDisplayConfiguration(width: 3840, height: 2160, hiDPI: true)
        try retina.validate()
        XCTAssertEqual(retina.logicalWidth, 1920); XCTAssertEqual(retina.logicalHeight, 1080)
        let portrait = VirtualDisplayConfiguration(width: 2160, height: 3840, hiDPI: true)
        try portrait.validate()
        XCTAssertEqual(portrait.logicalWidth, 1080); XCTAssertEqual(portrait.logicalHeight, 1920)
        let unscaled = VirtualDisplayConfiguration(width: 1920, height: 1080, hiDPI: false)
        try unscaled.validate(); XCTAssertEqual(unscaled.logicalWidth, 1920)
        XCTAssertEqual(try JSONDecoder().decode(VirtualDisplayConfiguration.self, from: JSONEncoder().encode(retina)), retina)
    }
    func testRejectsInvalidOrUnboundedModesBeforeCallingSystem() {
        for (width, height, hiDPI) in [(Int.max,Int.max,false),(-640,480,false),(639,480,false),
                                      (1921,1080,false),(1920,1081,false),(3840,3840,false),
                                      (7680,4320,false),(640,480,true),(1280,958,true)] {
            XCTAssertThrowsError(try VirtualDisplayConfiguration(width: width, height: height, hiDPI: hiDPI).validate())
        }
    }
}
