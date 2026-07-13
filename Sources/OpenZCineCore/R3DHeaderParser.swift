import Foundation

/// Parses frame dimensions from the leading bytes of an on-card `.R3D` file.
///
/// Primary path: `RED1` atom layout from FFmpeg's R3D demuxer (width/height as big-endian UInt32 at
/// offsets 52 and 56 from the file start). Fallback: legacy 16-bit word offsets documented for RED One
/// REDV headers (54 / 60). Nikon ZR R3D NE uses REDCODE but the on-card header layout is unverified —
/// [ZR · verify-on-HW].
public enum R3DHeaderParser {
    /// Minimum bytes to attempt `RED1` width/height reads.
    public static let minimumHeaderBytes = 60

    /// Parses frame dimensions when the file begins with a `RED1` atom.
    public static func parseRED1Dimensions(from data: Data) -> (width: UInt32, height: UInt32)? {
        guard data.count >= minimumHeaderBytes else { return nil }
        let bytes = [UInt8](data.prefix(minimumHeaderBytes))
        guard bytes[4] == 0x52, bytes[5] == 0x45, bytes[6] == 0x44, bytes[7] == 0x31 else {
            return nil
        }
        let width = readUInt32BE(bytes, at: 52)
        let height = readUInt32BE(bytes, at: 56)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Parses frame dimensions using `RED1` first, then the legacy 16-bit word layout.
    public static func parseDimensions(from data: Data) -> (width: UInt32, height: UInt32)? {
        if let red1 = parseRED1Dimensions(from: data) { return red1 }
        guard data.count >= 62 else { return nil }
        let bytes = [UInt8](data.prefix(62))
        let width = UInt32(readUInt16BE(bytes, at: 54))
        let height = UInt32(readUInt16BE(bytes, at: 60))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}
