import OpenCineAppKit
import XCTest

@testable import Runner

/// ZIB-469: sharing a still opened the clip popup with Bake LUT on, MOV/MP4 and a `.mov` name,
/// while the original still was delivered. The popup now knows which files are stills.
final class NikonStillDeliveryTests: XCTestCase {
    func testStillsAndMoviesAreToldApartForThePopup() {
        let still = MediaClip(
            cameraID: "SIMULATED", filename: "DSC_0001.JPG", handle: 1,
            storageID: 65_537, sizeBytes: 4, captureDate: "")
        let movie = MediaClip(
            cameraID: "SIMULATED", filename: "DSC_0002.MOV", handle: 2,
            storageID: 65_537, sizeBytes: 4, captureDate: "")
        XCTAssertEqual(NikonDelivery.selectionFile(still).isStill, true)
        XCTAssertEqual(NikonDelivery.selectionFile(movie).isStill, false)
        XCTAssertEqual(NikonDelivery.selectionFile(still).filename, "DSC_0001.JPG")
        let selection = MonitorDeliverySelectionFacts(
            files: [NikonDelivery.selectionFile(still)],
            cachedCount: 1, connected: nil)
        XCTAssertTrue(selection.allStills)
    }
}
