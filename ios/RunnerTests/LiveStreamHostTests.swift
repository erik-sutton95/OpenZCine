import XCTest

@testable import Runner

/// Live streaming's host values in OpenZCine: no route without a live picture, the shared
/// coordinator on the root model, and a clean look that never carries assists. SIMULATED (no
/// camera).
@MainActor
final class LiveStreamHostTests: XCTestCase {
    func testNoCameraMeansNoRouteAndTheControlSaysToConnectOne() throws {
        let model = NativeAppModel()
        XCTAssertNil(model.liveStreamRoute)
        XCTAssertNil(model.liveStreamSource)
        let stream = try XCTUnwrap(model.liveStream)
        XCTAssertEqual(stream.settingsState.eligibilityNote, "Connect a camera to go live.")
    }

    func testTheCleanLookCarriesNoAssists() {
        let effects = NativeAppModel().liveStreamEffects
        XCTAssertFalse(effects.peaking || effects.zebra || effects.falseColor)
        XCTAssertFalse(effects.splitComparison)
    }
}
