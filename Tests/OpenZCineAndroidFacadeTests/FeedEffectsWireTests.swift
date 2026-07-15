import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

/// The packed-2D payloads Compose uploads as effect textures must carry the
/// core's cube values exactly — pixel `(x = b·size + r, y = g)` ↔ red-fastest
/// cube index — and the scalar thresholds must be the core's, not re-derived.
struct FeedEffectsWireTests {
    /// RGBA of the packed pixel for cube lattice coordinates `(r, g, b)`.
    private func packedPixel(
        _ bytes: [UInt8], size: Int, r: Int, g: Int, b: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let offset = (g * size * size + b * size + r) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    /// The wire's own quantization, so expectations share the exact rounding.
    private func byte(_ value: Float) -> UInt8 {
        FeedEffectsWire.quantized(value)
    }

    @Test("Packed LUT grid carries MonitorLUT cube values byte-for-value")
    func packedLutMatchesCoreCube() throws {
        let size = 33
        let bytes = try #require(FeedEffectsWire.bakedLUT(lookOrdinal: 0, size: size))
        #expect(bytes.count == size * size * size * 4)
        let cube = MonitorLUT.log3G10Rec709.cube(size: size)
        for (r, g, b) in [(0, 0, 0), (32, 32, 32), (16, 8, 24), (32, 0, 0), (5, 21, 13)] {
            let index = (r + g * size + b * size * size) * 3
            let pixel = packedPixel(bytes, size: size, r: r, g: g, b: b)
            #expect(pixel.red == byte(cube.rgb[index]))
            #expect(pixel.green == byte(cube.rgb[index + 1]))
            #expect(pixel.blue == byte(cube.rgb[index + 2]))
            #expect(pixel.alpha == 255)
        }
    }

    @Test("Mono look bakes achromatic and neutral input maps near-identity greys")
    func monoLookIsAchromatic() throws {
        let size = 17
        let bytes = try #require(FeedEffectsWire.bakedLUT(lookOrdinal: 2, size: size))
        for (r, g, b) in [(0, 16, 8), (16, 0, 0), (4, 4, 4), (12, 3, 9)] {
            let pixel = packedPixel(bytes, size: size, r: r, g: g, b: b)
            #expect(pixel.red == pixel.green)
            #expect(pixel.green == pixel.blue)
        }
        // Neutral axis: Rec.709 luma of an achromatic input is the input itself
        // (±1 code for float rounding).
        let mid = packedPixel(bytes, size: size, r: 8, g: 8, b: 8)
        #expect(abs(Int(mid.red) - Int(byte(8.0 / 16.0))) <= 1)
    }

    @Test("False-colour grid matches the core cube and paints the documented clip zone")
    func falseColorCubeMatchesCore() throws {
        let bytes = try #require(FeedEffectsWire.bakedFalseColor(scaleOrdinal: 1, curveOrdinal: 0))
        let cube = FalseColorMap.cube(
            scale: .ire, mapping: ExposureSignalMapping(curve: .redLog3G10))
        let size = cube.size
        #expect(bytes.count == size * size * size * 4)
        for (r, g, b) in [(0, 0, 0), (63, 63, 63), (40, 20, 10), (10, 40, 55)] {
            let index = (r + g * size + b * size * size) * 3
            let pixel = packedPixel(bytes, size: size, r: r, g: g, b: b)
            #expect(pixel.red == byte(cube.rgb[index]))
            #expect(pixel.green == byte(cube.rgb[index + 1]))
            #expect(pixel.blue == byte(cube.rgb[index + 2]))
        }
        // Encoded 1.0 sits past the clip warning → the documented 99+ IRE red zone.
        let clip = packedPixel(bytes, size: size, r: 63, g: 63, b: 63)
        #expect(clip.red == byte(0.78))
        #expect(clip.green == byte(0.28))
        #expect(clip.blue == byte(0.18))
    }

    @Test("Scalars are the core's black/clip anchors and zebra thresholds")
    func scalarsCarryCoreThresholds() throws {
        let scalars = try #require(
            FeedEffectsWire.scalars(curveOrdinal: 0, zebraHighlightIRE: 100, zebraMidtoneIRE: 55))
        #expect(scalars.count == 4)
        let mapping = ExposureSignalMapping(curve: .redLog3G10)
        #expect(scalars[0] == Float(mapping.blackNative / 255))
        #expect(scalars[1] == Float(mapping.clipNative / 255))
        // Log3G10's default clip warning is native 180; monitor 100% maps onto it.
        #expect(scalars[1] == Float(180.0 / 255.0))
        #expect(scalars[2] == Float(mapping.signalNative(monitorPercent: 100) / 255))
        #expect(scalars[3] == Float(mapping.signalNative(monitorPercent: 55) / 255))
        #expect(scalars[2] > scalars[3])
        #expect(scalars[3] > scalars[0])
    }

    @Test("Camera mapping and renderer record follow the shared N-Log low-ISO policy")
    func cameraAwareRendererRecordUsesCoreMapping() throws {
        let mapping = ExposureSignalMapping.camera(codec: "N-Log", iso: 200, baseISO: nil)
        let payload = FeedEffectsWire.cameraMappingPayload(codec: "N-Log", iso: 200, baseISO: nil)
        #expect(
            payload == [
                1,
                Float(mapping.blackNative),
                Float(mapping.middleGrayNative),
                Float(mapping.clipNative),
            ])

        let render = try #require(
            FeedEffectsWire.renderConfiguration(
                codec: "N-Log", iso: 200, baseISO: nil,
                peakingSensitivityOrdinal: 2, peakingColorOrdinal: 1,
                highlightEnabled: false, highlightIRE: 96, highlightColorOrdinal: 3,
                midtoneEnabled: true, midtoneIRE: 42, midtoneColorOrdinal: 4))
        #expect(render.count == FeedEffectsWire.renderConfigurationFieldCount)
        #expect(render[0] == 1)
        #expect(render[1] == 200)
        #expect(render[7] == Float(0.022 * 0.06))
        #expect(render[12] == 0)
        #expect(render[17] == 1)
        #expect(render[13] == Float(mapping.signalNative(monitorPercent: 96) / 255))
        #expect(render[18] == Float(mapping.signalNative(monitorPercent: 42) / 255))
        let blue = Peaking.Color.blue.rgb
        #expect(Array(render[9...11]) == [Float(blue.0), Float(blue.1), Float(blue.2)])
    }

    @Test("Limits cubes preserve a separate paint and mask while reference bands stay core-owned")
    func limitsPayloadsAreAvailable() throws {
        let paint = try #require(
            FeedEffectsWire.bakedFalseColorLimitsPaint(curveOrdinal: 0, clipNative: 180))
        let weight = try #require(
            FeedEffectsWire.bakedFalseColorLimitsWeight(curveOrdinal: 0, clipNative: 180))
        #expect(paint.count == 64 * 64 * 64 * 4)
        #expect(weight.count == paint.count)
        let reference = try #require(
            FeedEffectsWire.falseColorReference(scaleOrdinal: 2, curveOrdinal: 0, clipNative: 180))
        #expect(reference[0] == 1)
        #expect(reference[1] == 0)
        #expect(reference[2] == 4)
        #expect(reference[3] == 0)
        #expect(reference.count == 4 + Int(reference[2]) * 5)
    }

    @Test("Unknown ordinals and unsupported sizes are rejected")
    func unknownOrdinalsAreRejected() {
        #expect(FeedEffectsWire.bakedLUT(lookOrdinal: 3, size: 33) == nil)
        #expect(FeedEffectsWire.bakedLUT(lookOrdinal: 0, size: 65) == nil)
        #expect(FeedEffectsWire.bakedFalseColor(scaleOrdinal: 2, curveOrdinal: 0) == nil)
        #expect(FeedEffectsWire.bakedFalseColor(scaleOrdinal: 0, curveOrdinal: 5) == nil)
        #expect(
            FeedEffectsWire.scalars(curveOrdinal: 9, zebraHighlightIRE: 100, zebraMidtoneIRE: 55)
                == nil)
    }
}
