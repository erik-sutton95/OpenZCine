import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct LUTLibraryWireTests {
    @Test("imports the shared gate refuses never pack, so nothing is stored")
    func packingFailsClosed() {
        for text in [
            "not a cube",
            // Far-out-of-domain samples (RED float noise is ~1e-6).
            "LUT_3D_SIZE 2\n1.2 0 0\n",
            "LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n",
        ] {
            #expect(LUTLibraryWire.packedImportedLUT(utf8: Array(text.utf8)) == nil)
        }
        #expect(
            LUTLibraryWire.packedImportedLUT(
                utf8: Array(repeating: 120, count: CubeLUT.maximumImportBytes + 1)) == nil)
    }

    @Test("RED IPP2 float-export overshoot (1.000001) still packs")
    func redIpp2FloatOvershootPacks() throws {
        // Official RED size-33 packs export many lattice points as 1.000001. A hard
        // 0…1 gate rejected every cube after a successful zip extract.
        let redLike = """
            TITLE "RED IPP2 test"
            LUT_3D_SIZE 2
            0 0 0
            1.000001 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1.000001 1.000001 1.000001
            """
        let packed = try #require(LUTLibraryWire.packedImportedLUT(utf8: Array(redLike.utf8)))
        #expect(packed.count == 2 * 2 * 2 * 4)
        // Quantization clamps 1.000001 → 255.
        #expect(packed[4] == 255)
    }

    @Test("a 65³ Resolve cube packs as the 33³ renderer grid")
    func resolveSizedCubePacksForRenderer() throws {
        let packed = try #require(
            LUTLibraryWire.packedImportedLUT(utf8: Array(zeroCubeText(size: 65).utf8)))
        #expect(packed.count == 33 * 33 * 33 * 4)
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

    private func zeroCubeText(size: Int) -> String {
        var lines = ["LUT_3D_SIZE \(size)"]
        lines.reserveCapacity(size * size * size + 1)
        for _ in 0..<(size * size * size) {
            lines.append("0 0 0")
        }
        return lines.joined(separator: "\n")
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
