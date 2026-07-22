import Foundation

/// PTP-IP `Operation_Request` DataPhaseInfo values.
public enum PTPDataPhase: UInt32, Sendable {
    /// No data phase, or a data-IN operation accepted by the ZR.
    case noDataOrDataIn = 1

    /// Host-to-camera data phase.
    case dataOut = 2

    /// Canonical camera-to-host data phase.
    case dataIn = 3
}

/// PTP operation codes used by OpenZCine.
///
/// Case names mirror their libgphoto2 symbols (`PTP_OC_*` / `PTP_OC_NIKON_*` in `camlibs/ptp2/
/// ptp.h`); see `docs/nikon-mtp.md` for the sourcing policy. Codes absent from libgphoto2 are
/// tagged `[ZR-only · verify-on-HW]` until confirmed against the camera.
public enum PTPOperationCode: UInt16, Sendable {
    // Session (PIMA 15740).
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003

    // Storage + object browsing (PIMA 15740) — the Media page's clip listing/fetch path. The ZR's
    // movie format codes and large-clip (≥ 4 GiB) behaviour are unverified — [ZR · verify-on-HW].
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005  // p1 storageID; data-in (capacity/free-space dataset)
    case getObjectHandles = 0x1007  // p1 storageID, p2 formatCode, p3 association; data-in
    case getObjectInfo = 0x1008  // p1 objectHandle; data-in (ObjectInfo dataset)
    case getThumb = 0x100A  // p1 objectHandle; data-in (embedded JPEG thumbnail)
    case getPartialObject = 0x101B  // p1 objectHandle, p2 offset, p3 maxBytes; data-in
    case getDevicePropDesc = 0x1014
    case getDevicePropValue = 0x1015
    // Returns the *valid* (card-present) StorageIDs. Standard GetStorageIDs reports placeholder
    // per-slot IDs even with a card inserted, and GetStorageInfo rejects those.
    case getVendorStorageIDs = 0x9209
    /// `PTP_OC_NIKON_GetObjectSize`: p1 objectHandle; data-in UINT64 size. [VERIFY-ON-HW]
    case getObjectSize = 0x9421
    /// `PTP_OC_NIKON_GetPartialObjectEx`: p1 handle, p2/p3 offset low/high, p4/p5 maximum bytes
    /// low/high; data-in. [VERIFY-ON-HW]
    case getPartialObjectEx = 0x9431

    // Pairing + session mode. [ZR-only · verify-on-HW]
    case getPairingInfo = 0x952B
    case confirmPairing = 0x935A
    case changeApplicationMode = 0x9435
    // p1 0 PC-camera mode / 1 remote mode. Over USB the ZR boots into
    // PC-camera mode and denies vendor app-control until remote mode is set;
    // Wi-Fi smart-device sessions arrive already trusted. [verify-on-HW]
    case changeCameraMode = 0x90C2

    // Properties. 2-byte `0xDxxx` props use the standard PIMA 15740 ops (0x1015/0x1016); the `Ex`
    // ops serve the 4-byte `0x0001_Dxxx` extended props. Ex-writing a 2-byte recording-format
    // property makes the ZR close the connection — those must go through 0x1016.
    case getVendorCodes = 0x9439
    case getDevicePropDescEx = 0x943A
    case getDevicePropValueEx = 0x943B
    case setDevicePropValueEx = 0x943C
    case setDevicePropValue = 0x1016

    // Still capture (card / SDRAM / media destination). Cross-body Z-series.
    /// PIMA still capture to card (`PTP_OC_InitiateCapture`).
    case initiateCapture = 0x100E
    /// Vendor still capture with destination parameter (`PTP_OC_NIKON_InitiateCaptureRecInMedia`).
    case initiateCaptureRecInMedia = 0x9207
    /// Vendor still capture buffered in camera SDRAM for host pull.
    case initiateCaptureRecInSdram = 0x90C0
    /// AF then capture into SDRAM.
    case afAndCaptureRecInSdram = 0x90CB
    /// Ends bulb / open capture started via media capture path.
    case terminateCapture = 0x920C
    /// Interval / focus-shift / open capture start. [VERIFY-ON-HW]
    case initiateOpenCaptureV = 0x9445
    /// Interval / focus-shift / open capture stop. [VERIFY-ON-HW]
    case terminateOpenCaptureV = 0x9446
    /// Open-capture status dataset. [VERIFY-ON-HW]
    case getOpenCaptureInfo = 0x9447

    // Live view, record, AF.
    case startLiveView = 0x9201
    case endLiveView = 0x9202
    case startMovieRecInCard = 0x920A  // no parameters, no data phase
    case endMovieRec = 0x920B  // no parameters, no data phase
    case getLiveViewImageEx = 0x9428
    case changeAfArea = 0x9205  // p1 x, p2 y — moves the live-view AF area
    case afDrive = 0x90C1
    case afDriveCancel = 0x9206
    case mfDrive = 0x9204
    case endTracking = 0x9425  // [ZR-only · verify-on-HW]
    case changeAELock = 0x9426
    case deviceReady = 0x90C8
    case getEvent = 0x90C7
    case getEventEx = 0x941C
}

/// Vendor PTP device-property codes referenced by the core.
///
/// Same sourcing rule as `PTPOperationCode`: case names mirror the `PTP_DPC_*` /
/// `PTP_DPC_NIKON_*` symbols in libgphoto2 `ptp.h`. Where libgphoto2 carries a code but no value
/// table, the value encoding is app-decoded and verify-on-HW; codes absent from libgphoto2
/// entirely are tagged `[ZR-only · verify-on-HW]`.
public enum PTPPropertyCode: UInt32, Sendable {
    // Live view + record state.
    case liveViewProhibitionCondition = 0xD1A4
    case liveViewImageSize = 0xD1AC
    case liveViewImageCompression = 0xD1BC
    case movieRecProhibitionCondition = 0xD0A4
    case movieRecordScreenSize = 0xD0A0
    case movieFileType = 0xD0AF

    // Exposure.
    case isoControlSensitivity = 0xD0B5
    /// Movie ISO auto/manual control (libgphoto2 `PTP_DPC_NIKON_MovISOAutoControl`).
    /// UINT8 On/Off — independent of exposure-program Auto (0x500E). MAID: MovieISOControl bool.
    case movieISOAutoControl = 0xD0AD
    /// Movie exposure index / video ISO write (libgphoto2 `PTP_DPC_NIKON_MovieISO` / design docs).
    /// UINT32. Rejected on R3D NE — dual-base uses `movieISOSensitivity` instead.
    case movieExposureIndex = 0xD1AA
    case movieBaseISO = 0x0001_D09D  // [ZR-only · verify-on-HW]
    /// Dual-base working video ISO (ZR). Range follows Low/High base circuit.
    case movieISOSensitivity = 0x0001_D09E  // [ZR-only · verify-on-HW]
    case movieShutterMode = 0x0001_D074  // UINT8: 1 speed, 2 angle [ZR-only · verify-on-HW]
    case movieTVLockSetting = 0x0001_D00F  // movie shutter speed/angle lock
    case movieShutterSpeed = 0xD1A8
    case movieShutterAngle = 0x0001_D075  // [ZR-only · verify-on-HW]
    case movieFNumber = 0xD1A9

    // White balance. The WB fine-tune ("tint") block is one property per WB mode; libgphoto2 has
    // the codes but no value tables, so the tint encoding is app-decoded. [verify-on-HW]
    case movieWhiteBalance = 0xD23A
    case movieWBColorTemp = 0xD21A
    case movieWbTuneAuto = 0xD212
    case movieWbTuneIncandescent = 0xD213
    case movieWbTuneFluorescent = 0xD215
    case movieWbTuneSunny = 0xD216
    case movieWbTuneCloudy = 0xD218
    case movieWbTuneShade = 0xD219
    case movieWbTuneColorTemp = 0xD21B
    case movieWbTuneNatural = 0xD23C

    // Body + lens status.
    case batteryLevel = 0x5001  // ZR reports only 1/20/40/60/80/100 — a 5-bar gauge
    case focalLength = 0x5008
    case exposureProgramMode = 0x500E  // read-only MODE-tile poll; the dial owns it [verify-on-HW]
    case lensID = 0xD0E0
    case lensFocalMin = 0xD0E3
    case lensFocalMax = 0xD0E4
    case lensApertureMin = 0xD0E5
    case acPower = 0xD101  // non-zero on external/USB power; drives the charging indicator
    // Aggregate warning bitfield. Bit positions are runtime-enumerated by the body — the overheat
    // bit is decoded behind the `CameraWarningStatus` verify-on-HW seam (TEMP tile + thermal
    // live-view step-down), not a guessed constant.
    case warningStatus = 0xD102

    // Movie AF. Value tables are app-decoded (no libgphoto2 config.c tables). [verify-on-HW]
    case movieFocusMode = 0xD1FA
    case movieFocusMeteringMode = 0xD1F8  // libgphoto2 names this `MovieAfAreaMode`
    case movieAFSubjectDetection = 0x0001_D006

    // Audio + stabilisation. Value tables are app-decoded. [verify-on-HW]
    case movMicrophone = 0xD0A2
    case movRecordMicrophoneLevelValue = 0xD0A8
    case movWindNoiseReduction = 0xD0AA
    case movieAttenuator = 0xD23D
    case audioInputSelection = 0x0001_D04D  // 1 mic, 2 line [ZR-only · verify-on-HW]
    case movie32BitFloatAudioRecording = 0x0001_D065  // 0/1 [ZR-only · verify-on-HW]
    case movieAudioInputSensitivity = 0x0001_D070  // 0xFF auto, 1…20 [ZR-only · verify-on-HW]
    case gridDisplay = 0xD16C  // viewfinder framing grid on/off [verify-on-HW]
    case electronicVR = 0xD314
    case electronicFrontCurtainShutter = 0xD20D  // stills-only; not polled
    case movieVibrationReduction = 0xD1F9

    // Still / photo-mode controls (cross-body Z-series). Polled when
    // `LiveViewSelector` reports photo mode; movie-path props stay preferred in video.
    /// Photo vs video live-view selector (`PTP_DPC_NIKON_LiveViewSelector`). UINT8: 0 photo, 1 video.
    case liveViewSelector = 0xD1A6
    case imageSize = 0x5003
    case compressionSetting = 0x5004
    case whiteBalance = 0x5005
    case fNumber = 0x5007
    case focusMode = 0x500A
    case exposureMeteringMode = 0x500B
    case flashMode = 0x500C
    case exposureTime = 0x500D
    case exposureIndex = 0x500F
    case exposureBiasCompensation = 0x5010
    /// Release / drive mode (`PTP_DPC_StillCaptureMode`).
    case stillCaptureMode = 0x5013
    case burstNumber = 0x5018
    case stillFocusMode = 0xD061
    case stillFocusMeteringMode = 0xD05D
    case stillISOAutoControl = 0xD054
    case stillShutterSpeed = 0xD100
    case recordingMedia = 0xD10B
    case rawCompressionType = 0xD016
}

/// PTP response codes used by the app.
public enum PTPResponseCode: UInt16, Sendable {
    case ok = 0x2001
    // Over USB, ImageCaptureCore holds the PTP session itself, so the app's own OpenSession can
    // return this — the session is usable; the open didn't fail.
    case sessionAlreadyOpen = 0x201E
    case deviceBusy = 0x2019
    case unknown = 0xFFFF
}

/// Builds the payload for a PTP-IP `Operation_Request` packet.
public struct PTPOperationRequest: Equatable, Sendable {
    public init(
        dataPhase: PTPDataPhase,
        operationCode: PTPOperationCode,
        transactionID: UInt32,
        parameters: [UInt32] = []
    ) {
        self.dataPhase = dataPhase
        self.operationCode = operationCode
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public let dataPhase: PTPDataPhase
    public let operationCode: PTPOperationCode
    public let transactionID: UInt32
    public let parameters: [UInt32]

    public var payloadBytes: [UInt8] {
        var bytes = ByteCoding.uint32LE(dataPhase.rawValue)
        bytes += ByteCoding.uint16LE(operationCode.rawValue)
        bytes += ByteCoding.uint32LE(transactionID)
        for parameter in parameters {
            bytes += ByteCoding.uint32LE(parameter)
        }
        return bytes
    }
}

/// Parsed PTP-IP `Operation_Response` payload.
public struct PTPOperationResponse: Equatable, Sendable {
    public init(payloadBytes bytes: [UInt8]) throws {
        guard bytes.count >= 6 else {
            throw PTPOperationResponseError.shortPayload(actualLength: bytes.count)
        }
        responseCode = PTPResponseCode(rawValue: ByteCoding.readUInt16LE(bytes, at: 0)) ?? .unknown
        transactionID = ByteCoding.readUInt32LE(bytes, at: 2)

        var parsedParameters: [UInt32] = []
        var offset = 6
        while offset + 4 <= bytes.count {
            parsedParameters.append(ByteCoding.readUInt32LE(bytes, at: offset))
            offset += 4
        }
        parameters = parsedParameters
    }

    public let responseCode: PTPResponseCode
    public let transactionID: UInt32
    public let parameters: [UInt32]
}

public enum PTPOperationResponseError: LocalizedError, Equatable, Sendable {
    case shortPayload(actualLength: Int)

    public var errorDescription: String? {
        switch self {
        case .shortPayload(let actualLength):
            "PTP operation response payload was too short (\(actualLength) bytes)."
        }
    }
}

/// Data-phase payload helpers for `SetDevicePropValueEx` and similar operations.
public enum PTPDataPayloads {
    public static func startData(transactionID: UInt32, totalLength: UInt64) -> [UInt8] {
        ByteCoding.uint32LE(transactionID) + ByteCoding.uint64LE(totalLength)
    }

    public static func endData(transactionID: UInt32, data: Data) -> [UInt8] {
        ByteCoding.uint32LE(transactionID) + Array(data)
    }
}

/// Parsed MTP `GetStorageInfo` dataset.
///
/// Layout per PIMA 15740 / libgphoto2 `ptp_unpack_SI` (offsets in bytes):
/// - `StorageType` u16 @ 0, `FilesystemType` u16 @ 2, `AccessCapability` u16 @ 4
/// - `StorageMaxCapacity` u64 @ 6 — total bytes on the volume
/// - `FreeSpaceInBytes` u64 @ 14 — free bytes
/// - `FreeSpaceInImages` u32 @ 22 (not decoded here), then description + volume label strings
///
/// HW verify: log raw `StorageMaxCapacity` and `FreeSpaceInBytes` from `GetStorageInfo` (0x1005).
public struct PTPStorageInfo: Equatable, Sendable {
    /// PTP sentinel when total capacity is unknown (`0xFFFFFFFF` in a UINT64 field).
    public static let unknownCapacityBytes: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

    /// Total capacity of the storage volume in bytes (`StorageMaxCapacity` @ offset 6).
    public let totalCapacityBytes: UInt64
    /// Free space in bytes (`FreeSpaceInBytes` @ offset 14).
    public let freeSpaceBytes: UInt64

    /// Parses a raw `GetStorageInfo` dataset. Returns nil when the payload is too short.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 22 else { return nil }
        let maxCapacity = ByteCoding.readUInt64LE(bytes, at: 6)
        let freeSpace = ByteCoding.readUInt64LE(bytes, at: 14)
        totalCapacityBytes = maxCapacity == Self.unknownCapacityBytes ? 0 : maxCapacity
        freeSpaceBytes = freeSpace
    }

    /// Whole gigabytes using decimal GB (1 GB = 1e9 bytes), matching camera UI conventions.
    public static func decimalGigabytes(from bytes: UInt64) -> Int {
        Int(bytes / 1_000_000_000)
    }

    /// Free space in whole decimal gigabytes.
    public var gigabytesFree: Int {
        Self.decimalGigabytes(from: freeSpaceBytes)
    }

    /// Total capacity in whole decimal gigabytes. 0 when the camera reports unknown capacity.
    public var gigabytesTotal: Int {
        guard totalCapacityBytes > 0 else { return 0 }
        return Self.decimalGigabytes(from: totalCapacityBytes)
    }

    /// Used space in whole decimal gigabytes. 0 when total is unknown or free exceeds total.
    public var gigabytesUsed: Int {
        guard totalCapacityBytes >= freeSpaceBytes else { return 0 }
        return Self.decimalGigabytes(from: totalCapacityBytes - freeSpaceBytes)
    }

    /// Percentage of total capacity that is free (0–100). 0 when total capacity is unknown.
    public var percentFree: Int {
        guard totalCapacityBytes > 0, freeSpaceBytes <= totalCapacityBytes else { return 0 }
        return Int((Double(freeSpaceBytes) / Double(totalCapacityBytes)) * 100)
    }
}

/// Parses a `GetStorageIDs` dataset — a PTP `UINT32` array: a 4-byte element count followed by that
/// many 4-byte storage IDs.
public enum PTPStorageIDs {
    public static func parse(_ bytes: [UInt8]) -> [UInt32] {
        guard bytes.count >= 4 else { return [] }
        // Clamp the declared count to what the payload can actually hold before reserving, so a
        // malformed dataset claiming billions of IDs can't drive a huge allocation.
        let declaredCount = Int(ByteCoding.readUInt32LE(bytes, at: 0))
        let availableCount = (bytes.count - 4) / 4
        let count = min(declaredCount, availableCount)
        var ids: [UInt32] = []
        ids.reserveCapacity(count)
        var offset = 4
        for _ in 0..<count {
            ids.append(ByteCoding.readUInt32LE(bytes, at: offset))
            offset += 4
        }
        return ids
    }
}

/// Parsed PTP `GetObjectInfo` (0x1008) dataset — the metadata for one stored object (clip or still).
///
/// Standard PTP/MTP ObjectInfo layout (PIMA 15740 §5.3.1): a 52-byte fixed prefix followed by four
/// PTP strings (filename, capture date, modification date, keywords). Only the fields the Media page
/// needs are surfaced; the thumbnail/association fields in the prefix are skipped. The ZR's exact
/// ObjectFormat code for movies is unverified, so `isMovie` is best-effort — [ZR · verify-on-HW].
public struct PTPObjectInfo: Equatable, Sendable {
    /// Owning storage volume.
    public let storageID: UInt32
    /// Object format code (OFC) — standard PTP/MTP object-format codes (PIMA 15740 / libgphoto2).
    public let objectFormat: UInt16
    /// On-card size in bytes. PTP's `ObjectCompressedSize` is UINT32, so clips ≥ 4 GiB report a
    /// truncated size here. When large-clip support is needed, fetch the true size with NIKON
    /// `GetObjectSize 0x9421` (64-bit) and read with `GetPartialObjectEx 0x9431`.
    // ponytail: 32-bit size/offset is enough for the first cut; upgrade to 0x9421/0x9431 only when
    // real ZR clips exceed 4 GiB.
    public let compressedSize: UInt32
    /// Full-image pixel width (0 when the camera omits it).
    public let imagePixWidth: UInt32
    /// Full-image pixel height (0 when the camera omits it).
    public let imagePixHeight: UInt32
    /// Object filename, e.g. `C0001.MOV`.
    public let filename: String
    /// PTP date-time string (`YYYYMMDDThhmmss`); empty when the camera omits it.
    public let captureDate: String

    /// Parses a raw `GetObjectInfo` dataset. Throws `PTPObjectInfoError.truncatedDataset` when the
    /// buffer is shorter than the layout requires.
    public init(_ data: Data) throws {
        var reader = PTPObjectInfoReader(data: data)
        storageID = try reader.readUInt32()  // @0  StorageID
        objectFormat = try reader.readUInt16()  // @4  ObjectFormat
        try reader.skip(byteCount: 2)  // @6  ProtectionStatus
        compressedSize = try reader.readUInt32()  // @8  ObjectCompressedSize
        try reader.skip(byteCount: 2)  // @12 ThumbFormat
        try reader.skip(byteCount: 4)  // @14 ThumbCompressedSize
        try reader.skip(byteCount: 4)  // @18 ThumbPixWidth
        try reader.skip(byteCount: 4)  // @22 ThumbPixHeight
        imagePixWidth = try reader.readUInt32()  // @26 ImagePixWidth
        imagePixHeight = try reader.readUInt32()  // @30 ImagePixHeight
        try reader.skip(byteCount: 4)  // @34 ImageBitDepth
        try reader.skip(byteCount: 4)  // @38 ParentObject
        try reader.skip(byteCount: 2)  // @42 AssociationType
        try reader.skip(byteCount: 4)  // @44 AssociationDesc
        try reader.skip(byteCount: 4)  // @48 SequenceNumber
        filename = try reader.readString()  // @52 Filename
        captureDate = try reader.readString()  // CaptureDate
    }

    /// True for `.r3d` cinema masters listed alongside proxy MP4/MOV clips on ZR cards.
    public var isR3D: Bool {
        MediaClipFilename.isR3D(filename)
    }

    /// Best-effort movie classification by object-format code or filename extension. The ZR's actual
    /// movie OFC is unverified, so we accept the standard movie OFCs *and* fall back to the file
    /// extension. [ZR · verify-on-HW]
    public var isMovie: Bool {
        // Standard PTP movie object-format codes: AVI/MPEG/ASF/QT, plus MTP MP4.
        let movieFormats: Set<UInt16> = [0x300A, 0x300B, 0x300C, 0x300D, 0xB982]
        if movieFormats.contains(objectFormat) { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "avi", "m4v"].contains(ext)
    }

    /// Best-effort still-image classification by PTP object-format code or filename extension.
    /// Standard still OFCs follow PIMA 15740 / libgphoto2 `PTP_OFC_*`; Nikon NEF/NRW/HEIF may use
    /// vendor codes on hardware — extension fallback covers those until [ZR · verify-on-HW].
    public var isStillImage: Bool {
        if isMovie || isR3D { return false }
        // Standard PTP still formats (EXIF JPEG, TIFF, DNG, PNG, JP2) plus common vendor HEIF.
        let stillFormats: Set<UInt16> = [
            0x3801,  // EXIF JPEG
            0x3802,  // TIFF EP
            0x3808,  // JFIF
            0x380B,  // PNG
            0x380D,  // TIFF
            0x380F,  // JP2
            0x3810,  // JPX
            0x3811,  // DNG
            0xB110,  // Sony HEIF (some bodies; harmless if ZR uses another code)
        ]
        if stillFormats.contains(objectFormat) { return true }
        return MediaClipFilename.isPhoto(filename)
    }

    /// Objects indexed by the Media library: movies, stills, and R3D masters for resolution pairing.
    public var isMediaLibraryObject: Bool {
        isMovie || isR3D || isStillImage
    }
}

/// Errors that can occur while parsing PTP ObjectInfo.
public enum PTPObjectInfoError: LocalizedError, Equatable, Sendable {
    /// The ObjectInfo dataset was shorter than the layout requires.
    case truncatedDataset

    public var errorDescription: String? {
        switch self {
        case .truncatedDataset:
            "Camera ObjectInfo dataset was shorter than expected."
        }
    }
}

/// Cursor reader for the ObjectInfo dataset — mirrors the `PTPDeviceInfoReader` idiom (little-endian
/// scalars + PTP UTF-16LE strings) with bounds checks that throw `PTPObjectInfoError.truncatedDataset`.
private struct PTPObjectInfoReader {
    init(data: Data) { self.bytes = Array(data) }

    private let bytes: [UInt8]
    private var offset = 0

    mutating func skip(byteCount: Int) throws {
        guard offset + byteCount <= bytes.count else { throw PTPObjectInfoError.truncatedDataset }
        offset += byteCount
    }

    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw PTPObjectInfoError.truncatedDataset }
        defer { offset += 2 }
        return ByteCoding.readUInt16LE(bytes, at: offset)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw PTPObjectInfoError.truncatedDataset }
        defer { offset += 4 }
        return ByteCoding.readUInt32LE(bytes, at: offset)
    }

    /// Reads a PTP string: a UINT8 code-unit count (including the trailing NUL) then that many
    /// UTF-16LE units. Returns "" for a zero count and drops the trailing NUL.
    mutating func readString() throws -> String {
        guard offset < bytes.count else { throw PTPObjectInfoError.truncatedDataset }
        let characterCount = Int(bytes[offset])
        offset += 1
        guard characterCount > 0 else { return "" }
        guard offset + characterCount * 2 <= bytes.count else {
            throw PTPObjectInfoError.truncatedDataset
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(characterCount)
        for _ in 0..<characterCount {
            codeUnits.append(ByteCoding.readUInt16LE(bytes, at: offset))
            offset += 2
        }
        if codeUnits.last == 0 { codeUnits.removeLast() }
        return String(decoding: codeUnits, as: UTF16.self)
    }
}
