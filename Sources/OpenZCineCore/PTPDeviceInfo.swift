import Foundation

/// Identity fields extracted from a standard PTP `DeviceInfo` dataset.
public struct PTPDeviceInfo: Equatable, Sendable {
    public init(data: Data) throws {
        var reader = PTPDeviceInfoReader(data: data)
        try reader.skip(byteCount: 2)
        try reader.skip(byteCount: 4)
        try reader.skip(byteCount: 2)
        try reader.skipString()
        try reader.skip(byteCount: 2)
        try reader.skipUInt16Array()
        try reader.skipUInt16Array()
        try reader.skipUInt16Array()
        try reader.skipUInt16Array()
        try reader.skipUInt16Array()

        manufacturer = try reader.readString()
        model = try reader.readString()
        deviceVersion = try reader.readString()
        serialNumber = try reader.readString()
    }

    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String
}

/// Errors that can occur while parsing PTP DeviceInfo.
public enum PTPDeviceInfoError: LocalizedError, Equatable, Sendable {
    /// The DeviceInfo dataset was shorter than expected.
    case truncatedDataset

    public var errorDescription: String? {
        switch self {
        case .truncatedDataset:
            "Camera DeviceInfo dataset was shorter than expected."
        }
    }
}

/// Produces concise camera names for startup and monitor UI.
public enum CameraDisplayNamePolicy {
    /// Builds a display name, preferring the camera-assigned PTP-IP name when available.
    public static func displayName(
        cameraName rawCameraName: String?,
        manufacturer rawManufacturer: String,
        model rawModel: String,
        fallback rawFallback: String = "Nikon camera"
    ) -> String {
        let cameraName = normalized(rawCameraName ?? "")
        if isUsefulCameraAssignedName(cameraName) {
            return cameraName
        }

        let manufacturer = normalizedManufacturer(rawManufacturer)
        let model = normalized(rawModel)
        if !model.isEmpty {
            guard !manufacturer.isEmpty else { return model }
            if model.localizedCaseInsensitiveContains(manufacturer) {
                return model
            }
            return "\(manufacturer) \(model)"
        }
        if !manufacturer.isEmpty {
            return manufacturer
        }

        let fallback = normalized(rawFallback)
        return fallback.isEmpty ? "Camera" : fallback
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedManufacturer(_ value: String) -> String {
        let manufacturer = normalized(value)
        switch manufacturer.lowercased() {
        case "nikon corporation", "nikon corp.", "nikon corp":
            return "Nikon"
        default:
            return manufacturer
        }
    }

    private static func isUsefulCameraAssignedName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.localizedCaseInsensitiveCompare("PTP-IP Camera") != .orderedSame
    }
}

private struct PTPDeviceInfoReader {
    init(data: Data) {
        self.bytes = Array(data)
    }

    private let bytes: [UInt8]
    private var offset = 0

    mutating func skip(byteCount: Int) throws {
        guard offset + byteCount <= bytes.count else {
            throw PTPDeviceInfoError.truncatedDataset
        }
        offset += byteCount
    }

    mutating func skipUInt16Array() throws {
        let count = Int(try readUInt32())
        try skip(byteCount: count * 2)
    }

    mutating func skipString() throws {
        let characterCount = Int(try readUInt8())
        try skip(byteCount: characterCount * 2)
    }

    mutating func readString() throws -> String {
        let characterCount = Int(try readUInt8())
        guard characterCount > 0 else { return "" }
        guard offset + characterCount * 2 <= bytes.count else {
            throw PTPDeviceInfoError.truncatedDataset
        }

        var codeUnits: [UInt16] = []
        for _ in 0..<characterCount {
            let unit = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            codeUnits.append(unit)
        }
        if codeUnits.last == 0 {
            codeUnits.removeLast()
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else {
            throw PTPDeviceInfoError.truncatedDataset
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else {
            throw PTPDeviceInfoError.truncatedDataset
        }
        defer { offset += 4 }
        return ByteCoding.readUInt32LE(bytes, at: offset)
    }
}
