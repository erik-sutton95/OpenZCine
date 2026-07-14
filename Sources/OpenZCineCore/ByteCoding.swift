import Foundation

/// Little/big-endian scalar codecs shared by the PTP/PTP-IP packet builders and
/// parsers — public so platform adapters (iOS shell, Android facade) frame
/// packets with the same primitives the core uses.
public enum ByteCoding {
    public static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0x00FF), UInt8((value >> 8) & 0x00FF)]
    }

    public static func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0x0000_00FF),
            UInt8((value >> 8) & 0x0000_00FF),
            UInt8((value >> 16) & 0x0000_00FF),
            UInt8((value >> 24) & 0x0000_00FF),
        ]
    }

    public static func uint64LE(_ value: UInt64) -> [UInt8] {
        [
            UInt8(value & 0x0000_0000_0000_00FF),
            UInt8((value >> 8) & 0x0000_0000_0000_00FF),
            UInt8((value >> 16) & 0x0000_0000_0000_00FF),
            UInt8((value >> 24) & 0x0000_0000_0000_00FF),
            UInt8((value >> 32) & 0x0000_0000_0000_00FF),
            UInt8((value >> 40) & 0x0000_0000_0000_00FF),
            UInt8((value >> 48) & 0x0000_0000_0000_00FF),
            UInt8((value >> 56) & 0x0000_0000_0000_00FF),
        ]
    }

    public static func int32LE(_ value: Int32) -> [UInt8] {
        uint32LE(UInt32(bitPattern: value))
    }

    public static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /// Big-endian uint16. The PTP containers are little-endian, but the Nikon LiveViewObject
    /// display-info header encodes its size/AF fields big-endian, so this pairs with `readUInt16BE`.
    public static func uint16BE(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0x00FF), UInt8(value & 0x00FF)]
    }

    public static func readUInt16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    public static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    public static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    public static func readInt32LE(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(bytes, at: offset))
    }

    public static func readUInt64LE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (index * 8)
        }
        return value
    }
}
