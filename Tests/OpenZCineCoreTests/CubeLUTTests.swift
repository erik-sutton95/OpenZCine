import Testing

@testable import OpenZCineCore

@Test func parsesValidTwoByTwoCube() throws {
    let text = """
        # a comment
        TITLE "demo"
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

    let lut = try CubeLUT.parse(text)

    #expect(lut.size == 2)
    #expect(lut.rgb.count == 2 * 2 * 2 * 3)
    #expect(Array(lut.rgb.prefix(3)) == [0, 0, 0])
    #expect(Array(lut.rgb.suffix(3)) == [1, 1, 1])
}

@Test func skipsDomainAndMetadataLines() throws {
    let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        0.5 0.5 0.5
        0.0 0.0 0.0
        0.0 0.0 0.0
        0.0 0.0 0.0
        0.0 0.0 0.0
        0.0 0.0 0.0
        1.0 1.0 1.0
        """

    let lut = try CubeLUT.parse(text)

    #expect(lut.size == 2)
    #expect(lut.rgb.count == 24)
    #expect(Array(lut.rgb[3..<6]) == [0.5, 0.5, 0.5])
}

@Test func rejectsNonDefaultInputDomain() {
    // A .cube authored for a non-0–1 domain would get the wrong mapping from the renderer, so the
    // parser rejects it rather than apply the wrong colours.
    let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 2.0 2.0 2.0
        0.0 0.0 0.0
        1.0 1.0 1.0
        """
    #expect(throws: CubeLUTParseError.unsupportedDomain) {
        try CubeLUT.parse(text)
    }
}

@Test func throwsWhenSizeDeclarationMissing() {
    #expect(throws: CubeLUTParseError.missingSize) {
        try CubeLUT.parse("0 0 0\n1 1 1\n")
    }
}

@Test func throwsWhenSampleCountDoesNotMatchSize() {
    let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 1 1
        """

    #expect(throws: CubeLUTParseError.self) {
        try CubeLUT.parse(text)
    }
}

@Test func rejectsDegenerateCubeSizeBelowTwo() {
    // A size of 1 has no interpolation domain; it must be rejected, not parsed.
    #expect(throws: CubeLUTParseError.unsupportedSize(1)) {
        try CubeLUT.parse("LUT_3D_SIZE 1\n0 0 0\n")
    }
}

@Test func rejectsCubeSizeAboveSupportedMaximum() {
    // 65 exceeds CIColorCube's maximum dimension (64); rendering it would fail silently.
    #expect(throws: CubeLUTParseError.unsupportedSize(65)) {
        try CubeLUT.parse("LUT_3D_SIZE 65\n0 0 0\n")
    }
}

@Test func rejectsAbsurdlyLargeDeclaredSizeWithoutAllocating() {
    // A corrupt/hostile file must be rejected on the size line, before the data block is
    // accumulated — otherwise size³ samples (here 3 billion) would exhaust memory.
    #expect(throws: CubeLUTParseError.unsupportedSize(1000)) {
        try CubeLUT.parse("LUT_3D_SIZE 1000\n0 0 0\n")
    }
}

@Test func parsesCubeAtMaximumSupportedSize() throws {
    // 64 is the boundary that must keep parsing — common high-quality LUTs ship at this size.
    let lut = try CubeLUT.parse(zeroCubeText(size: 64))

    #expect(lut.size == 64)
    #expect(lut.rgb.count == 64 * 64 * 64 * 3)
}

/// Builds a syntactically valid `.cube` of `size` filled with zeroed triplets.
private func zeroCubeText(size: Int) -> String {
    var lines = ["LUT_3D_SIZE \(size)"]
    lines.reserveCapacity(size * size * size + 1)
    for _ in 0..<(size * size * size) {
        lines.append("0 0 0")
    }
    return lines.joined(separator: "\n")
}
