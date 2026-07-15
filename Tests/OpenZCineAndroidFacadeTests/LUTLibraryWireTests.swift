import Foundation
import Testing

@testable import OpenZCineAndroidFacade

struct LUTLibraryWireTests {
    @Test("validation uses the shared selection cache key and strict parser")
    func validationCarriesCanonicalSelection() throws {
        let record = try #require(
            LUTLibraryWire.validatedImport(
                utf8: Array(identityCube.utf8),
                categoryOrdinal: LUTLibraryWire.CategoryOrdinal.custom,
                fileName: "operator-look-a1b2c3d4.cube"))
        #expect(
            record.components(separatedBy: LUTLibraryWire.fieldSeparator)
                == ["1", "2", "stored:Custom:operator-look-a1b2c3d4.cube"])
    }

    @Test("validation rejects unsafe file names and invalid cube bytes before storage")
    func validationFailsClosed() {
        #expect(
            LUTLibraryWire.validatedImport(
                utf8: Array(identityCube.utf8),
                categoryOrdinal: LUTLibraryWire.CategoryOrdinal.custom,
                fileName: "../outside.cube") == nil)
        #expect(
            LUTLibraryWire.validatedImport(
                utf8: Array("LUT_3D_SIZE 2\n1.2 0 0\n".utf8),
                categoryOrdinal: LUTLibraryWire.CategoryOrdinal.custom,
                fileName: "unsafe-samples.cube") == nil)
        #expect(
            LUTLibraryWire.validatedImport(
                utf8: Array(identityCube.utf8),
                categoryOrdinal: 99,
                fileName: "operator-look.cube") == nil)
    }

    @Test("Android validation rejects duplicate size declarations and oversized sources")
    func androidBoundaryLimits() {
        #expect(
            LUTLibraryWire.validatedImport(
                utf8: Array("LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n".utf8),
                categoryOrdinal: LUTLibraryWire.CategoryOrdinal.custom,
                fileName: "duplicate.cube") == nil)
        #expect(
            LUTLibraryWire.validatedImport(
                utf8: Array(repeating: 120, count: LUTLibraryWire.maximumSourceBytes + 1),
                categoryOrdinal: LUTLibraryWire.CategoryOrdinal.custom,
                fileName: "oversized.cube") == nil)
    }

    @Test("packed imported cubes use the feed renderer's existing 2D layout")
    func packedCubeUsesExistingRendererLayout() throws {
        let bytes = try #require(LUTLibraryWire.packedImportedLUT(utf8: Array(identityCube.utf8)))
        #expect(bytes.count == 2 * 2 * 2 * 4)
        // `(r = 1, g = 0, b = 1)` sits at x = b * size + r, y = g.
        let offset = (0 * 2 * 2 + 1 * 2 + 1) * 4
        #expect(Array(bytes[offset..<(offset + 4)]) == [255, 0, 255, 255])
    }

    @Test("versioned RED availability preserves the shared camera-AP precedence")
    func redAvailabilityUsesSharedPolicy() {
        #expect(
            LUTLibraryWire.redDownloadAvailability(
                hasInternetPath: true, isOnCameraAccessPoint: false)
                == "1\u{001F}0")
        #expect(
            LUTLibraryWire.redDownloadAvailability(
                hasInternetPath: true, isOnCameraAccessPoint: true)
                == "1\u{001F}1")
        #expect(
            LUTLibraryWire.redDownloadAvailability(
                hasInternetPath: false, isOnCameraAccessPoint: true)
                == "1\u{001F}1")
        #expect(
            LUTLibraryWire.redDownloadAvailability(
                hasInternetPath: false, isOnCameraAccessPoint: false)
                == "1\u{001F}2")
    }

    private let identityCube = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
}
