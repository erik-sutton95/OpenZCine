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
    /// Fast needle read while the EV meter tool is visible: the body's exposure
    /// indicator only (lit-state gate on a slow stride), no round-robin advance.
    case evIndicator
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

/// Camera-advertised Android control selections and their current semantic readbacks.
///
/// Exact descriptor values remain cached by `PTPIPClientSession`. These labels are
/// intentionally the only representation that crosses JNI.
public struct AndroidCameraControlCapabilities: Equatable, Sendable {
    public init(
        resolutionFrameRate: String? = nil,
        codec: String? = nil,
        whiteBalanceTint: String? = nil,
        isoValues: [String] = [],
        shutterValues: [String] = [],
        irisValues: [String] = [],
        whiteBalanceValues: [String] = [],
        focusModes: [String] = [],
        focusAreas: [String] = [],
        focusSubjects: [String] = [],
        audioSensitivities: [String] = [],
        audioInputs: [String] = [],
        windFilters: [String] = [],
        attenuators: [String] = [],
        audio32BitFloat: [String] = [],
        baseISO: [String] = [],
        shutterModes: [String] = [],
        shutterLocks: [String] = [],
        whiteBalanceTints: [String] = [],
        resolutionFrameRates: [String] = [],
        codecs: [String] = [],
        vibrationReduction: [String] = [],
        electronicVR: [String] = []
    ) {
        self.resolutionFrameRate = resolutionFrameRate
        self.codec = codec
        self.whiteBalanceTint = whiteBalanceTint
        self.isoValues = isoValues
        self.shutterValues = shutterValues
        self.irisValues = irisValues
        self.whiteBalanceValues = whiteBalanceValues
        self.focusModes = focusModes
        self.focusAreas = focusAreas
        self.focusSubjects = focusSubjects
        self.audioSensitivities = audioSensitivities
        self.audioInputs = audioInputs
        self.windFilters = windFilters
        self.attenuators = attenuators
        self.audio32BitFloat = audio32BitFloat
        self.baseISO = baseISO
        self.shutterModes = shutterModes
        self.shutterLocks = shutterLocks
        self.whiteBalanceTints = whiteBalanceTints
        self.resolutionFrameRates = resolutionFrameRates
        self.codecs = codecs
        self.vibrationReduction = vibrationReduction
        self.electronicVR = electronicVR
    }

    /// Current shared-core resolution/frame-rate label matching descriptor options.
    public let resolutionFrameRate: String?
    /// Current shared-core short codec label matching descriptor options.
    public let codec: String?
    /// Current WB fine-tune label for the active camera WB mode.
    public let whiteBalanceTint: String?
    /// ISO values valid for the active codec and base circuit.
    public let isoValues: [String]
    /// Values from the active shutter angle/speed descriptor.
    public let shutterValues: [String]
    /// Apertures valid for the mounted lens.
    public let irisValues: [String]
    /// Kelvin and preset white-balance values valid on the body.
    public let whiteBalanceValues: [String]
    /// Movie autofocus modes valid on the body.
    public let focusModes: [String]
    /// Movie autofocus areas valid on the body.
    public let focusAreas: [String]
    /// Movie autofocus subject modes valid on the body.
    public let focusSubjects: [String]
    /// Audio-input sensitivity values valid on the body.
    public let audioSensitivities: [String]
    /// Audio source values valid on the body.
    public let audioInputs: [String]
    /// Wind-filter states valid on the body.
    public let windFilters: [String]
    /// Input-attenuator states valid on the body.
    public let attenuators: [String]
    /// 32-bit-float audio states valid on the body.
    public let audio32BitFloat: [String]
    /// Dual-base circuits advertised by the camera.
    public let baseISO: [String]
    /// Shutter display modes advertised by the camera.
    public let shutterModes: [String]
    /// Camera shutter-lock states advertised by the camera.
    public let shutterLocks: [String]
    /// Valid fine-tune grid values, present only when the active tune property is advertised.
    public let whiteBalanceTints: [String]
    /// Recording modes from the camera's screen-size descriptor.
    public let resolutionFrameRates: [String]
    /// Codecs from the camera's file-type descriptor.
    public let codecs: [String]
    /// Movie VR values from the camera descriptor.
    public let vibrationReduction: [String]
    /// Electronic-VR values from the camera descriptor.
    public let electronicVR: [String]

    /// Empty capabilities before a successful descriptor refresh.
    public static let empty = AndroidCameraControlCapabilities()
}

/// One camera card decoded by Swift and exposed to the Android shell.
public struct AndroidCameraStorageSlot: Equatable, Sendable {
    /// Authoritative PTP storage identifier used by media-object records.
    public let storageID: UInt32
    /// One-based display order after unusable camera storage IDs are removed.
    public let slotNumber: Int
    /// Capacity and free-space data decoded by the shared core.
    public let storage: PTPStorageInfo

    /// Creates one ordered semantic storage-slot record for Android.
    public init(storageID: UInt32, slotNumber: Int, storage: PTPStorageInfo) {
        self.storageID = storageID
        self.slotNumber = slotNumber
        self.storage = storage
    }
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
    /// Every valid camera card in camera-advertised order.
    public let storageSlots: [AndroidCameraStorageSlot]
    /// Camera-advertised control labels backed by exact raw values retained in Swift.
    public let controls: AndroidCameraControlCapabilities

    /// Creates one semantic Android property-refresh readback.
    public init(
        result: AndroidCameraPropertyRefreshResult,
        properties: PTPCameraPropertySnapshot,
        storage: PTPStorageInfo?,
        storageSlots: [AndroidCameraStorageSlot] = [],
        controls: AndroidCameraControlCapabilities = .empty
    ) {
        self.result = result
        self.properties = properties
        self.storage = storage
        self.storageSlots = storageSlots
        self.controls = controls
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
        append("isoAuto", value: properties.isoAuto.map { String($0) }, to: &fields)
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
        let activeCodec = readback.controls.codec ?? properties.fileType
        append(
            "tone",
            value: activeCodec.flatMap { PTPCameraPropertyDecoders.toneLabel(fromCodec: $0) },
            to: &fields)
        append("batteryPercent", value: properties.batteryPercent.map { String($0) }, to: &fields)
        append("externalPower", value: properties.onExternalPower.map { String($0) }, to: &fields)
        append("warningRaw", value: properties.warningRaw.map { String($0) }, to: &fields)
        append(
            "temperatureStatus",
            value: properties.warningRaw.map { _ in properties.warningStatus.tileLabel },
            to: &fields)
        if let storage = readback.storage,
            let totalCapacity = Int64(exactly: storage.totalCapacityBytes),
            let freeSpace = Int64(exactly: storage.freeSpaceBytes),
            totalCapacity == 0 || freeSpace <= totalCapacity
        {
            append("storageTotalCapacityBytes", value: String(totalCapacity), to: &fields)
            append("storageFreeSpaceBytes", value: String(freeSpace), to: &fields)
        }
        appendStorageSlots(readback.storageSlots, to: &fields)
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
        append("captureSelector", value: properties.captureSelector?.rawValue, to: &fields)
        append("stillCaptureMode", value: properties.stillCaptureMode, to: &fields)
        append("stillToneMode", value: properties.stillToneMode, to: &fields)
        append("imageSize", value: properties.imageSize, to: &fields)
        append("compression", value: properties.compression, to: &fields)
        append("meteringMode", value: properties.meteringMode, to: &fields)
        append("flashMode", value: properties.flashMode, to: &fields)
        append("exposureBias", value: properties.exposureBias, to: &fields)
        append("shotsRemaining", value: properties.shotsRemaining.map(String.init), to: &fields)
        append("pictureControl", value: properties.pictureControl, to: &fields)
        append(
            "evIndicatorSixths", value: properties.evIndicatorSixths.map(String.init), to: &fields)
        append("evIndicatorLit", value: properties.evIndicatorLit.map(String.init), to: &fields)
        let controls = readback.controls
        append("resolutionFrameRate", value: controls.resolutionFrameRate, to: &fields)
        append("codecSelection", value: controls.codec, to: &fields)
        append("whiteBalanceTint", value: controls.whiteBalanceTint, to: &fields)
        appendOptions("options.iso", values: controls.isoValues, to: &fields)
        appendOptions("options.shutter", values: controls.shutterValues, to: &fields)
        appendOptions("options.iris", values: controls.irisValues, to: &fields)
        appendOptions(
            "options.whiteBalance", values: controls.whiteBalanceValues, to: &fields)
        appendOptions("options.focusMode", values: controls.focusModes, to: &fields)
        appendOptions("options.focusArea", values: controls.focusAreas, to: &fields)
        appendOptions("options.focusSubject", values: controls.focusSubjects, to: &fields)
        appendOptions(
            "options.audioSensitivity", values: controls.audioSensitivities, to: &fields)
        appendOptions("options.audioInput", values: controls.audioInputs, to: &fields)
        appendOptions("options.windFilter", values: controls.windFilters, to: &fields)
        appendOptions("options.attenuator", values: controls.attenuators, to: &fields)
        appendOptions(
            "options.audio32BitFloat", values: controls.audio32BitFloat, to: &fields)
        appendOptions("options.baseIso", values: controls.baseISO, to: &fields)
        appendOptions("options.shutterMode", values: controls.shutterModes, to: &fields)
        appendOptions("options.shutterLock", values: controls.shutterLocks, to: &fields)
        appendOptions("options.whiteBalanceTint", values: controls.whiteBalanceTints, to: &fields)
        appendOptions(
            "options.resolutionFrameRate", values: controls.resolutionFrameRates, to: &fields)
        appendOptions("options.codec", values: controls.codecs, to: &fields)
        appendOptions(
            "options.vibrationReduction", values: controls.vibrationReduction, to: &fields)
        appendOptions("options.electronicVr", values: controls.electronicVR, to: &fields)
        return fields.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
    }

    private static let optionSeparator = "\u{1F}"
    private static let maximumStorageSlotCount = 32

    /// Adds one atomic, indexed slot generation. Invalid native values omit the
    /// generation instead of publishing a partial list that Kotlin could
    /// mistake for the camera's complete card order. Slot numbers are the
    /// PHYSICAL body slots (sorted, strictly increasing, possibly gapped —
    /// a lone card in slot 2 publishes as slot 2), not list indices.
    private static func appendStorageSlots(
        _ slots: [AndroidCameraStorageSlot],
        to fields: inout [(key: String, value: String)]
    ) {
        guard slots.count <= maximumStorageSlotCount else { return }
        var encoded: [(key: String, value: String)] = []
        var seen = Set<UInt32>()
        var previousSlotNumber = 0
        for (index, slot) in slots.enumerated() {
            let storage = slot.storage
            guard slot.slotNumber > previousSlotNumber,
                slot.storageID != 0,
                slot.storageID != UInt32.max,
                seen.insert(slot.storageID).inserted,
                let totalCapacity = Int64(exactly: storage.totalCapacityBytes),
                let freeSpace = Int64(exactly: storage.freeSpaceBytes),
                totalCapacity == 0 || freeSpace <= totalCapacity
            else { return }
            previousSlotNumber = slot.slotNumber
            let prefix = "storageSlot.\(index)"
            encoded.append(("\(prefix).storageId", String(slot.storageID)))
            encoded.append(("\(prefix).slotNumber", String(slot.slotNumber)))
            encoded.append(("\(prefix).totalCapacityBytes", String(totalCapacity)))
            encoded.append(("\(prefix).freeSpaceBytes", String(freeSpace)))
        }
        append("storageSlotCount", value: String(slots.count), to: &fields)
        fields.append(contentsOf: encoded)
    }

    private static func appendOptions(
        _ key: String,
        values: [String],
        to fields: inout [(key: String, value: String)]
    ) {
        guard !values.isEmpty,
            values.allSatisfy({ !$0.contains(optionSeparator) })
        else { return }
        append(key, value: values.joined(separator: optionSeparator), to: &fields)
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
