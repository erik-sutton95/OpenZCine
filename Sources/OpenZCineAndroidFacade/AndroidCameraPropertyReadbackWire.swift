import OpenZCineCore

/// One semantic property-refresh request from the Android shell.
///
/// Kotlin supplies only lifecycle intent and raw `DevicePropChanged` values it
/// already received from the camera. Swift decides whether that raw value is a
/// supported property and is solely responsible for every Nikon property code
/// and byte decoder.
public enum AndroidCameraPropertyRefreshRequest: Sendable {
    /// Seed the monitor with a bounded set of high-value values after connect.
    case bootstrap
    /// Read the next low-rate property in the shared core's monitor order.
    case next(isRecording: Bool)
    /// Re-read one known property after the camera announces a change.
    case propertyChanged(UInt32)
}

/// Non-terminal result of one Android camera-property refresh.
public enum AndroidCameraPropertyRefreshResult: String, Equatable, Sendable {
    /// No active facade session exists for the requested readback.
    case noSession
    /// At least the requested supported read completed.
    case accepted
    /// Camera media currently owns the command channel.
    case mediaBusy
    /// A mode-dependent or unknown property is unavailable on this body.
    case unsupported
    /// The command transport failed during this noncritical readback.
    case transportFailed
}

/// Swift-owned decoded state returned to the Android shell after one refresh.
///
/// This keeps `PTPCameraPropertySnapshot` and `PTPStorageInfo` as the only
/// models that interpret camera bytes. The Kotlin mirror receives the encoded
/// semantic fields below, never a Nikon property identifier or payload.
public struct AndroidCameraPropertyReadback: Equatable, Sendable {
    /// The outcome of the refresh request.
    public let result: AndroidCameraPropertyRefreshResult
    /// Accumulated values successfully read from this connected body.
    public let properties: PTPCameraPropertySnapshot
    /// Current active-card storage state when it has been read successfully.
    public let storage: PTPStorageInfo?

    /// Creates one semantic Android property-refresh readback.
    public init(
        result: AndroidCameraPropertyRefreshResult,
        properties: PTPCameraPropertySnapshot,
        storage: PTPStorageInfo?
    ) {
        self.result = result
        self.properties = properties
        self.storage = storage
    }
}

/// Flat semantic record codec for the coarse Android property-refresh JNI seam.
///
/// Each line is a `key<TAB>value` field and unavailable fields are omitted.
/// Values containing a tab, carriage return, or line feed are omitted so the
/// Kotlin side can decode the record without a platform JSON dependency. This
/// is a semantic contract (`"iso"`, `"focusMode"`, `"cameraGrid"`, etc.), not
/// a PTP wire format; all property IDs and byte decoding remain in the shared
/// Swift core.
public enum AndroidCameraPropertyReadbackWire {
    /// Encodes one readback as a compact semantic record for Kotlin.
    public static func encode(_ readback: AndroidCameraPropertyReadback) -> String {
        let properties = readback.properties
        var fields = [(key: "result", value: readback.result.rawValue)]
        append("iso", value: properties.iso.map { String($0) }, to: &fields)
        append("baseIso", value: properties.baseISO, to: &fields)
        append("exposureMode", value: properties.exposureMode, to: &fields)
        append("shutterMode", value: properties.shutterMode?.rawValue, to: &fields)
        append("shutterLocked", value: properties.shutterLocked.map { String($0) }, to: &fields)
        append("shutterSpeed", value: properties.shutterSpeed, to: &fields)
        append("shutterAngle", value: properties.shutterAngle, to: &fields)
        append("iris", value: properties.fNumber, to: &fields)
        append("whiteBalanceMode", value: properties.wbMode, to: &fields)
        append("whiteBalanceKelvin", value: properties.wbKelvin.map { String($0) }, to: &fields)
        append("resolution", value: properties.resolution, to: &fields)
        append("frameRate", value: properties.fps.map { String($0) }, to: &fields)
        append("codec", value: properties.fileType, to: &fields)
        append("batteryPercent", value: properties.batteryPercent.map { String($0) }, to: &fields)
        append("externalPower", value: properties.onExternalPower.map { String($0) }, to: &fields)
        append("warningRaw", value: properties.warningRaw.map { String($0) }, to: &fields)
        append(
            "temperatureStatus",
            value: properties.warningRaw.map { _ in properties.warningStatus.tileLabel },
            to: &fields)
        if let storage = readback.storage,
            let totalCapacity = Int64(exactly: storage.totalCapacityBytes),
            let freeSpace = Int64(exactly: storage.freeSpaceBytes)
        {
            append("storageTotalCapacityBytes", value: String(totalCapacity), to: &fields)
            append("storageFreeSpaceBytes", value: String(freeSpace), to: &fields)
        }
        append("lens", value: properties.lens, to: &fields)
        append("focalLength", value: properties.focalLength, to: &fields)
        append("focusMode", value: properties.focusMode, to: &fields)
        append("focusArea", value: properties.focusArea, to: &fields)
        append("focusSubject", value: properties.focusSubject, to: &fields)
        append("microphoneSensitivity", value: properties.microphoneSensitivity, to: &fields)
        append("microphoneLevel", value: properties.microphoneLevel, to: &fields)
        append("windFilter", value: properties.windNoiseReduction, to: &fields)
        append("inputAttenuator", value: properties.inputAttenuator, to: &fields)
        append("audioInput", value: properties.audioInput, to: &fields)
        append("audioSensitivity", value: properties.audioSensitivity, to: &fields)
        append("audio32BitFloat", value: properties.audio32BitFloat, to: &fields)
        append("vibrationReduction", value: properties.vibrationReduction, to: &fields)
        append("electronicVr", value: properties.electronicVR, to: &fields)
        append("cameraGrid", value: properties.gridDisplay, to: &fields)
        return fields.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
    }

    private static func append(
        _ key: String,
        value: String?,
        to fields: inout [(key: String, value: String)]
    ) {
        guard let value,
            !value.contains("\t"),
            !value.contains("\n"),
            !value.contains("\r")
        else { return }
        fields.append((key: key, value: value))
    }
}
