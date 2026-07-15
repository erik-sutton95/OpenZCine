import Foundation

/// A parsed Adobe/IRIDAS `.cube` 3D LUT.
///
/// `rgb` holds `size³` RGB triplets in the cube's canonical **red-fastest** order
/// (`index = (r + g·size + b·size²) · 3`), each component in `[0, 1]`. The domain is assumed 0–1
/// (the common case). This is a portable value type; turning it into a renderable form
/// (`CIColorCube`) is the platform shell's job.
public struct CubeLUT: Equatable, Sendable {
    /// Supported cube edge lengths. The lower bound (2) is the minimum for trilinear
    /// interpolation; the upper bound (64) is the maximum `inputCubeDimension` Core Image's
    /// `CIColorCube` accepts, and it also caps the table at ~3 MB so a corrupt or hostile
    /// `.cube` declaring a huge `LUT_3D_SIZE` cannot exhaust memory.
    public static let supportedSizeRange = 2...64

    /// Largest UTF-8 `.cube` source accepted by the portable parser. A 64³ table normally takes
    /// well under this limit, while the cap keeps an import made mostly of comments or oversized
    /// numeric tokens from allocating an unbounded `String`/sample buffer in a platform shell.
    public static let maximumSourceBytes = 16 * 1024 * 1024

    /// Edge length of the cube (e.g. 33 for a 33×33×33 LUT).
    public let size: Int

    /// `size³ × 3` samples in `[0, 1]`, red-fastest.
    public let rgb: [Float]

    public init(size: Int, rgb: [Float]) {
        self.size = size
        self.rgb = rgb
    }
}

/// Why a `.cube` payload could not be parsed.
public enum CubeLUTParseError: LocalizedError, Equatable {
    case sourceTooLarge(maximumBytes: Int)
    case missingSize
    case duplicateSize
    case unsupportedSize(Int)
    case unsupportedDomain
    case invalidSample
    case sampleCountMismatch(expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge(let maximumBytes):
            return
                "The .cube file is larger than the supported \(maximumBytes / 1024 / 1024) MB "
                + "limit."
        case .missingSize:
            return "The .cube file is missing its LUT_3D_SIZE declaration."
        case .duplicateSize:
            return "The .cube file declares LUT_3D_SIZE more than once."
        case .unsupportedSize(let size):
            return
                "The .cube file declares an unsupported LUT size of \(size). Supported sizes are "
                + "\(CubeLUT.supportedSizeRange.lowerBound)–\(CubeLUT.supportedSizeRange.upperBound)."
        case .unsupportedDomain:
            return
                "The .cube file declares a non-default input domain (DOMAIN_MIN/MAX); only the "
                + "standard 0–1 domain is supported."
        case .invalidSample:
            return "The .cube file contains a non-finite or out-of-range RGB sample."
        case .sampleCountMismatch(let expected, let found):
            return
                "The .cube file declares \(expected / 3) table entries but contains \(found / 3)."
        }
    }
}

extension CubeLUT {
    /// Parses a 3D `.cube` LUT: reads `LUT_3D_SIZE` and the RGB data triplets, skipping comments and
    /// metadata (`TITLE`, `LUT_1D_*`, …). A non-default `DOMAIN_MIN/MAX` is rejected (the renderer
    /// assumes a 0–1 input domain). Throws ``CubeLUTParseError`` on an oversized source, a
    /// missing/duplicate/oversized size, a non-default domain, a non-finite/out-of-range sample,
    /// or a triplet count that doesn't match `size³`.
    public static func parse(_ text: String) throws -> CubeLUT {
        guard text.utf8.count <= CubeLUT.maximumSourceBytes else {
            throw CubeLUTParseError.sourceTooLarge(maximumBytes: CubeLUT.maximumSourceBytes)
        }
        var size: Int?
        var values: [Float] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("LUT_3D_SIZE") {
                guard size == nil else { throw CubeLUTParseError.duplicateSize }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 2, let parsed = Int(fields[1]) {
                    // Validate the declared size *here*, before the data block is read, so a corrupt
                    // or hostile `LUT_3D_SIZE` (e.g. 1000 → 3 billion samples) is rejected up front
                    // rather than driving an unbounded allocation.
                    guard CubeLUT.supportedSizeRange.contains(parsed) else {
                        throw CubeLUTParseError.unsupportedSize(parsed)
                    }
                    size = parsed
                }
                continue
            }

            if line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                // The renderer assumes a 0–1 input domain. A .cube authored for a different domain
                // would silently get the wrong mapping, so reject it rather than apply bad colours.
                let expected: Float = line.hasPrefix("DOMAIN_MIN") ? 0 : 1
                let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .dropFirst().compactMap { Float($0) }
                guard comps.count >= 3, comps.prefix(3).allSatisfy({ $0 == expected }) else {
                    throw CubeLUTParseError.unsupportedDomain
                }
                continue
            }

            // Data rows begin with a number (or sign / decimal point); anything else is metadata.
            guard let first = line.first else { continue }
            let startsData =
                ("0"..."9").contains(first) || first == "+" || first == "-"
                || first == "."
            if !startsData { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3,
                let r = Float(fields[0]), let g = Float(fields[1]), let b = Float(fields[2])
            else { continue }
            guard r.isFinite, g.isFinite, b.isFinite,
                (0...1).contains(r), (0...1).contains(g), (0...1).contains(b)
            else { throw CubeLUTParseError.invalidSample }
            values.append(r)
            values.append(g)
            values.append(b)
        }

        guard let resolvedSize = size else { throw CubeLUTParseError.missingSize }
        let expected = resolvedSize * resolvedSize * resolvedSize * 3
        guard values.count == expected else {
            throw CubeLUTParseError.sampleCountMismatch(expected: expected, found: values.count)
        }
        return CubeLUT(size: resolvedSize, rgb: values)
    }
}

extension CubeLUT {
    /// RGBA float components (`size³ × 4`, red-fastest, alpha = 1) laid out for Core Image's
    /// `CIColorCube`, which expects the same red-fastest ordering this LUT already uses.
    public var rgbaComponents: [Float] {
        var out = [Float]()
        out.reserveCapacity(size * size * size * 4)
        var index = 0
        while index + 2 < rgb.count {
            out.append(rgb[index])
            out.append(rgb[index + 1])
            out.append(rgb[index + 2])
            out.append(1)
            index += 3
        }
        return out
    }

    /// Trilinear CPU sample of the cube — the same interpolation `CIColorCube` performs on the
    /// GPU, for callers that transform a handful of values (scope points) rather than a frame.
    /// Inputs clamp to the 0–1 domain; a malformed table returns the input unchanged.
    public func map(red: Float, green: Float, blue: Float) -> (
        red: Float, green: Float, blue: Float
    ) {
        let n = size
        guard n >= 2, rgb.count == n * n * n * 3 else { return (red, green, blue) }
        let scale = Float(n - 1)
        let fr = min(max(red, 0), 1) * scale
        let fg = min(max(green, 0), 1) * scale
        let fb = min(max(blue, 0), 1) * scale
        let r0 = Int(fr)
        let g0 = Int(fg)
        let b0 = Int(fb)
        let r1 = min(r0 + 1, n - 1)
        let g1 = min(g0 + 1, n - 1)
        let b1 = min(b0 + 1, n - 1)
        let tr = fr - Float(r0)
        let tg = fg - Float(g0)
        let tb = fb - Float(b0)

        func lattice(_ r: Int, _ g: Int, _ b: Int, _ channel: Int) -> Float {
            rgb[(r + g * n + b * n * n) * 3 + channel]
        }
        func sample(_ channel: Int) -> Float {
            let c00 = lattice(r0, g0, b0, channel) * (1 - tr) + lattice(r1, g0, b0, channel) * tr
            let c10 = lattice(r0, g1, b0, channel) * (1 - tr) + lattice(r1, g1, b0, channel) * tr
            let c01 = lattice(r0, g0, b1, channel) * (1 - tr) + lattice(r1, g0, b1, channel) * tr
            let c11 = lattice(r0, g1, b1, channel) * (1 - tr) + lattice(r1, g1, b1, channel) * tr
            let c0 = c00 * (1 - tg) + c10 * tg
            let c1 = c01 * (1 - tg) + c11 * tg
            return c0 * (1 - tb) + c1 * tb
        }
        return (sample(0), sample(1), sample(2))
    }
}
