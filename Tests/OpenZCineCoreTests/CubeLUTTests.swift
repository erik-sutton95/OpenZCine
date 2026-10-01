import Testing

@testable import OpenZCineCore

// Parser and interpolation tests moved to OpenCineCore (OpenCineMediaTests/CubeLUTTests).
// OpenZCine keeps the tests of its own renderer policy.

@Test func preparesResolveSizedCubeForTheRenderer() {
    let source = identityCube(size: 65)
    let prepared = source.preparedForRenderer()

    #expect(prepared.size == CubeLUT.rendererDisplaySize)
    #expect(prepared.rgb.count == 33 * 33 * 33 * 3)
    // 65³ → 33³ hits every other source lattice point exactly (k/32 = 2k/64).
    #expect(Array(prepared.rgb.prefix(3)) == [0, 0, 0])
    #expect(Array(prepared.rgb.suffix(3)) == [1, 1, 1])
    let mid = 16 + 16 * 33 + 16 * 33 * 33
    #expect(abs(prepared.rgb[mid * 3] - 0.5) < 0.0001)
    #expect(identityCube(size: 33).preparedForRenderer().size == 33)
}

@Test func resampledCubeKeepsSourceLatticeValues() {
    var rgb = [Float](repeating: 0, count: 65 * 65 * 65 * 3)
    // A non-identity black that must survive the even-lattice 65³ → 33³ reduction.
    rgb[0] = 0.2
    rgb[1] = 0.3
    rgb[2] = 0.4
    let prepared = CubeLUT(size: 65, rgb: rgb).preparedForRenderer()
    #expect(Array(prepared.rgb.prefix(3)) == [0.2, 0.3, 0.4])
}

/// Identity RGB cube: each lattice point maps to its own normalized coordinate.
private func identityCube(size: Int) -> CubeLUT {
    var rgb = [Float]()
    rgb.reserveCapacity(size * size * size * 3)
    let denominator = Float(size - 1)
    for b in 0..<size {
        for g in 0..<size {
            for r in 0..<size {
                rgb.append(Float(r) / denominator)
                rgb.append(Float(g) / denominator)
                rgb.append(Float(b) / denominator)
            }
        }
    }
    return CubeLUT(size: size, rgb: rgb)
}
