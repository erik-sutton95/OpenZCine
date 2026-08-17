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
    // 66 is past Resolve's 65³ standard and the parser's allocation cap.
    #expect(throws: CubeLUTParseError.unsupportedSize(66)) {
        try CubeLUT.parse("LUT_3D_SIZE 66\n0 0 0\n")
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
    // 65 is Resolve's standard high-resolution size and must parse.
    let lut = try CubeLUT.parse(zeroCubeText(size: 65))

    #expect(lut.size == 65)
    #expect(lut.rgb.count == 65 * 65 * 65 * 3)
}

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

/// Identity RGB cube — each lattice point maps to its own normalized coordinate.
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

/// Builds a syntactically valid `.cube` of `size` filled with zeroed triplets.
private func zeroCubeText(size: Int) -> String {
    var lines = ["LUT_3D_SIZE \(size)"]
    lines.reserveCapacity(size * size * size + 1)
    for _ in 0..<(size * size * size) {
        lines.append("0 0 0")
    }
    return lines.joined(separator: "\n")
}

/// Most Windows LUT tools author CRLF cubes. After the "\n" split every line keeps a trailing
/// "\r", and neither `Int("2\r")` nor `Float("0\r")` parses — so a perfectly valid file was
/// rejected as having no LUT_3D_SIZE at all (#295). The parser must treat "\r" as line junk.
@Test func parsesACRLFAuthoredCube() throws {
    let text =
        "# a comment\r\n"
        + "TITLE \"demo\"\r\n"
        + "LUT_3D_SIZE 2\r\n"
        + "DOMAIN_MIN 0.0 0.0 0.0\r\n"
        + "DOMAIN_MAX 1.0 1.0 1.0\r\n"
        + "0 0 0\r\n1 0 0\r\n0 1 0\r\n1 1 0\r\n"
        + "0 0 1\r\n1 0 1\r\n0 1 1\r\n1 1 1\r\n"

    let lut = try CubeLUT.parse(text)

    #expect(lut.size == 2)
    #expect(lut.rgb.count == 2 * 2 * 2 * 3)
    #expect(Array(lut.rgb.suffix(3)) == [1, 1, 1])
}
