// PTP-IP protocol/session layer for the Android facade.
//
// Socket-ownership decision: the sockets live HERE, in Swift, inside the facade
// target — not in Kotlin. AGENTS.md says platform adapters own sockets, and on
// Android the facade *is* the platform adapter: routing every PTP-IP packet
// Kotlin↔Swift over JNI would put several JNI round trips on each transaction
// (and per live-view frame later), while the core deliberately exposes a
// transaction-level `CameraTransport` boundary rather than a packet-pump engine.
// This mirrors `ios/Runner/PTPIPTransport.swift` + `NativeCameraSession.swift`
// (the iOS shell's twin of this file) with the same core codecs underneath;
// the Kotlin side sees only coarse connect / read-property / disconnect calls.
// See docs/investigations/android-core-feasibility.md ("Where sockets go").
//
// Everything below is adapter glue over `OpenZCineCore`: packet framing,
// handshake payloads, transaction collection, property decoding, and pairing
// policies all come from the core. This file compiles on Darwin too, so the
// fake-camera tests in `Tests/OpenZCineAndroidFacadeTests` exercise the exact
// bytes-on-the-wire behavior that ships in the Android `.so`.

import Foundation
import OpenZCineCore

/// Stable Android PTP-IP initiator identity kept separate from the iOS camera profile.
public enum AndroidPTPIPInitiator {
    /// The 16-byte Android GUID retained across reconnects and upgrades.
    public static let appGUID = Data("OpenZCineAndroid".utf8)

    /// Android's paired-initiator display name.
    public static let friendlyName = "OpenZCine Android"
}

#if canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

#if os(Android)
    /// One-shot stop flag for the USB establishment event pump. Set from the
    /// establish thread, read from the pump thread — hence the lock.
    final class USBEventPumpFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stop = false
        var stopRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stop
        }
        func requestStop() {
            lock.lock()
            stop = true
            lock.unlock()
        }
    }
#endif

/// Errors surfaced by the facade's PTP-IP session layer.
public enum PTPIPClientSessionError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case connectionClosed
    case timeout(String)
    case unexpectedPacket(expected: String, actual: PTPIPPacketType)
    case initFailed(PTPIPInitFailReason)
    case operationRejected(PTPOperationCode, PTPResponseCode)
    case invalidPacketLength(UInt32)
    case pairingChallengeUnavailable
    /// A saved camera-side profile did not accept this initiator for app control.
    case savedProfileRequired
    case appControlUnavailable
    case unsupportedProperty(UInt32)
    case unsupportedControl(PTPCameraControl, String)
    case unsupportedAndroidControl(String, String)
    case controlReadbackMismatch(String, String)
    case invalidPropertyDescriptor(UInt32)
    case unwritablePropertyDescriptor(UInt32)
    case liveViewAlreadyActive
    case mediaModeActive
    case mediaModeRequired
    case focusStateUnavailable
    case eventDrainAlreadyActive

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return message
        case .connectionClosed:
            return "The camera closed the connection."
        case .timeout(let label):
            return "\(label) timed out."
        case .unexpectedPacket(let expected, let actual):
            return "Expected \(expected), got PTP-IP packet \(actual.rawValue)."
        case .initFailed(let reason):
            return "The camera rejected the PTP-IP handshake: \(reason)."
        case .operationRejected(let operation, let response):
            return "Camera rejected \(operation) with response \(response)."
        case .invalidPacketLength(let length):
            return "Invalid PTP-IP packet length \(length)."
        case .pairingChallengeUnavailable:
            return
                "The camera did not provide a pairing code. Restart Connect to Smart Device on the camera, then pair again."
        case .savedProfileRequired:
            return "The camera requires first-time pairing before app control can start."
        case .appControlUnavailable:
            return "The camera did not open app-control mode after pairing."
        case .unsupportedProperty(let code):
            return "Property 0x\(PTPIPClientSession.hexString(code)) is not known to the core."
        case .unsupportedControl(let control, let label):
            return "\(String(describing: control)) does not support the selection \"\(label)\"."
        case .unsupportedAndroidControl(let control, let label):
            return "\(control) is not advertised with the selection \"\(label)\" on this camera."
        case .controlReadbackMismatch(let control, let label):
            return
                "The camera accepted \(control) \(label), but its readback did not change. Check the active camera mode and try again."
        case .invalidPropertyDescriptor(let code):
            return
                "Property 0x\(PTPIPClientSession.hexString(code)) returned an invalid descriptor."
        case .unwritablePropertyDescriptor(let code):
            return
                "Property 0x\(PTPIPClientSession.hexString(code)) did not advertise a writable value domain."
        case .liveViewAlreadyActive:
            return "Live view is already streaming on this session."
        case .mediaModeActive:
            return "Live view is unavailable while camera media is open."
        case .mediaModeRequired:
            return "Open camera media before starting an object transfer."
        case .focusStateUnavailable:
            return "Camera focus metadata is not available yet."
        case .eventDrainAlreadyActive:
            return "The camera event channel is already being drained."
        }
    }
}

/// Camera identity assembled from the Init handshake plus `GetDeviceInfo`.
public struct PTPIPClientIdentity: Equatable, Sendable {
    public let cameraName: String
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    /// Operator-facing camera title, resolved by the core's shared naming policy.
    public var displayName: String {
        CameraDisplayNamePolicy.displayName(
            cameraName: cameraName,
            manufacturer: manufacturer,
            model: model
        )
    }
}

private struct AndroidRawControlMode<Value: FixedWidthInteger & Sendable>: Sendable {
    let label: String
    let raw: Value
}

private enum AndroidWritableDescriptorForm: Sendable {
    case enumeration([[UInt8]])
    case range(minimum: [UInt8], maximum: [UInt8], step: [UInt8])
}

/// Nikon ZR controls whose settable domain is stable even when the body omits or temporarily
/// narrows a descriptor. These are never applied to a different camera model.
private enum AndroidNikonZRControlFallback {
    static let baseISO: [AndroidRawControlMode<UInt8>] = [
        AndroidRawControlMode(label: "Low", raw: 1),
        AndroidRawControlMode(label: "High", raw: 2),
    ]
    /// Nikon K [Choose color temperature] discrete steps (2500–10000 K).
    /// Keep in lockstep with `WhiteBalanceKelvinPolicy.kelvinSteps`.
    static let whiteBalanceKelvin: [AndroidRawControlMode<UInt16>] =
        WhiteBalanceKelvinPolicy.kelvinSteps.map {
            AndroidRawControlMode(label: "\($0)K", raw: UInt16($0))
        }
    static let whiteBalanceModes: [AndroidRawControlMode<UInt16>] = [
        AndroidRawControlMode(label: "Auto", raw: 0x0002),
        AndroidRawControlMode(label: "Natural auto", raw: 0x8016),
        AndroidRawControlMode(label: "Sunny", raw: 0x0004),
        AndroidRawControlMode(label: "Cloudy", raw: 0x8010),
        AndroidRawControlMode(label: "Shade", raw: 0x8011),
        AndroidRawControlMode(label: "Incandescent", raw: 0x0006),
        AndroidRawControlMode(label: "Fluorescent", raw: 0x0005),
        AndroidRawControlMode(label: "Flash", raw: 0x0007),
        AndroidRawControlMode(label: "Preset", raw: 0x8013),
        AndroidRawControlMode(label: "Color temp", raw: 0x8012),
    ]
    static let focusModes: [AndroidRawControlMode<UInt8>] = [
        AndroidRawControlMode(label: "AF-S", raw: 0),
        AndroidRawControlMode(label: "AF-C", raw: 1),
        AndroidRawControlMode(label: "AF-F", raw: 2),
        AndroidRawControlMode(label: "MF", raw: 4),
    ]
    static let focusAreas: [AndroidRawControlMode<UInt16>] = [
        AndroidRawControlMode(label: "Single", raw: 0x8010),
        AndroidRawControlMode(label: "Wide-S", raw: 0x8018),
        AndroidRawControlMode(label: "Wide-L", raw: 0x8019),
        AndroidRawControlMode(label: "Auto", raw: 0x8011),
        AndroidRawControlMode(label: "Subject", raw: 0x8033),
    ]
    static let focusSubjects: [AndroidRawControlMode<UInt8>] = [
        AndroidRawControlMode(label: "Auto", raw: 1),
        AndroidRawControlMode(label: "People", raw: 2),
        AndroidRawControlMode(label: "Animal", raw: 3),
        AndroidRawControlMode(label: "Bird", raw: 5),
        AndroidRawControlMode(label: "Vehicle", raw: 4),
        AndroidRawControlMode(label: "Airplane", raw: 6),
    ]
    static let audioSensitivities: [AndroidRawControlMode<UInt8>] =
        [AndroidRawControlMode(label: "Auto", raw: 0xFF)]
        + (1...20).map { AndroidRawControlMode(label: String($0), raw: UInt8($0)) }
    static let audioInputs: [AndroidRawControlMode<UInt8>] = [
        AndroidRawControlMode(label: "Microphone", raw: 1),
        AndroidRawControlMode(label: "Line", raw: 2),
    ]
    static let onOff: [AndroidRawControlMode<UInt8>] = [
        AndroidRawControlMode(label: "OFF", raw: 0),
        AndroidRawControlMode(label: "ON", raw: 1),
    ]
    static let vibrationReduction: [AndroidRawControlMode<UInt8>] = [
        AndroidRawControlMode(label: "OFF", raw: 0),
        AndroidRawControlMode(label: "ON", raw: 1),
        AndroidRawControlMode(label: "SPORT", raw: 2),
    ]

    // MovScreenSize has NO write fallbacks. Invented packs reboot real ZRs; only the body's
    // DevicePropDesc enum entries may become write targets (see refreshAndroidScreenSizeDescriptor).

    /// Proven Nikon ZR `MovFileType` (0xD0AF) packed values from the Flutter lab capture.
    static let fileTypes: [PTPCameraFileTypeMode] = PTPCameraPropertyDecoders.fileTypeModes(
        fromEnum: [
            0x0000_0801,  // H.264
            0x0001_0800,  // H.265
            0x0001_0A00,  // H.265 10-bit
            0x0010_0A00,  // ProRes 422 HQ
            0x0011_0C00,  // ProRes RAW HQ
            0x0031_0C03,  // R3D NE 12-bit R3D
            0x0002_0C02,  // N-RAW
        ])
}

/// Exact camera-advertised values retained inside the Swift session.
private struct AndroidRawControlCatalog: Sendable {
    var isComplete = false
    var screenSizes: [PTPCameraScreenSizeMode] = []
    var fileTypes: [PTPCameraFileTypeMode] = []
    var apertures: [AndroidRawControlMode<UInt16>] = []
    var whiteBalanceKelvin: [AndroidRawControlMode<UInt16>] = []
    var whiteBalanceModes: [AndroidRawControlMode<UInt16>] = []
    var focusModes: [AndroidRawControlMode<UInt8>] = []
    var focusAreas: [AndroidRawControlMode<UInt16>] = []
    var focusSubjects: [AndroidRawControlMode<UInt8>] = []
    var audioSensitivities: [AndroidRawControlMode<UInt8>] = []
    var audioInputs: [AndroidRawControlMode<UInt8>] = []
    var windFilters: [AndroidRawControlMode<UInt8>] = []
    var attenuators: [AndroidRawControlMode<UInt8>] = []
    var audio32BitFloat: [AndroidRawControlMode<UInt8>] = []
    var shutterAngles: [AndroidRawControlMode<UInt32>] = []
    var shutterSpeeds: [AndroidRawControlMode<UInt32>] = []
    var baseISO: [AndroidRawControlMode<UInt8>] = []
    var shutterModes: [AndroidRawControlMode<UInt8>] = []
    var shutterLocks: [AndroidRawControlMode<UInt8>] = []
    var whiteBalanceTints: [(label: String, amberBlue: Int, greenMagenta: Int)] = []
    var vibrationReduction: [AndroidRawControlMode<UInt8>] = []
    var electronicVR: [AndroidRawControlMode<UInt8>] = []
    var allowsApertureFallback = false
    // Photo-mode descriptor domains (iOS `cameraControlOptions` stills equivalents).
    var stillShutterSpeeds: [AndroidRawControlMode<UInt32>] = []
    var stillWhiteBalanceModes: [AndroidRawControlMode<UInt16>] = []
    var imageSizes: [String] = []

    func capabilities(
        properties: PTPCameraPropertySnapshot,
        whiteBalanceTint: String?,
        isScreenSizeReadbackCurrent: Bool,
        usesNikonZRFallbacks: Bool
    ) -> AndroidCameraControlCapabilities {
        guard isComplete else { return .empty }
        // Descriptor-recognized short codec only — crop labels and e-VR gating stay fail-closed
        // for unknown file types. ISO may also use the live readback short label when the enum
        // domain has not listed the active codec yet.
        let recognizedCodec = recognizedCurrentCodec(properties.fileType)
        let isoCodec =
            recognizedCodec ?? properties.fileType.map(MonitorTextFormat.codecShortLabel)
        let showsDualBaseCircuits = isoCodec.map(ISOPickerPolicy.showsDualBaseCircuits) ?? false
        let currentScreenSizeLabel: String?
        if isScreenSizeReadbackCurrent,
            let rawScreenSize = properties.rawScreenSize,
            let mode = screenSizeModeMatching(raw: rawScreenSize)
        {
            currentScreenSizeLabel = screenSizeLabel(
                for: mode,
                currentCodec: recognizedCodec,
                usesNikonZRFallbacks: usesNikonZRFallbacks)
        } else {
            currentScreenSizeLabel = nil
        }
        let resolutionFrameRate: String?
        if !isScreenSizeReadbackCurrent {
            // The codec has changed but its D0A0 value has not been read back yet. Do not present
            // the previous codec's resolution as the active selection while the picker uses the
            // new descriptor domain.
            resolutionFrameRate = nil
        } else if let currentScreenSizeLabel {
            resolutionFrameRate = currentScreenSizeLabel
        } else if let raw = properties.rawScreenSize {
            // Camera is the source of truth: always surface the live packing even when it is not
            // (yet) in the enum list. Label from the raw bytes so body-side dial changes appear
            // immediately; write path still only uses camera-advertised catalog packs (iOS).
            let size = PTPCameraPropertyDecoders.screenSize(raw)
            let base = MonitorTextFormat.resolutionLabel(
                pixelWidth: size.width,
                pixelHeight: size.height,
                frameRate: Double(size.fps))
            resolutionFrameRate = NikonZRRawCropPresentation.label(
                baseLabel: base,
                rawScreenSize: raw,
                currentCodec: recognizedCodec ?? properties.fileType,
                isNikonZR: usesNikonZRFallbacks)
        } else {
            resolutionFrameRate =
                MonitorTextFormat.resolutionLabel(
                    fromProperty: properties.resolution,
                    frameRate: properties.fps ?? 0,
                    fallback: ""
                ).nilIfEmpty
        }
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: properties.captureSelector)
        let activeShutterValues: [String]
        if photography {
            // Photo: the body enumerates the stills speeds valid for the active
            // program/flash state (iOS `optionProperty` for `.stillShutter`);
            // the shell keeps its ladder fallback when empty.
            activeShutterValues = stillShutterSpeeds.map(\.label)
        } else {
            switch properties.shutterMode {
            case .angle: activeShutterValues = shutterAngles.map(\.label)
            case .speed: activeShutterValues = shutterSpeeds.map(\.label)
            case nil: activeShutterValues = []
            }
        }
        let irisValues: [String]
        if !apertures.isEmpty {
            irisValues = apertures.map(\.label)
        } else if usesNikonZRFallbacks, allowsApertureFallback {
            // Empty/omitted f-number enum on ZR — shared-core + lens ladder is safe.
            // A read-only/unwritable descriptor leaves allowsApertureFallback false so
            // we fail closed rather than inventing writes the body will reject.
            irisValues = PTPCameraPropertyDecoders.availableApertures(forLens: properties.lens)
        } else {
            irisValues = []
        }
        let isoValues: [String]
        if usesNikonZRFallbacks, isoCodec != nil {
            if showsDualBaseCircuits {
                switch properties.baseISO {
                case "Low": isoValues = ISOPickerPolicy.lowBaseOptions
                case "High": isoValues = ISOPickerPolicy.highBaseOptions
                default:
                    // Base circuit has not landed yet — keep the dual-base drum writable
                    // with the full union so ISO is never padlock-grayed for a late D0xx.
                    isoValues = ISOPickerPolicy.unifiedOptions
                }
            } else {
                isoValues = ISOPickerPolicy.unifiedOptions
            }
        } else if usesNikonZRFallbacks {
            // Codec short label not yet known; still expose the ZR ISO ladder.
            isoValues = ISOPickerPolicy.unifiedOptions
        } else {
            isoValues = []
        }
        let whiteBalanceValues: [String]
        if photography {
            // Photo WB: the stills preset enum, with the shared Kelvin dial
            // ladder while the body offers colour-temperature mode (iOS photo
            // WB reuses the movie popup over the stills property).
            whiteBalanceValues =
                (stillWhiteBalanceModes.contains { $0.label == "Color temp" }
                    ? WhiteBalanceKelvinPolicy.kelvinOptions : [])
                + stillWhiteBalanceModes.filter { $0.label != "Color temp" }.map(\.label)
        } else {
            whiteBalanceValues =
                (whiteBalanceModes.contains { $0.label == "Color temp" }
                    ? whiteBalanceKelvin.map(\.label) : [])
                + whiteBalanceModes.filter { $0.label != "Color temp" }.map(\.label)
        }
        return AndroidCameraControlCapabilities(
            resolutionFrameRate: resolutionFrameRate,
            codec: properties.fileType.map(MonitorTextFormat.codecShortLabel),
            whiteBalanceTint: whiteBalanceTint,
            isoValues: isoValues,
            shutterValues: activeShutterValues,
            irisValues: irisValues,
            whiteBalanceValues: uniqueLabels(whiteBalanceValues),
            focusModes: focusModes.map(\.label),
            focusAreas: focusAreas.map(\.label),
            focusSubjects: focusSubjects.map(\.label),
            audioSensitivities: audioSensitivities.map(\.label),
            audioInputs: audioInputs.map(\.label),
            windFilters: windFilters.map(\.label),
            attenuators: attenuators.map(\.label),
            audio32BitFloat: audio32BitFloat.map(\.label),
            baseISO: showsDualBaseCircuits ? baseISO.map(\.label) : [],
            shutterModes: shutterModes.map(\.label),
            shutterLocks: shutterLocks.map(\.label),
            whiteBalanceTints: whiteBalanceTints.map(\.label),
            resolutionFrameRates: screenSizes.map {
                screenSizeLabel(
                    for: $0,
                    currentCodec: recognizedCodec,
                    usesNikonZRFallbacks: usesNikonZRFallbacks)
            },
            codecs: fileTypes.map(\.label),
            vibrationReduction: vibrationReduction.map(\.label),
            // Unknown/raw codecs fail closed: only a recognized non-raw codec unlocks e-VR.
            electronicVR:
                recognizedCodec.map(MonitorTextFormat.isRawCodec) == false
                ? electronicVR.map(\.label) : [],
            imageSizes: imageSizes
        )
    }

    private func recognizedCurrentCodec(_ codec: String?) -> String? {
        guard let codec else { return nil }
        let label = MonitorTextFormat.codecShortLabel(codec)
        return fileTypes.contains(where: { $0.label == label }) ? label : nil
    }

    /// Resolves a picker label to a camera-advertised mode — same matching as iOS
    /// `NativeAppRoot` resolution write: presentation label, bare mode label, then bare
    /// presentation. Writes only the exact descriptor `raw` (never invent packs).
    func screenSizeMode(
        for label: String,
        properties: PTPCameraPropertySnapshot,
        usesNikonZRFallbacks: Bool
    ) -> PTPCameraScreenSizeMode? {
        let currentCodec = recognizedCurrentCodec(properties.fileType)
        let bareTarget = PTPIPClientSession.bareRecordingModeLabel(label)
        return screenSizes.first { mode in
            let presented = screenSizeLabel(
                for: mode,
                currentCodec: currentCodec,
                usesNikonZRFallbacks: usesNikonZRFallbacks)
            if presented == label || mode.label == label { return true }
            guard !bareTarget.isEmpty else { return false }
            return PTPIPClientSession.bareRecordingModeLabel(mode.label) == bareTarget
                || PTPIPClientSession.bareRecordingModeLabel(presented) == bareTarget
        }
    }

    /// Matches a packed raw to a catalog mode by exact bytes, then by decoded WxH+fps.
    func screenSizeModeMatching(raw: UInt64) -> PTPCameraScreenSizeMode? {
        if let exact = screenSizes.first(where: { $0.raw == raw }) { return exact }
        let live = PTPCameraPropertyDecoders.screenSize(raw)
        return screenSizes.first {
            let size = PTPCameraPropertyDecoders.screenSize($0.raw)
            return size.width == live.width && size.height == live.height && size.fps == live.fps
        }
    }

    private func screenSizeLabel(
        for mode: PTPCameraScreenSizeMode,
        currentCodec: String?,
        usesNikonZRFallbacks: Bool
    ) -> String {
        NikonZRRawCropPresentation.label(
            for: mode,
            currentCodec: currentCodec,
            isNikonZR: usesNikonZRFallbacks)
    }

    private func uniqueLabels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One storage readback and the ownership generation that captured it.
struct AndroidMediaBrowsePreparation: Sendable {
    let readback: AndroidCameraPropertyReadback
    let ownershipGeneration: UInt64
}

/// A synchronous PTP-IP camera session: two TCP sockets (command + event) to
/// port 15740, the CIPA DC-005 Init handshake, and the Nikon open/pair/identify
/// sequence — the Android twin of `NativeCameraSession.establish`.
///
/// Blocking by design: JNI entry points arrive on JVM threads (Kotlin drives
/// them from `Dispatchers.IO`), so the Dispatch/async machinery the iOS shell
/// needs has no job here. All transactions are serialized on `transactionLock`.
// SAFETY: `@unchecked Sendable` — `nextTransactionID` and socket I/O are only
// touched inside transactions serialized by `transactionLock`.
public final class PTPIPClientSession: @unchecked Sendable {
    /// Selects how this connection establishes Nikon app-control access.
    ///
    /// An unknown Wi-Fi camera must use ``firstTimePairing`` directly. A
    /// `ChangeApplicationMode` probe can interrupt the camera's Wi-Fi pairing
    /// wizard before `GetPairingInfo` has a chance to provide its challenge.
    public enum ConnectionStrategy: Equatable, Sendable {
        /// Reconnect through a camera-side profile that has already paired this initiator.
        case savedProfile
        /// Establish a new profile without probing app control first.
        case firstTimePairing
        /// Try a saved profile, then pair only if the profile is specifically rejected.
        ///
        /// This is appropriate for USB, where there is no Wi-Fi pairing wizard
        /// to disrupt. It preserves the facade's pre-strategy compatibility behavior.
        case restoreProfileThenPairing
    }

    private let command: PosixTCPSocket?
    private let event: PosixTCPSocket?
    #if os(Android)
        /// USB owns the physical endpoints in Kotlin. Swift owns the generic
        /// PTP containers and every session operation above this transport.
        private let usbTransport: AndroidUSBPTPTransport?
    #endif
    private let transactionLock = NSLock()
    /// Serializes high-level camera-changing command sequences with recording,
    /// media ownership transitions, and teardown. Individual wire transactions
    /// still use `transactionLock`, so live-view frame reads stay safe between
    /// a multi-write control sequence's individual PTP transactions.
    private let commandLifecycleLock = NSLock()
    /// Accumulated Android monitor state. Access only while
    /// `commandLifecycleLock` is held so a refresh cannot race control writes,
    /// media ownership, or teardown.
    private var androidPropertySnapshot = PTPCameraPropertySnapshot()
    /// `false` from a codec transition until `MovScreenSize` (`D0A0`) is read back again. This
    /// prevents a previous codec's active resolution from being rendered as current while its
    /// camera-advertised picker domain is already refreshed.
    private var androidScreenSizeReadbackIsCurrent = false
    private var androidStorageInfo: PTPStorageInfo?
    private var androidStorageSlots: [AndroidCameraStorageSlot] = []
    private var androidControlCatalog = AndroidRawControlCatalog()
    private var androidWhiteBalanceTint: String?
    private var androidPropertyPollIndex = 0
    private var androidEVIndicatorPollTick = 0
    private var androidLastStorageRefreshAt: Date?
    private var androidLastDescriptorRefreshAt: Date?
    private var nextTransactionID: UInt32 = 1
    private var isClosed = false

    /// Latest completed command-channel request/response duration. This has a
    /// dedicated lock because the live-view pump and UI commands may publish
    /// measurements independently of `commandLifecycleLock`.
    private let roundTripLock = NSLock()
    private var latestRoundTripMillisecondsStorage: Double?

    /// Live-view pump state, guarded by `liveViewCondition` (never by
    /// `transactionLock` — the pump holds that per transaction, and stop/join
    /// must be able to run while a frame fetch is in flight).
    private let liveViewCondition = NSCondition()
    private var liveViewPumpActive = false
    private var liveViewStopRequested = false
    private var mediaModeActive = false
    private var mediaModeOwnershipGeneration: UInt64 = 0
    /// Preview-only pacing selected by the shared Android live-view policy.
    /// Access while `commandLifecycleLock` is held before start, then copied
    /// into the pump under `liveViewCondition`; this never changes camera
    /// recording settings or the camera's card write cadence.
    private var configuredLiveViewFrameIntervalNanoseconds =
        PTPIPClientSession.liveViewFrameIntervalNanoseconds

    /// Latest camera-authored focus header and its live-frame generation. The
    /// pump updates this independently of `commandLifecycleLock`, allowing a
    /// reset command to wait for 3...15 genuinely new headers while retaining
    /// exclusive ownership of high-level camera-changing work.
    private let focusFrameCondition = NSCondition()
    private var latestLiveViewFocus: PTPLiveViewFocusInfo?
    private var focusFrameGeneration: UInt64 = 0

    /// Event-channel ownership. PTP-IP events arrive on their own TCP socket,
    /// so a dedicated reader can drain sparse camera pushes without blocking
    /// serialized command transactions or live-view frame reads.
    private let eventDrainCondition = NSCondition()
    private var eventDrainActive = false
    private var eventDrainStopRequested = false

    /// Media payload pump state. Like live view, this is independent of the
    /// transaction lock so stop/join can proceed while one camera read is in
    /// flight.
    private let mediaTransferCondition = NSCondition()
    private var mediaTransferActive = false
    private var mediaTransferStopRequested = false

    /// Camera identity resolved during `connect`. Written once by
    /// `identify()` during establishment, before the session escapes to
    /// callers, so reads never race the write.
    public private(set) var identity: PTPIPClientIdentity

    /// True only for the production target whose stable descriptor omissions have explicit policy.
    private var usesNikonZRFallbacks: Bool {
        let manufacturer = identity.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let model = identity.model.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return manufacturer.contains("NIKON") && (model == "ZR" || model == "NIKON ZR")
    }

    private init(command: PosixTCPSocket, event: PosixTCPSocket, identity: PTPIPClientIdentity) {
        self.command = command
        self.event = event
        #if os(Android)
            usbTransport = nil
        #endif
        self.identity = identity
    }

    #if os(Android)
        private init(usbTransport: AndroidUSBPTPTransport, identity: PTPIPClientIdentity) {
            command = nil
            event = nil
            self.usbTransport = usbTransport
            self.identity = identity
        }
    #endif

    // MARK: - Connect

    /// Connects, handshakes, and establishes an app-control PTP session.
    ///
    /// Use ``ConnectionStrategy/firstTimePairing`` for an unknown Wi-Fi
    /// camera. ``ConnectionStrategy/restoreProfileThenPairing`` remains the
    /// compatibility default for callers that have not yet selected a strategy.
    /// Progress is pushed through `onPhase` (`.handshaking`, `.pairing`,
    /// `.confirmOnCamera` with the PIN as detail after `ConfirmPairing`
    /// succeeds, `.connected`).
    public static func connect(
        host: String,
        port: UInt16 = UInt16(ptpIPPort),
        guid: Data = AndroidPTPIPInitiator.appGUID,
        friendlyName: String = AndroidPTPIPInitiator.friendlyName,
        timeoutMilliseconds: Int32 = 10_000,
        strategy: ConnectionStrategy = .restoreProfileThenPairing,
        onPhase: (CameraConnectionPhase, String) -> Void = { _, _ in }
    ) throws -> PTPIPClientSession {
        onPhase(.handshaking, "")
        switch strategy {
        case .savedProfile:
            return try connectSavedProfile(
                host: host,
                port: port,
                guid: guid,
                friendlyName: friendlyName,
                timeoutMilliseconds: timeoutMilliseconds,
                onPhase: onPhase
            )
        case .firstTimePairing:
            return try connectFirstTimePairing(
                host: host,
                port: port,
                guid: guid,
                friendlyName: friendlyName,
                timeoutMilliseconds: timeoutMilliseconds,
                onPhase: onPhase
            )
        case .restoreProfileThenPairing:
            do {
                return try connectSavedProfile(
                    host: host,
                    port: port,
                    guid: guid,
                    friendlyName: friendlyName,
                    timeoutMilliseconds: timeoutMilliseconds,
                    onPhase: onPhase
                )
            } catch {
                guard let sessionError = error as? PTPIPClientSessionError,
                    sessionError == .savedProfileRequired
                else {
                    throw error
                }
                return try connectFirstTimePairing(
                    host: host,
                    port: port,
                    guid: guid,
                    friendlyName: friendlyName,
                    timeoutMilliseconds: timeoutMilliseconds,
                    onPhase: onPhase
                )
            }
        }
    }

    private static func connectSavedProfile(
        host: String,
        port: UInt16,
        guid: Data,
        friendlyName: String,
        timeoutMilliseconds: Int32,
        onPhase: (CameraConnectionPhase, String) -> Void
    ) throws -> PTPIPClientSession {
        let session = try establishLink(
            host: host,
            port: port,
            guid: guid,
            friendlyName: friendlyName,
            timeoutMilliseconds: timeoutMilliseconds
        )
        do {
            try establishSavedProfile(on: session, onPhase: onPhase)
            return session
        } catch {
            session.disconnect()
            throw error
        }
    }

    private static func establishSavedProfile(
        on session: PTPIPClientSession,
        onPhase: (CameraConnectionPhase, String) -> Void
    ) throws {
        try session.openSession()
        guard try session.enableAppControl() else {
            throw PTPIPClientSessionError.savedProfileRequired
        }
        try session.identify()
        onPhase(.connected, session.identity.displayName)
    }

    #if os(Android)
        /// USB variant of the establish sequence. The cable has no PTP-IP Init
        /// handshake, so there is no pairing step and no paired-GUID trust —
        /// the ZR boots into PC-camera mode and Access_Denies the vendor
        /// app-control switch that Wi-Fi sessions get for free. Monitoring
        /// does not need it, so the path is: open → remote mode → prove live
        /// view streams. [verify-on-HW: ZR over USB-C, 2026-07-17 — connects,
        /// streams 24 fps, full metadata.]
        private static func establishUSBSession(
            on session: PTPIPClientSession,
            onPhase: (CameraConnectionPhase, String) -> Void
        ) throws {
            try session.openSession()
            // Application mode — NOT remote mode — is what keeps the camera
            // BODY awake (remote mode locks it to "Connected to computer").
            // iOS only ever uses application mode. Over USB the ZR's app-mode
            // switch blocks on delivering a StoreRemoved event, so the switch
            // is serviced with a concurrent event pump. The camera has no
            // GetPairingInfo/ConfirmPairing over USB (absent from its USB
            // OperationsSupported), so there is no pairing fallback here.
            if try session.enableAppControlServicingEvents() != .ok {
                // App mode still refused. Degrade to remote mode: the live
                // feed works, though the camera body stays on "Connected to
                // computer" (tracked follow-up). Better a working feed than a
                // failed connect.
                _ = try? session.executeTransaction(.changeCameraMode, parameters: [1])
            }
            try session.identify()
            onPhase(.connected, session.identity.displayName)
        }
    #endif

    private static func connectFirstTimePairing(
        host: String,
        port: UInt16,
        guid: Data,
        friendlyName: String,
        timeoutMilliseconds: Int32,
        onPhase: (CameraConnectionPhase, String) -> Void
    ) throws -> PTPIPClientSession {
        let session = try establishLink(
            host: host,
            port: port,
            guid: guid,
            friendlyName: friendlyName,
            timeoutMilliseconds: timeoutMilliseconds
        )
        do {
            try establishFirstTimePairing(on: session, onPhase: onPhase)
            return session
        } catch {
            session.disconnect()
            throw error
        }
    }

    private static func establishFirstTimePairing(
        on session: PTPIPClientSession,
        onPhase: (CameraConnectionPhase, String) -> Void
    ) throws {
        try session.openSession()
        onPhase(.pairing, "")
        let challenge = try session.waitForPairingChallenge()
        try session.transactExpectingOK(
            .confirmPairing,
            parameters: [PTPIPSessionScript.pairingConfirmValue]
        )
        // `ConfirmPairing` (app-side) has succeeded. The operator must still tap
        // Confirm on the camera body; that restarts the camera AP and this
        // temporary session cannot become a usable monitor session.
        //
        // Do NOT call ChangeApplicationMode / identify here: on real hardware
        // they race the body-confirm reboot, throw (often as a generic
        // unreachable/app-control failure), and Kotlin never reaches the
        // confirm-on-camera wait + saved-profile reconnect (iOS always shuts
        // down after first-time pairing and waits — see
        // `transitionToSavedCameraNetworkCheck`). Publish `confirmOnCamera`
        // then a soft `connected` with the handshake-level name so JNI
        // completes cleanly; the Android shell disconnects and reconnects.
        onPhase(.confirmOnCamera, challenge.pin ?? "")
        onPhase(.connected, session.identity.displayName)
    }

    #if os(Android)
        /// Establishes the same Nikon app-control session over a claimed USB
        /// PTP transport. The platform layer vends raw endpoint bytes only;
        /// generic containers, pairing, identity, and all camera operations
        /// remain in Swift/shared core just like the PTP-IP path.
        static func connectUSB(
            transport: AndroidUSBPTPTransport,
            host: String,
            cameraNameHint: String,
            strategy: ConnectionStrategy = .restoreProfileThenPairing,
            onPhase: (CameraConnectionPhase, String) -> Void = { _, _ in }
        ) throws -> PTPIPClientSession {
            onPhase(.handshaking, "")
            let session = PTPIPClientSession(
                usbTransport: transport,
                identity: PTPIPClientIdentity(
                    cameraName: cameraNameHint,
                    manufacturer: "",
                    model: "",
                    deviceVersion: "",
                    serialNumber: ""
                )
            )
            // The privacy-safe USB key is a Kotlin-local saved-record lookup;
            // PTP has no network host, so it is neither addressed nor sent here.
            _ = host
            // USB has no Nikon pairing gate: `GetPairingInfo` is a Wi-Fi-only
            // vendor flow, and issuing it on the cable is never answered and
            // wedges the body's USB stack until a replug. Every strategy
            // therefore runs the saved-profile establish here, and an
            // app-control refusal is surfaced as a real error, not routed to
            // pairing.
            _ = strategy
            // A timed-out earlier attempt can leave its response queued on the
            // still-claimed bulk-in pipe, shifting every later read one
            // transaction back. Start each attempt from an empty pipe.
            transport.drainStaleInput()
            do {
                // GetDeviceInfo is the only operation valid outside a session,
                // and every host stack (macOS ICC, Windows, libgphoto2) issues
                // it before OpenSession while enumerating. Observed on the ZR:
                // an OpenSession-first sequence is held unanswered while
                // CloseSession still answers instantly — so match the
                // universal order. Outside a session the TransactionID is 0.
                _ = try transport.executeTransactionSynchronously(
                    operationCode: .getDeviceInfo,
                    transactionID: 0,
                    dataPhase: .dataIn,
                    deadline: .seconds(5)
                )
                try establishUSBSession(on: session, onPhase: onPhase)
                return session
            } catch {
                session.disconnect()
                throw error
            }
        }
    #endif

    /// Opens both TCP channels and runs the PTP-IP Init handshake; returns a
    /// session whose identity carries only the handshake camera name so far.
    private static func establishLink(
        host: String,
        port: UInt16,
        guid: Data,
        friendlyName: String,
        timeoutMilliseconds: Int32
    ) throws -> PTPIPClientSession {
        let command = PosixTCPSocket(
            host: host, port: port, label: "command", timeoutMilliseconds: timeoutMilliseconds)
        let event = PosixTCPSocket(
            host: host, port: port, label: "event", timeoutMilliseconds: timeoutMilliseconds)
        do {
            try command.open()
            let initRequest = try PTPIPInitCommandRequest(guid: guid, friendlyName: friendlyName)
            try command.send(
                PTPIPPacket(type: .initCommandRequest, payload: Data(initRequest.payloadBytes)))
            let initReply = try command.readPacket()
            if initReply.type == .initFail {
                let fail = try PTPIPInitFail(payloadBytes: Array(initReply.payload))
                throw PTPIPClientSessionError.initFailed(fail.reason)
            }
            guard initReply.type == .initCommandAck else {
                throw PTPIPClientSessionError.unexpectedPacket(
                    expected: "Init_Command_Ack", actual: initReply.type)
            }
            let ack = try PTPIPInitCommandAck(payloadBytes: Array(initReply.payload))

            try event.open()
            try event.send(
                PTPIPPacket(
                    type: .initEventRequest,
                    payload: Data(
                        PTPIPInitEventRequest(connectionNumber: ack.connectionNumber).payloadBytes))
            )
            let eventReply = try event.readPacket()
            guard eventReply.type == .initEventAck else {
                throw PTPIPClientSessionError.unexpectedPacket(
                    expected: "Init_Event_Ack", actual: eventReply.type)
            }

            let identity = PTPIPClientIdentity(
                cameraName: ack.cameraName ?? "Nikon camera",
                manufacturer: "", model: "", deviceVersion: "", serialNumber: "")
            return PTPIPClientSession(command: command, event: event, identity: identity)
        } catch {
            command.close()
            event.close()
            throw error
        }
    }

    // MARK: - Session sequence steps

    private func openSession() throws {
        let open = try executeTransaction(.openSession, transactionID: 0, parameters: [1])
        let response = open.operationResponse.responseCode
        guard response == .ok || response == .sessionAlreadyOpen else {
            throw PTPIPClientSessionError.operationRejected(.openSession, response)
        }
    }

    /// Nikon app-control gate. `true` when the camera accepted app control —
    /// `false` routes the caller to first-time pairing (core probe policy).
    private func enableAppControl() throws -> Bool {
        try enableAppControlResponse() == .ok
    }

    /// `ChangeApplicationMode` returning the raw response so the USB path can
    /// branch on Access_Denied vs OK (Session_Already_Open never applies to
    /// this op).
    func enableAppControlResponse() throws -> PTPResponseCode {
        try executeTransaction(.changeApplicationMode, parameters: [1])
            .operationResponse.responseCode
    }

    #if os(Android)
        /// `ChangeApplicationMode` with the interrupt/event pipe serviced on a
        /// side thread for the duration of the call. Entering application mode
        /// makes the ZR emit a StoreRemoved event, and over USB it stalls the
        /// switch (~5 s, then Access_Denied) until the host drains that event.
        /// ImageCaptureCore on iOS always runs an event loop, so it never
        /// stalls; our establish is single-threaded, so pump events here. The
        /// event endpoint has its own lock — this never blocks the command
        /// pipe carrying the app-mode request itself.
        func enableAppControlServicingEvents() throws -> PTPResponseCode {
            guard let usbTransport else { return try enableAppControlResponse() }
            let pump = USBEventPumpFlag()
            Thread.detachNewThread {
                while !pump.stopRequested {
                    usbTransport.servicePendingEvent(timeoutMilliseconds: 250)
                }
            }
            defer { pump.requestStop() }
            return try enableAppControlResponse()
        }
    #endif

    /// Polls `GetPairingInfo` until the camera produces a pairing challenge,
    /// with the same cadence as the iOS shell (10 attempts, 250 ms apart).
    private func waitForPairingChallenge() throws -> PTPIPPairingChallenge {
        for _ in 1...10 {
            if let pairInfo = try? executeTransaction(.getPairingInfo, dataPhase: .dataIn),
                PTPIPPairingInfoPolicy.resolve(
                    response: pairInfo.operationResponse.responseCode,
                    byteCount: pairInfo.data.count) == .promptUser
            {
                return PTPIPPairingChallenge(data: pairInfo.data, cameraName: identity.cameraName)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw PTPIPClientSessionError.pairingChallengeUnavailable
    }

    /// Runs `GetDeviceInfo` and fills in the full identity — in place, so the
    /// session's transaction-ID sequence keeps counting (a fresh instance here
    /// once restarted IDs mid-session, which a real body may reject).
    private func identify() throws {
        let info = try transactExpectingOK(.getDeviceInfo, dataPhase: .dataIn)
        let deviceInfo = try PTPDeviceInfo(data: info.data)
        identity = PTPIPClientIdentity(
            cameraName: identity.cameraName.isEmpty ? deviceInfo.model : identity.cameraName,
            manufacturer: deviceInfo.manufacturer,
            model: deviceInfo.model,
            deviceVersion: deviceInfo.deviceVersion,
            serialNumber: deviceInfo.serialNumber)
    }

    // MARK: - Properties

    /// Reads one camera property and returns its raw bytes. Mirrors the write path:
    /// standard 16-bit codes use `GetDevicePropValue` (0x1015) — the only property ops
    /// gen-1/2 bodies have, and the ones the ZR expects for 2-byte codes — while the
    /// 4-byte extended `0x0001_xxxx` codes use `GetDevicePropValueEx`.
    public func readProperty(_ property: PTPPropertyCode) throws -> Data {
        let operation: PTPOperationCode =
            property.rawValue <= UInt32(UInt16.max)
            ? .getDevicePropValue
            : .getDevicePropValueEx
        return try transactExpectingOK(
            operation, parameters: [property.rawValue], dataPhase: .dataIn
        ).data
    }

    /// Reads one property descriptor with the same width routing as `readProperty`.
    /// Callers decode it only through shared-core descriptor policy.
    private func readPropertyDescriptor(_ property: PTPPropertyCode) throws -> Data {
        let operation: PTPOperationCode =
            property.rawValue <= UInt32(UInt16.max)
            ? .getDevicePropDesc
            : .getDevicePropDescEx
        return try transactExpectingOK(
            operation,
            parameters: [property.rawValue],
            dataPhase: .dataIn
        ).data
    }

    private func descriptorEnumValues(
        _ property: PTPPropertyCode,
        valueByteCount: Int
    ) throws -> [UInt32] {
        let values = try descriptorEnumBytes(property, valueByteCount: valueByteCount)
        return values.map { bytes in
            switch valueByteCount {
            case 1: UInt32(bytes[0])
            case 2: UInt32(ByteCoding.readUInt16LE(bytes, at: 0))
            default: ByteCoding.readUInt32LE(bytes, at: 0)
            }
        }
    }

    private func descriptorEnumBytes(
        _ property: PTPPropertyCode,
        valueByteCount: Int
    ) throws -> [[UInt8]] {
        let form = try writableDescriptorForm(property, valueByteCount: valueByteCount)
        guard case .enumeration(let values) = form else {
            throw PTPIPClientSessionError.unwritablePropertyDescriptor(property.rawValue)
        }
        return values
    }

    private func writableDescriptorForm(
        _ property: PTPPropertyCode,
        valueByteCount: Int
    ) throws -> AndroidWritableDescriptorForm {
        let descriptor = try readPropertyDescriptor(property)
        return try Self.writableDescriptorForm(
            descriptor,
            property: property,
            valueByteCount: valueByteCount)
    }

    /// Validates a DevicePropDesc / DevicePropDescEx dataset before any value becomes a write
    /// capability. Accepts both:
    /// - **Ex / FakeZR shape:** UINT32 property code + UINT16 type + GetSet + defaults…
    /// - **Standard 16-bit shape:** UINT16 property code (e.g. `0xD0A0`) + UINT16 type + …
    /// which real Nikon bodies use for some movie properties over `GetDevicePropDescEx`.
    private static func writableDescriptorForm(
        _ descriptor: Data,
        property: PTPPropertyCode,
        valueByteCount: Int
    ) throws -> AndroidWritableDescriptorForm {
        let bytes = [UInt8](descriptor)
        let expectedDataType: UInt16 =
            switch valueByteCount {
            case 1: 0x0002  // UINT8
            case 2: 0x0004  // UINT16
            case 4: 0x0006  // UINT32
            case 8: 0x0008  // UINT64
            default: 0
            }
        guard expectedDataType != 0, bytes.count >= 7 else {
            throw PTPIPClientSessionError.invalidPropertyDescriptor(property.rawValue)
        }

        // Layout A: UINT32 property code (Ex datasets / FakeZR).
        let exProperty = ByteCoding.readUInt32LE(bytes, at: 0)
        let exType = ByteCoding.readUInt16LE(bytes, at: 4)
        let exGetSet = bytes[6]
        let exFormIndex = 7 + valueByteCount * 2

        // Layout B: UINT16 property code (standard DevicePropDesc).
        let stdProperty = UInt32(ByteCoding.readUInt16LE(bytes, at: 0))
        let stdType = ByteCoding.readUInt16LE(bytes, at: 2)
        let stdGetSet = bytes[4]
        let stdFormIndex = 5 + valueByteCount * 2

        let formIndex: Int
        let getSet: UInt8
        if exProperty == property.rawValue, exType == expectedDataType,
            exGetSet == 0 || exGetSet == 1, bytes.count > exFormIndex
        {
            formIndex = exFormIndex
            getSet = exGetSet
        } else if stdProperty == property.rawValue, stdType == expectedDataType,
            stdGetSet == 0 || stdGetSet == 1, bytes.count > stdFormIndex
        {
            formIndex = stdFormIndex
            getSet = stdGetSet
        } else {
            throw PTPIPClientSessionError.invalidPropertyDescriptor(property.rawValue)
        }
        guard getSet == 1 else {
            throw PTPIPClientSessionError.unwritablePropertyDescriptor(property.rawValue)
        }

        switch bytes[formIndex] {
        case 0:
            throw PTPIPClientSessionError.unwritablePropertyDescriptor(property.rawValue)
        case 1:
            let valuesStart = formIndex + 1
            guard valuesStart + valueByteCount * 3 == bytes.count else {
                throw PTPIPClientSessionError.invalidPropertyDescriptor(property.rawValue)
            }
            return .range(
                minimum: Array(bytes[valuesStart..<(valuesStart + valueByteCount)]),
                maximum: Array(
                    bytes[(valuesStart + valueByteCount)..<(valuesStart + valueByteCount * 2)]),
                step: Array(
                    bytes[(valuesStart + valueByteCount * 2)..<(valuesStart + valueByteCount * 3)]))
        case 2:
            guard formIndex + 3 <= bytes.count else {
                throw PTPIPClientSessionError.invalidPropertyDescriptor(property.rawValue)
            }
            let count = Int(ByteCoding.readUInt16LE(bytes, at: formIndex + 1))
            let valuesStart = formIndex + 3
            guard valuesStart + count * valueByteCount == bytes.count else {
                throw PTPIPClientSessionError.invalidPropertyDescriptor(property.rawValue)
            }
            return .enumeration(
                (0..<count).map { item in
                    let start = valuesStart + item * valueByteCount
                    return Array(bytes[start..<(start + valueByteCount)])
                })
        default:
            throw PTPIPClientSessionError.invalidPropertyDescriptor(property.rawValue)
        }
    }

    /// Reads a property and decodes it through the core: battery level comes
    /// back as a percentage string (`"80"`), anything else as the raw
    /// little-endian value in hex (`"0x0"`) until its decoder is wired up.
    public func readPropertyDisplayValue(code: UInt32) throws -> String {
        guard let property = PTPPropertyCode(rawValue: code) else {
            throw PTPIPClientSessionError.unsupportedProperty(code)
        }
        let data = try readProperty(property)
        let snapshot = PTPCameraPropertySnapshot().applying(property: property, data: data)
        if property == .batteryLevel, let percent = snapshot.batteryPercent {
            return "\(percent)"
        }
        // ponytail: generic hex fallback — per-property display decoding grows
        // with the monitor UI slice; the raw value is what HW validation needs.
        var value: UInt64 = 0
        for byte in Array(data).prefix(8).reversed() {
            value = value << 8 | UInt64(byte)
        }
        return "0x\(Self.hexString(value))"
    }

    /// Refreshes the semantic Android monitor readback without exposing a PTP
    /// property ID or encoded bytes to Kotlin.
    ///
    /// Bootstrap runs a **full** live-monitor property burst plus storage and
    /// control descriptors so AF mode, lens, subject, audio, and VR land before
    /// the first live-view frame is shown. The Android shell holds the feed
    /// until that burst finishes. Subsequent `.next` calls resume one-property
    /// round-robin (codec kept immediately before screen-size). Polling never
    /// disconnects the session on a body-specific unsupported field.
    public func refreshAndroidPropertySnapshot(
        _ request: AndroidCameraPropertyRefreshRequest
    ) -> AndroidCameraPropertyReadback {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            return androidPropertyReadback(result: .mediaBusy)
        }

        switch request {
        case .bootstrap:
            var result: AndroidCameraPropertyRefreshResult = .accepted
            // Full live order — same set as steady-state poll, read back-to-back
            // so the operator does not wait ~30s for focus/lens/subject.
            for property in Self.androidLiveMonitorPollOrder {
                result = mergedAndroidPropertyRefreshResult(
                    result, refreshAndroidProperty(property))
                if result == .transportFailed { break }
            }
            if result != .transportFailed {
                result = mergedAndroidPropertyRefreshResult(result, refreshAndroidStorage())
            }
            if result != .transportFailed {
                result = mergedAndroidPropertyRefreshResult(
                    result, refreshAndroidControlDescriptors())
            }
            // Steady-state `.next` starts after the complete set has been seeded.
            androidPropertyPollIndex = 0
            return androidPropertyReadback(result: result)
        case .next(let isRecording):
            // While GetLiveViewImageEx is pumping, every extra PTP transaction
            // steals `transactionLock` and punches a visible hole in the feed
            // (seen as a hitch every ~1.5–3 s). Keep steady-state polls to a
            // single property; defer storage/descriptor/screen-size extras
            // until live view is idle (Command / media / standby).
            // High-priority LiveViewSelector interleave (every other tick) so
            // photo/video chrome flips without waiting a full round-robin cycle.
            let liveViewStreaming = liveViewIsActive()
            let property = PTPPropertyCode.nextMonitorPollProperty(
                pollIndex: androidPropertyPollIndex,
                isRecording: isRecording,
                captureSelector: androidPropertySnapshot.captureSelector,
                order: Self.androidMonitorPollOrder(
                    isRecording: isRecording,
                    captureSelector: androidPropertySnapshot.captureSelector))
            androidPropertyPollIndex &+= 1
            let previousFileType = androidPropertySnapshot.fileType
            var result = refreshAndroidProperty(property)
            if property == .movieFileType,
                result == .accepted,
                androidPropertySnapshot.fileType != previousFileType
            {
                result = mergedAndroidPropertyRefreshResult(
                    result,
                    refreshAndroidScreenSizeAfterCodecChange()
                )
            }
            // Body-side REC dial: re-sample MovScreenSize when the feed is not
            // owning the wire. During live view, trust DevicePropChanged + the
            // regular round-robin slot for D0A0 instead of a dual hit.
            if !liveViewStreaming,
                !isRecording,
                result != .transportFailed,
                property != .movieRecordScreenSize,
                androidPropertyPollIndex % 3 == 0
            {
                result = mergedAndroidPropertyRefreshResult(
                    result, refreshAndroidProperty(.movieRecordScreenSize))
            }
            if !liveViewStreaming,
                result != .transportFailed,
                CameraMonitorPollPolicy.isDue(
                    lastRefreshAt: androidLastStorageRefreshAt,
                    now: Date(),
                    interval: CameraMonitorPollPolicy.storageRefreshInterval)
            {
                result = mergedAndroidPropertyRefreshResult(result, refreshAndroidStorage())
            }
            if !liveViewStreaming,
                result != .transportFailed,
                !isRecording,
                CameraMonitorPollPolicy.isDue(
                    lastRefreshAt: androidLastDescriptorRefreshAt,
                    now: Date(),
                    interval: CameraMonitorPollPolicy.descriptorRefreshInterval)
            {
                result = mergedAndroidPropertyRefreshResult(
                    result, refreshAndroidControlDescriptors())
            }
            return androidPropertyReadback(result: result)
        case .evIndicator:
            // While the EV tool is on, the needle reads on its own fast Kotlin
            // cadence between round-robin ticks — a needle visited once per full
            // property cycle lags the meter by minutes. The lit-state gate
            // refreshes on a slow stride, like the iOS fast poll.
            androidEVIndicatorPollTick &+= 1
            return androidPropertyReadback(
                result: refreshAndroidProperty(
                    androidEVIndicatorPollTick.isMultiple(of: 8)
                        ? .exposureIndicateLightup : .exposureIndicateStatus))
        case .propertyChanged(let rawCode):
            guard let property = PTPPropertyCode(rawValue: rawCode),
                PTPPropertyCode.liveMonitorPollOrder.contains(property)
            else {
                // The event stream preserves unknown properties for callers,
                // but a raw event alone is not evidence that this readback
                // model knows how to decode one.
                return androidPropertyReadback(result: .accepted)
            }
            let result = refreshAndroidProperty(property)
            // Codec change still rebuilds the rate domain; a plain D0A0 value change only
            // needs the value read above (plus live-pack reconcile inside that read).
            guard property == .movieFileType, result == .accepted else {
                return androidPropertyReadback(result: result)
            }
            return androidPropertyReadback(
                result: mergedAndroidPropertyRefreshResult(
                    result,
                    refreshAndroidScreenSizeAfterCodecChange()
                )
            )
        }
    }

    /// Performs one shared-core property read and updates only that decoded
    /// field in the accumulated Android snapshot.
    private func refreshAndroidProperty(
        _ property: PTPPropertyCode
    ) -> AndroidCameraPropertyRefreshResult {
        do {
            let data = try readProperty(property)
            guard property != .movieRecordScreenSize || data.count >= 8 else {
                androidScreenSizeReadbackIsCurrent = false
                return .transportFailed
            }
            guard property != .movieFileType || data.count >= 4 else {
                return .transportFailed
            }
            let previousFileType = androidPropertySnapshot.fileType
            androidPropertySnapshot = androidPropertySnapshot.applying(
                property: property, data: data)
            if property == .movieRecordScreenSize {
                androidScreenSizeReadbackIsCurrent = true
            } else if property == .movieFileType,
                previousFileType != nil,
                androidPropertySnapshot.fileType != previousFileType
            {
                androidScreenSizeReadbackIsCurrent = false
            }
            return .accepted
        } catch let error as PTPIPClientSessionError {
            switch error {
            case .mediaModeActive, .mediaModeRequired:
                return .mediaBusy
            case .operationRejected, .unsupportedProperty:
                return .unsupported
            default:
                return .transportFailed
            }
        } catch {
            return .transportFailed
        }
    }

    /// Refreshes every valid card at the shared core's slow storage cadence.
    private func refreshAndroidStorage() -> AndroidCameraPropertyRefreshResult {
        do {
            let enumerated = try readAllStorageInfo()
            // The physical slot lives in the storage ID's high word (0x000X0001) — the
            // enumerated order does NOT follow it (the second card can arrive appended
            // via the vendor storage list), which would label slot 1's card "SLOT 2" in
            // the media chips. Number by the physical slot and sort, falling back to
            // list order for IDs without the slot-word pattern. [verify-on-HW]
            var slots = enumerated.enumerated().map { index, slot in
                let physicalSlot = Int((slot.id >> 16) & 0xFF)
                return AndroidCameraStorageSlot(
                    storageID: slot.id,
                    slotNumber: physicalSlot > 0 ? physicalSlot : index + 1,
                    storage: slot.info)
            }
            .sorted { $0.slotNumber < $1.slotNumber }
            if Set(slots.map(\.slotNumber)).count != slots.count {
                // A duplicate physical number would fail the wire's strictly-increasing
                // guard and drop every card — keep the old list-order numbering instead.
                slots = enumerated.enumerated().map { index, slot in
                    AndroidCameraStorageSlot(
                        storageID: slot.id, slotNumber: index + 1, storage: slot.info)
                }
            }
            guard !slots.isEmpty else {
                androidStorageInfo = nil
                androidStorageSlots = []
                return .unsupported
            }
            androidStorageSlots = slots
            // The legacy single-card readout keeps the camera's enumeration-first card,
            // independent of the display sort.
            androidStorageInfo = enumerated.first?.info
            androidLastStorageRefreshAt = Date()
            return .accepted
        } catch let error as PTPIPClientSessionError {
            switch error {
            case .mediaModeActive, .mediaModeRequired:
                return .mediaBusy
            case .operationRejected:
                return .unsupported
            default:
                return .transportFailed
            }
        } catch {
            return .transportFailed
        }
    }

    /// Refreshes each Android control descriptor independently. A body may
    /// advertise only a subset; one unsupported descriptor must not hide the
    /// valid controls that follow it.
    private func refreshAndroidControlDescriptors() -> AndroidCameraPropertyRefreshResult {
        // Build one new capability generation under commandLifecycleLock. Callers never observe a
        // half-built catalog: either the new generation becomes complete, or the previous complete
        // generation is retained. A single descriptor parse failure must not wipe every control.
        let previousCatalog = androidControlCatalog
        let previousTint = androidWhiteBalanceTint
        androidControlCatalog = AndroidRawControlCatalog()
        androidWhiteBalanceTint = nil
        let refreshers: [() throws -> Void] = [
            refreshAndroidScreenSizeDescriptor,
            refreshAndroidFileTypeDescriptor,
            refreshAndroidApertureDescriptor,
            refreshAndroidWhiteBalanceKelvinDescriptor,
            refreshAndroidWhiteBalanceModeDescriptor,
            refreshAndroidFocusModeDescriptor,
            refreshAndroidFocusAreaDescriptor,
            refreshAndroidFocusSubjectDescriptor,
            refreshAndroidAudioSensitivityDescriptor,
            refreshAndroidAudioInputDescriptor,
            refreshAndroidWindFilterDescriptor,
            refreshAndroidAttenuatorDescriptor,
            refreshAndroidAudio32BitFloatDescriptor,
            refreshAndroidShutterAngleDescriptor,
            refreshAndroidShutterSpeedDescriptor,
            refreshAndroidBaseISODescriptor,
            refreshAndroidShutterModeDescriptor,
            refreshAndroidShutterLockDescriptor,
            refreshAndroidWhiteBalanceTintDescriptor,
            refreshAndroidVibrationReductionDescriptor,
            refreshAndroidElectronicVRDescriptor,
            // Photo-mode enums (stills shutter / photo WB presets / image sizes).
            // Bodies reject them in movie mode; the walk continues past that.
            refreshAndroidStillShutterDescriptor,
            refreshAndroidStillWhiteBalanceDescriptor,
            refreshAndroidImageSizeDescriptor,
        ]
        var result: AndroidCameraPropertyRefreshResult = .accepted
        for refresh in refreshers {
            do {
                try refresh()
            } catch let error as PTPIPClientSessionError {
                result = mergedAndroidPropertyRefreshResult(
                    result, androidDescriptorResult(for: error))
            } catch {
                result = .transportFailed
            }
            // Keep walking independent descriptors after unsupported/rejected forms so one
            // body-specific omission cannot hide the rest. Only a dead transport aborts early.
            if result == .transportFailed || result == .mediaBusy { break }
        }
        if result == .transportFailed || result == .mediaBusy {
            // Prefer the last complete catalog over a blank generation so open pickers keep working
            // across a transient GetDevicePropDescEx glitch while live view holds the channel.
            if previousCatalog.isComplete {
                androidControlCatalog = previousCatalog
                androidWhiteBalanceTint = previousTint
            } else {
                androidControlCatalog = AndroidRawControlCatalog()
                androidWhiteBalanceTint = nil
            }
        } else {
            androidControlCatalog.isComplete = true
            androidLastDescriptorRefreshAt = Date()
        }
        return result
    }

    private func refreshAndroidScreenSizeDescriptor() throws {
        // Build the next domain off to the side so a failed re-read never blanks a still-valid
        // catalog (body-side REC changes re-enter here frequently).
        let descriptor = try readPropertyDescriptor(.movieRecordScreenSize)
        // Prefer the strict Ex-shaped parser (FakeZR + well-formed bodies). Real ZR firmware
        // sometimes returns a standard 16-bit DevicePropDesc for 0xD0A0 that fails the
        // 32-bit header check — fall back to the shared-core scan that finds the enum
        // form flag anywhere in the payload so REC options stay writable.
        //
        // HARD RULE: never invent packed MovScreenSize values. Writing an unadvertised
        // combination (lab fallbacks / bit-spliced fps) can reboot a Nikon ZR. Only the
        // exact 8-byte enum entries from this descriptor may become write targets.
        let parsed: [PTPCameraScreenSizeMode]
        do {
            let form = try Self.writableDescriptorForm(
                descriptor,
                property: .movieRecordScreenSize,
                valueByteCount: 8)
            guard case .enumeration(let values) = form else {
                throw PTPIPClientSessionError.unwritablePropertyDescriptor(
                    PTPPropertyCode.movieRecordScreenSize.rawValue)
            }
            parsed = values.compactMap { bytes in
                guard bytes.count >= 8 else { return nil }
                let raw = ByteCoding.readUInt64LE(bytes, at: 0)
                return Self.screenSizeMode(raw: raw)
            }
        } catch {
            let modes = PTPCameraPropertyDecoders.screenSizeModes(fromDescriptor: descriptor)
            guard !modes.isEmpty else { throw error }
            parsed = modes
        }
        guard !parsed.isEmpty else {
            throw PTPIPClientSessionError.unwritablePropertyDescriptor(
                PTPPropertyCode.movieRecordScreenSize.rawValue)
        }
        // Keep the descriptor enum verbatim — same as iOS `cameraScreenModes`. Never rewrite
        // advertised packs from a live readback; write path uses exact catalog raws only.
        androidControlCatalog.screenSizes = parsed
    }

    private static func screenSizeMode(raw: UInt64) -> PTPCameraScreenSizeMode? {
        let size = PTPCameraPropertyDecoders.screenSize(raw)
        guard size.width >= 640, size.width <= 8_192, size.height >= 360,
            size.height <= 5_000, size.fps >= 1, size.fps <= 240
        else { return nil }
        return PTPCameraScreenSizeMode(
            raw: raw,
            label: MonitorTextFormat.resolutionLabel(
                pixelWidth: size.width,
                pixelHeight: size.height,
                frameRate: Double(size.fps)))
    }

    private func refreshAndroidFileTypeDescriptor() throws {
        androidControlCatalog.fileTypes = []
        do {
            let modes = PTPCameraPropertyDecoders.fileTypeModes(
                fromEnum: try descriptorEnumValues(.movieFileType, valueByteCount: 4))
            androidControlCatalog.fileTypes =
                modes.isEmpty && usesNikonZRFallbacks
                ? AndroidNikonZRControlFallback.fileTypes : modes
        } catch let error as PTPIPClientSessionError {
            guard usesNikonZRFallbacks, isDescriptorFallbackEligible(error) else { throw error }
            androidControlCatalog.fileTypes = AndroidNikonZRControlFallback.fileTypes
        }
    }

    private func refreshAndroidApertureDescriptor() throws {
        androidControlCatalog.apertures = []
        androidControlCatalog.allowsApertureFallback = false
        do {
            let raw = try descriptorEnumValues(.movieFNumber, valueByteCount: 2)
            let modes = uniqueUInt16Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.irisFNumber(value)
                return label == "—" ? nil : label
            }
            guard raw.isEmpty || !modes.isEmpty else {
                throw PTPIPClientSessionError.unwritablePropertyDescriptor(
                    PTPPropertyCode.movieFNumber.rawValue)
            }
            androidControlCatalog.apertures = modes
            androidControlCatalog.allowsApertureFallback = raw.isEmpty && usesNikonZRFallbacks
        } catch let error as PTPIPClientSessionError {
            guard usesNikonZRFallbacks, isDescriptorFallbackEligible(error) else { throw error }
            androidControlCatalog.allowsApertureFallback = true
        }
    }

    private func refreshAndroidWhiteBalanceKelvinDescriptor() throws {
        androidControlCatalog.whiteBalanceKelvin = []
        androidControlCatalog.whiteBalanceKelvin = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.whiteBalanceKelvin
        ) {
            let raw = try descriptorEnumValues(.movieWBColorTemp, valueByteCount: 2)
            return uniqueUInt16Modes(raw) { value in
                (1_000...50_000).contains(value) ? "\(value)K" : nil
            }
        }
    }

    private func refreshAndroidWhiteBalanceModeDescriptor() throws {
        androidControlCatalog.whiteBalanceModes = []
        androidControlCatalog.whiteBalanceModes = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.whiteBalanceModes
        ) {
            let raw = try descriptorEnumValues(.movieWhiteBalance, valueByteCount: 2)
            return uniqueUInt16Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.whiteBalanceMode(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
    }

    private func refreshAndroidFocusModeDescriptor() throws {
        androidControlCatalog.focusModes = []
        let advertised = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.focusModes
        ) {
            let raw = try descriptorEnumValues(.movieFocusMode, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.movieFocusMode(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
        androidControlCatalog.focusModes =
            usesNikonZRFallbacks
            ? mergedModes(AndroidNikonZRControlFallback.focusModes, advertised)
            : advertised
    }

    private func refreshAndroidFocusAreaDescriptor() throws {
        androidControlCatalog.focusAreas = []
        androidControlCatalog.focusAreas = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.focusAreas
        ) {
            let raw = try descriptorEnumValues(.movieFocusMeteringMode, valueByteCount: 2)
            return uniqueUInt16Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.movieFocusArea(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
    }

    private func refreshAndroidFocusSubjectDescriptor() throws {
        androidControlCatalog.focusSubjects = []
        androidControlCatalog.focusSubjects = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.focusSubjects
        ) {
            let raw = try descriptorEnumValues(.movieAFSubjectDetection, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.movieAFSubject(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
    }

    private func refreshAndroidAudioSensitivityDescriptor() throws {
        androidControlCatalog.audioSensitivities = []
        androidControlCatalog.audioSensitivities = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.audioSensitivities
        ) {
            let raw = try descriptorEnumValues(.movieAudioInputSensitivity, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.audioInputSensitivity(value)
                return PTPCameraPropertyDecoders.audioInputSensitivityCode(for: label) == nil
                    ? nil : label
            }
        }
    }

    private func refreshAndroidAudioInputDescriptor() throws {
        androidControlCatalog.audioInputs = []
        androidControlCatalog.audioInputs = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.audioInputs
        ) {
            let raw = try descriptorEnumValues(.audioInputSelection, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.audioInputSelection(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
    }

    private func refreshAndroidWindFilterDescriptor() throws {
        androidControlCatalog.windFilters = []
        androidControlCatalog.windFilters = try refreshAndroidOnOffDescriptor(
            .movWindNoiseReduction)
    }

    private func refreshAndroidAttenuatorDescriptor() throws {
        androidControlCatalog.attenuators = []
        androidControlCatalog.attenuators = try refreshAndroidOnOffDescriptor(.movieAttenuator)
    }

    private func refreshAndroidAudio32BitFloatDescriptor() throws {
        androidControlCatalog.audio32BitFloat = []
        androidControlCatalog.audio32BitFloat = try refreshAndroidOnOffDescriptor(
            .movie32BitFloatAudioRecording)
    }

    private func refreshAndroidOnOffDescriptor(
        _ property: PTPPropertyCode
    ) throws -> [AndroidRawControlMode<UInt8>] {
        try descriptorModesWithZRFallback(fallback: AndroidNikonZRControlFallback.onOff) {
            let raw = try descriptorEnumValues(property, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                guard value == 0 || value == 1 else { return nil }
                return PTPCameraPropertyDecoders.onOffLabel(value)
            }
        }
    }

    private func refreshAndroidShutterAngleDescriptor() throws {
        androidControlCatalog.shutterAngles = []
        let raw = try descriptorEnumValues(.movieShutterAngle, valueByteCount: 4)
        androidControlCatalog.shutterAngles = uniqueUInt32Modes(raw) {
            PTPCameraPropertyDecoders.shutterAngle(Int32(bitPattern: $0))
        }
    }

    private func refreshAndroidShutterSpeedDescriptor() throws {
        androidControlCatalog.shutterSpeeds = []
        let raw = try descriptorEnumValues(.movieShutterSpeed, valueByteCount: 4)
        androidControlCatalog.shutterSpeeds = uniqueUInt32Modes(raw) { value in
            let label = PTPCameraPropertyDecoders.shutterSpeed(value)
            return label.contains("/") ? label : nil
        }
    }

    private func refreshAndroidBaseISODescriptor() throws {
        androidControlCatalog.baseISO = []
        androidControlCatalog.baseISO = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.baseISO
        ) {
            let raw = try descriptorEnumValues(.movieBaseISO, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.baseISO(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
    }

    private func refreshAndroidShutterModeDescriptor() throws {
        androidControlCatalog.shutterModes = []
        let raw = try descriptorEnumValues(.movieShutterMode, valueByteCount: 1)
        androidControlCatalog.shutterModes = uniqueUInt8Modes(raw) { value in
            guard value == 1 || value == 2 else { return nil }
            return PTPCameraPropertyDecoders.shutterMode(value) == .speed ? "Speed" : "Angle"
        }
    }

    private func refreshAndroidShutterLockDescriptor() throws {
        androidControlCatalog.shutterLocks = []
        let raw = try descriptorEnumValues(.movieTVLockSetting, valueByteCount: 1)
        androidControlCatalog.shutterLocks = uniqueUInt8Modes(raw) { value in
            switch value {
            case 0: "Unlocked"
            case 1: "Locked"
            default: nil
            }
        }
    }

    private func refreshAndroidStillShutterDescriptor() throws {
        // The body enumerates stills speeds valid for the active program/flash
        // state (fraction-packed `ShutterSpeed` plus the Bulb/Time sentinels).
        // Sentinels a picker cannot re-encode are dropped like iOS. [verify-on-HW]
        androidControlCatalog.stillShutterSpeeds = []
        let raw = try descriptorEnumValues(.stillShutterSpeed, valueByteCount: 4)
        androidControlCatalog.stillShutterSpeeds = uniqueUInt32Modes(raw) { value in
            let label = PTPCameraPropertyDecoders.stillShutterLabel(value)
            guard PTPCameraPropertyDecoders.stillShutterRaw(for: label) != nil else {
                return nil
            }
            return label
        }
    }

    private func refreshAndroidStillWhiteBalanceDescriptor() throws {
        // Photo WB preset enum (`WhiteBalance` 0x5005) — the photography popup's
        // Preset drum follows it, mirroring iOS's stills WB option source.
        androidControlCatalog.stillWhiteBalanceModes = []
        let raw = try descriptorEnumValues(.whiteBalance, valueByteCount: 2)
        androidControlCatalog.stillWhiteBalanceModes = uniqueUInt16Modes(raw) { value in
            let label = PTPCameraPropertyDecoders.whiteBalanceMode(value)
            return label.hasPrefix("0x") ? nil : label
        }
    }

    private func refreshAndroidImageSizeDescriptor() throws {
        // `ImageSize` is a string enumeration ("Size L" / resolution strings);
        // the SIZE picker offers the exact strings and writes them verbatim.
        androidControlCatalog.imageSizes = []
        let descriptor = try readPropertyDescriptor(.imageSize)
        androidControlCatalog.imageSizes =
            PTPCameraPropertyDecoders.devicePropDescStringEnumValues(data: descriptor)
    }

    private func refreshAndroidWhiteBalanceTintDescriptor() throws {
        androidControlCatalog.whiteBalanceTints = []
        androidWhiteBalanceTint = nil
        guard
            let mode = androidPropertySnapshot.wbMode,
            let property = WhiteBalanceTint.tuneProperty(
                forWBModeLabel: mode,
                // Photo mode fine-tunes the stills pad family (iOS routes by
                // the snapshot's selector). [verify-on-HW]
                photography: StillCapturePolicy.prefersPhotographyChrome(
                    selector: androidPropertySnapshot.captureSelector))
        else {
            return
        }
        let descriptor = try writableDescriptorForm(property, valueByteCount: 2)
        androidControlCatalog.whiteBalanceTints = Self.whiteBalanceTintModes(
            fromDescriptor: descriptor)
        let data = try readProperty(property)
        guard data.count >= 2 else { return }
        let raw = UInt16(data[0]) | UInt16(data[1]) << 8
        guard let cells = WhiteBalanceTint.cells(fromPropertyValue: raw) else { return }
        androidWhiteBalanceTint = WhiteBalanceTint.label(
            amberBlueCell: cells.amberBlue,
            greenMagentaCell: cells.greenMagenta)
    }

    private func refreshAndroidVibrationReductionDescriptor() throws {
        androidControlCatalog.vibrationReduction = []
        androidControlCatalog.vibrationReduction = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.vibrationReduction
        ) {
            let raw = try descriptorEnumValues(.movieVibrationReduction, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                let label = PTPCameraPropertyDecoders.movieVibrationReduction(value)
                return label.hasPrefix("0x") ? nil : label
            }
        }
    }

    private func refreshAndroidElectronicVRDescriptor() throws {
        androidControlCatalog.electronicVR = []
        androidControlCatalog.electronicVR = try descriptorModesWithZRFallback(
            fallback: AndroidNikonZRControlFallback.onOff
        ) {
            let raw = try descriptorEnumValues(.electronicVR, valueByteCount: 1)
            return uniqueUInt8Modes(raw) { value in
                guard value == 0 || value == 1 else { return nil }
                return PTPCameraPropertyDecoders.onOffLabel(value)
            }
        }
    }

    private func androidDescriptorResult(
        for error: PTPIPClientSessionError
    ) -> AndroidCameraPropertyRefreshResult {
        switch error {
        case .mediaModeActive, .mediaModeRequired: .mediaBusy
        // A malformed or unwritable *single* DevicePropDesc must not abort the whole catalog
        // refresh as a transport failure — that wiped ISO/WB/REC domains after one bad D0A0.
        case .operationRejected, .unsupportedProperty, .unwritablePropertyDescriptor,
            .invalidPropertyDescriptor:
            .unsupported
        default: .transportFailed
        }
    }

    /// Uses a known ZR control domain only when this connected body identifies as a Nikon ZR and
    /// its descriptor is omitted, rejected, or temporarily empty. Other models fail closed.
    private func descriptorModesWithZRFallback<Value>(
        fallback: [AndroidRawControlMode<Value>],
        load: () throws -> [AndroidRawControlMode<Value>]
    ) throws -> [AndroidRawControlMode<Value>]
    where Value: FixedWidthInteger & Sendable {
        do {
            let advertised = try load()
            if !advertised.isEmpty || !usesNikonZRFallbacks { return advertised }
            return fallback
        } catch let error as PTPIPClientSessionError {
            guard usesNikonZRFallbacks, isDescriptorFallbackEligible(error) else {
                throw error
            }
            return fallback
        }
    }

    private func isDescriptorFallbackEligible(_ error: PTPIPClientSessionError) -> Bool {
        switch error {
        // Real ZR firmware often returns DevicePropDesc layouts the strict Ex parser rejects
        // (16-bit headers, unexpected padding). Treat those like an omitted domain so ZR-only
        // ladders can still open. `unwritablePropertyDescriptor` (getSet=0) stays fail-closed —
        // the body explicitly said the property is not settable; do not invent writes.
        case .operationRejected, .unsupportedProperty, .invalidPropertyDescriptor:
            true
        default: false
        }
    }

    private func mergedModes<Value>(
        _ preferred: [AndroidRawControlMode<Value>],
        _ fallback: [AndroidRawControlMode<Value>]
    ) -> [AndroidRawControlMode<Value>]
    where Value: FixedWidthInteger & Sendable {
        var seen = Set<String>()
        return (preferred + fallback).filter { seen.insert($0.label).inserted }
    }

    private func uniqueUInt32Modes(
        _ rawValues: [UInt32],
        label: (UInt32) -> String?
    ) -> [AndroidRawControlMode<UInt32>] {
        var seen = Set<String>()
        return rawValues.compactMap { raw in
            guard let label = label(raw), seen.insert(label).inserted else { return nil }
            return AndroidRawControlMode(label: label, raw: raw)
        }
    }

    private func uniqueUInt16Modes(
        _ rawValues: [UInt32],
        label: (UInt16) -> String?
    ) -> [AndroidRawControlMode<UInt16>] {
        var seen = Set<String>()
        return rawValues.compactMap { raw in
            guard let value = UInt16(exactly: raw), let label = label(value),
                seen.insert(label).inserted
            else { return nil }
            return AndroidRawControlMode(label: label, raw: value)
        }
    }

    private func uniqueUInt8Modes(
        _ rawValues: [UInt32],
        label: (UInt8) -> String?
    ) -> [AndroidRawControlMode<UInt8>] {
        var seen = Set<String>()
        return rawValues.compactMap { raw in
            guard let value = UInt8(exactly: raw), let label = label(value),
                seen.insert(label).inserted
            else { return nil }
            return AndroidRawControlMode(label: label, raw: value)
        }
    }

    private static let whiteBalanceTintGrid:
        [(
            label: String, amberBlue: Int, greenMagenta: Int
        )] = {
            WhiteBalanceTint.cellRange.flatMap { greenMagenta in
                WhiteBalanceTint.cellRange.map { amberBlue in
                    (
                        WhiteBalanceTint.label(
                            amberBlueCell: amberBlue,
                            greenMagentaCell: greenMagenta),
                        amberBlue,
                        greenMagenta
                    )
                }
            }
        }()

    /// Resolves only tint cells the active property descriptor advertises.
    /// Enumeration descriptors retain their exact cells; range descriptors
    /// constrain the shared Nikon grid by the camera's min/max/step tuple.
    private static func whiteBalanceTintModes(
        fromDescriptor descriptor: AndroidWritableDescriptorForm
    ) -> [(label: String, amberBlue: Int, greenMagenta: Int)] {
        switch descriptor {
        case .enumeration(let enumerated):
            return enumerated.compactMap { bytes in
                let value = ByteCoding.readUInt16LE(bytes, at: 0)
                guard
                    let cells = WhiteBalanceTint.cells(fromPropertyValue: value)
                else { return nil }
                return (
                    WhiteBalanceTint.label(
                        amberBlueCell: cells.amberBlue,
                        greenMagentaCell: cells.greenMagenta),
                    cells.amberBlue,
                    cells.greenMagenta
                )
            }
        case .range(let minimumBytes, let maximumBytes, let stepBytes):
            let minimum = ByteCoding.readUInt16LE(minimumBytes, at: 0)
            let maximum = ByteCoding.readUInt16LE(maximumBytes, at: 0)
            let step = ByteCoding.readUInt16LE(stepBytes, at: 0)
            guard minimum <= maximum, step > 0 else { return [] }
            return whiteBalanceTintGrid.filter { mode in
                let value = WhiteBalanceTint.propertyValue(
                    amberBlueCell: mode.amberBlue,
                    greenMagentaCell: mode.greenMagenta)
                return value >= minimum && value <= maximum
                    && (value - minimum).isMultiple(of: step)
            }
        }
    }

    /// Packages the accumulated snapshot without allowing a transient failed
    /// read to erase useful last-known camera state.
    private func androidPropertyReadback(
        result: AndroidCameraPropertyRefreshResult
    ) -> AndroidCameraPropertyReadback {
        AndroidCameraPropertyReadback(
            result: result,
            properties: androidPropertySnapshot,
            storage: androidStorageInfo,
            storageSlots: androidStorageSlots,
            controls: androidControlCatalog.capabilities(
                properties: androidPropertySnapshot,
                whiteBalanceTint: androidWhiteBalanceTint,
                isScreenSizeReadbackCurrent: androidScreenSizeReadbackIsCurrent,
                usesNikonZRFallbacks: usesNikonZRFallbacks)
        )
    }

    /// Preserves the most useful non-terminal reason while a bootstrap carries
    /// on to other supported fields. A transport failure stops that burst.
    private func mergedAndroidPropertyRefreshResult(
        _ lhs: AndroidCameraPropertyRefreshResult,
        _ rhs: AndroidCameraPropertyRefreshResult
    ) -> AndroidCameraPropertyRefreshResult {
        if lhs == .transportFailed || rhs == .transportFailed { return .transportFailed }
        if lhs == .mediaBusy || rhs == .mediaBusy { return .mediaBusy }
        if lhs == .unsupported || rhs == .unsupported { return .unsupported }
        return .accepted
    }

    /// Android keeps codec immediately before its codec-dependent frame-size value so a missed
    /// property event cannot publish a new D0A0 value with the prior codec's picker domain.
    /// Photo mode uses the portable stills poll set (selector already high-priority interleaved).
    static func androidMonitorPollOrder(
        isRecording: Bool,
        captureSelector: CameraCaptureSelector? = nil
    ) -> [PTPPropertyCode] {
        if isRecording { return PTPPropertyCode.recordingMonitorPollOrder }
        if StillCapturePolicy.prefersPhotographyChrome(selector: captureSelector) {
            return StillCapturePolicy.photoMonitorPollOrder
        }
        return androidLiveMonitorPollOrder
    }

    /// Full live-monitor property set used for both the post-connect bootstrap
    /// burst and the steady-state round-robin. Each entry is still one PTP
    /// transaction; bootstrap just issues them back-to-back without the 1.5 s gap.
    private static let androidLiveMonitorPollOrder: [PTPPropertyCode] = {
        var pollOrder = PTPPropertyCode.liveMonitorPollOrder
        guard
            let screenSizeIndex = pollOrder.firstIndex(of: .movieRecordScreenSize),
            let fileTypeIndex = pollOrder.firstIndex(of: .movieFileType)
        else {
            return pollOrder
        }
        let fileType = pollOrder.remove(at: fileTypeIndex)
        pollOrder.insert(fileType, at: screenSizeIndex)
        return pollOrder
    }()

    // MARK: - Recording

    /// Starts movie recording to the camera card with Nikon's
    /// `StartMovieRecInCard` operation.
    ///
    /// The transaction executor serializes this with live-view frame reads,
    /// so the command runs at a safe protocol boundary rather than racing a
    /// `GetLiveViewImageEx` read on the shared command socket.
    public func startRecording() throws {
        try performRecordingCommand(.startMovieRecInCard)
    }

    /// Stops movie recording with Nikon's `EndMovieRec` operation.
    public func stopRecording() throws {
        try performRecordingCommand(.endMovieRec)
    }

    private func performRecordingCommand(_ operation: PTPOperationCode) throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }
        try transactExpectingOK(operation)
    }

    // MARK: - Still capture (photography mode)

    /// Fires a still release with the media-destination capture op (AF-then-release to
    /// the card). Activation-style: the OK response confirms the release started; poll
    /// ``pollStillReleaseReadiness()`` between frames for completion.
    public func initiateStillCapture() throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }
        try transactExpectingOK(
            .initiateCaptureRecInMedia, parameters: [0xFFFF_FFFE, 0x0000])
    }

    /// One `DeviceReady` poll after a still release.
    public func pollStillReleaseReadiness() throws -> StillReleaseReadiness {
        let result = try executeTransaction(.deviceReady)
        return StillCapturePolicy.releaseReadiness(result.operationResponse.responseCode)
    }

    /// Ends a bulb/time exposure or stops a running burst; frames captured so far are kept.
    public func terminateStillCapture() throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }
        try transactExpectingOK(.terminateCapture, parameters: [0, 0])
    }

    // MARK: - Android live-view configuration

    /// Applies one shared-policy preview request before the next live-view start.
    ///
    /// The two Nikon properties control only the monitor JPEG stream. They are
    /// deliberately configured through the same `SetDevicePropValueEx` path
    /// as the iOS shell, and the frame interval only changes Android's
    /// `GetLiveViewImageEx` pull cadence. No recording property is read or
    /// written here.
    @discardableResult
    public func configureLiveView(
        imageSize: UInt8,
        compression: UInt8,
        frameIntervalNanoseconds: UInt64
    ) -> Bool {
        guard
            (1...3).contains(imageSize),
            (1...3).contains(compression),
            // Match recording-rate cadences (e.g. 25p → 40 ms, 50p → 20 ms) while
            // still rejecting pathological intervals outside the supported envelope.
            frameIntervalNanoseconds >= Self.minimumLiveViewFrameIntervalNanoseconds,
            frameIntervalNanoseconds <= Self.maximumLiveViewFrameIntervalNanoseconds
        else { return false }

        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else { return false }

        liveViewCondition.lock()
        guard !liveViewPumpActive else {
            liveViewCondition.unlock()
            return false
        }
        configuredLiveViewFrameIntervalNanoseconds = frameIntervalNanoseconds
        liveViewCondition.unlock()

        let sizeApplied = setLiveViewByte(.liveViewImageSize, value: imageSize)
        let compressionApplied = setLiveViewByte(.liveViewImageCompression, value: compression)
        return sizeApplied && compressionApplied
    }

    /// Mirrors iOS's best-effort preview property write. A body may reject an
    /// unverified compression enum, but the monitor still attempts to start
    /// with the latest safe request instead of mutating a recording setting.
    private func setLiveViewByte(_ property: PTPPropertyCode, value: UInt8) -> Bool {
        do {
            try transactExpectingOK(
                .setDevicePropValueEx,
                parameters: [property.rawValue],
                dataPhase: .dataOut,
                dataOut: Data([value]))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Camera controls

    /// Source-compatible entry for the portable shared-core control model.
    public func applyControl(_ control: PTPCameraControl, label: String) throws {
        guard let androidControl = AndroidCameraControl(control) else {
            throw PTPIPClientSessionError.operationRejected(
                .setDevicePropValue, .unknown)
        }
        try applyAndroidControl(androidControl, label: label)
    }

    /// Applies one semantic Android selection using either the shared core's
    /// established label encoder or an exact camera-advertised descriptor value.
    /// The write is not reported as accepted until bounded authoritative
    /// property readback matches every payload.
    func applyAndroidControl(_ control: AndroidCameraControl, label: String) throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }

        let writes = androidControlWrites(control, label: label)
        guard !writes.isEmpty else {
            throw PTPIPClientSessionError.unsupportedAndroidControl(
                String(describing: control), label)
        }
        for write in writes {
            try writeCameraProperty(write)
        }
        try confirmAndroidControlWrites(writes, control: control, label: label)
        if control == .shutterMode {
            // The ZR exposes the full value enum only for the active shutter
            // circuit. Re-describe it immediately after the confirmed switch.
            switch androidPropertySnapshot.shutterMode {
            case .angle: try? refreshAndroidShutterAngleDescriptor()
            case .speed: try? refreshAndroidShutterSpeedDescriptor()
            case nil: break
            }
        } else if control == .whiteBalance {
            // The selected preset chooses a different tune property. Rebuild
            // that capability now or fail closed until the next descriptor pass.
            try? refreshAndroidWhiteBalanceTintDescriptor()
        } else if control == .codec {
            _ = refreshAndroidScreenSizeAfterCodecChange()
        }
    }

    /// Rebuilds the codec-dependent `MovScreenSize` domain immediately after a confirmed codec
    /// write, a camera-originated property event, or a newly observed normal-poll transition.
    /// Retaining the previous descriptor would let Android show and write combinations the newly
    /// selected codec does not advertise. A failed refresh clears this one domain and withholds
    /// the active selection until a valid D0A0 readback arrives, so the UI fails closed rather
    /// than reusing stale modes.
    private func refreshAndroidScreenSizeAfterCodecChange() -> AndroidCameraPropertyRefreshResult {
        androidScreenSizeReadbackIsCurrent = false
        do {
            try refreshAndroidScreenSizeDescriptor()
        } catch let error as PTPIPClientSessionError {
            return androidDescriptorResult(for: error)
        } catch {
            return .transportFailed
        }
        // A codec transition can make the camera choose a compatible screen size itself. Refresh
        // the active raw value too, so the current label and picker selection stay in sync.
        return refreshAndroidProperty(.movieRecordScreenSize)
    }

    private func androidControlWrites(
        _ control: AndroidCameraControl,
        label: String
    ) -> [PTPCameraPropertyWrite] {
        // When the body has advertised a non-empty write domain, refuse labels outside it
        // (keeps dual-base ISO circuits, RAW e-VR suppression, etc. honest). An *empty*
        // domain used to reject every label via `contains` — that broke capture-bar and
        // top-bar pickers that open on iOS policy ladders before descriptors land, and
        // after a failed/incomplete catalog refresh. Empty domains either fall through to
        // shared-core label encoding (iOS parity) or stay fail-closed for raw-only writes.
        let capabilityOptions = currentAndroidCapabilityOptions(for: control)
        if control.requiresCapabilityValidation {
            if capabilityOptions.isEmpty {
                if !control.allowsEncodeWithoutCapabilityDomain {
                    return []
                }
            } else if !capabilityOptions.contains(label)
                && !Self.capabilityOptionsContainRecordingLabel(capabilityOptions, label: label)
            {
                // Kelvin long-press fine-adjust (±10) lands off the dial ladder
                // (e.g. 5570K) only when the body already offers a Kelvin domain
                // (Color temp mode). Never invent Kelvin when only presets are advertised.
                let kelvinDomainOpen =
                    capabilityOptions.contains(where: WhiteBalanceKelvinPolicy.isKelvinLabel)
                    || androidControlCatalog.whiteBalanceModes.contains {
                        $0.label == "Color temp"
                    }
                    || androidControlCatalog.stillWhiteBalanceModes.contains {
                        $0.label == "Color temp"
                    }
                let isFineKelvin =
                    control == .whiteBalance
                    && WhiteBalanceKelvinPolicy.isKelvinLabel(label)
                    && kelvinDomainOpen
                // iOS always encodes MovieTVLock Locked/Unlocked without requiring both
                // values in the live enum (the body often only advertises the active state).
                let isShutterLockToggle =
                    control == .shutterLock && (label == "Locked" || label == "Unlocked")
                // Movie ISO: the capability list is a UI ladder (dual-base circuit / unified
                // steps). Auto can park outside it (e.g. 51200) and the body still accepts
                // MovieExposureIndex / MovieISOSensitivity. Rejecting here flashes a false
                // "not supported" after Auto Off (or a dual-write) already moved the body.
                // Any numeric label the shared core can encode is allowed; the body remains
                // the authority if a value is truly out of range.
                let isEncodableISO =
                    control == .iso
                    && PTPCameraPropertyWrite.isoWrite(label: label, dualBase: false) != nil
                if !isFineKelvin, !isShutterLockToggle, !isEncodableISO {
                    return []
                }
            }
        }
        switch control {
        case .iso, .isoAuto, .focusMode:
            return sharedControlWrites(control, label: label)
        case .shutter:
            if let write = shutterDescriptorWrite(label: label) {
                return [write]
            }
            // Prefer the active circuit's advertised raw when present; otherwise encode the
            // angle/speed label the same way the iOS shell does.
            return sharedControlWrites(control, label: label)
        case .iris:
            if let raw = androidControlCatalog.apertures.first(where: { $0.label == label })?.raw {
                return [
                    PTPCameraPropertyWrite(
                        property: .movieFNumber, data: Data(ByteCoding.uint16LE(raw)))
                ]
            }
            // Empty/omitted enum on ZR (allowsApertureFallback) can use shared-core
            // encoding. A completed catalog with no domain and no fallback stays closed.
            if androidControlCatalog.isComplete,
                androidControlCatalog.apertures.isEmpty,
                !androidControlCatalog.allowsApertureFallback
            {
                return []
            }
            return sharedControlWrites(control, label: label)
        case .whiteBalance:
            // Photography reuses the movie WB picker; the shared core routes the write to the
            // stills WB property family by the snapshot's selector. Prefer the photo descriptor's
            // exact preset raws when the body advertised them. [verify-on-HW]
            if StillCapturePolicy.prefersPhotographyChrome(
                selector: androidPropertySnapshot.captureSelector)
            {
                if let raw = androidControlCatalog.stillWhiteBalanceModes.first(where: {
                    $0.label == label
                })?.raw {
                    return [
                        PTPCameraPropertyWrite(
                            property: .whiteBalance, data: Data(ByteCoding.uint16LE(raw)))
                    ]
                }
                return sharedControlWrites(control, label: label)
            }
            let descriptorWrites = whiteBalanceDescriptorWrites(label: label)
            if !descriptorWrites.isEmpty { return descriptorWrites }
            return sharedControlWrites(control, label: label)
        case .focusArea:
            let writes = uint16DescriptorWrite(
                label: label,
                modes: androidControlCatalog.focusAreas,
                property: .movieFocusMeteringMode)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .focusSubject:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.focusSubjects,
                property: .movieAFSubjectDetection)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .audioSensitivity:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.audioSensitivities,
                property: .movieAudioInputSensitivity)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .audioInput:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.audioInputs,
                property: .audioInputSelection)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .windFilter:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.windFilters,
                property: .movWindNoiseReduction)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .attenuator:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.attenuators,
                property: .movieAttenuator)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .audio32BitFloat:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.audio32BitFloat,
                property: .movie32BitFloatAudioRecording)
            return writes.isEmpty ? sharedControlWrites(control, label: label) : writes
        case .baseISO:
            guard let codec = androidPropertySnapshot.fileType,
                ISOPickerPolicy.showsDualBaseCircuits(codec: codec)
            else { return [] }
            let modes =
                if !androidControlCatalog.baseISO.isEmpty {
                    androidControlCatalog.baseISO
                } else if usesNikonZRFallbacks {
                    AndroidNikonZRControlFallback.baseISO
                } else {
                    [] as [AndroidRawControlMode<UInt8>]
                }
            return uint8DescriptorWrite(
                label: label,
                modes: modes,
                property: .movieBaseISO)
        case .shutterMode:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.shutterModes,
                property: .movieShutterMode)
            if !writes.isEmpty { return writes }
            // Known Angle/Speed labels without a descriptor yet (iOS always encodes).
            guard let mode = shutterDisplayMode(label: label) else { return [] }
            return [PTPCameraPropertyWrite.shutterMode(mode)]
        case .shutterLock:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.shutterLocks,
                property: .movieTVLockSetting)
            if !writes.isEmpty { return writes }
            switch label {
            case "Locked": return [PTPCameraPropertyWrite.movieTVLock(unlocked: false)]
            case "Unlocked": return [PTPCameraPropertyWrite.movieTVLock(unlocked: true)]
            default: return []
            }
        case .whiteBalanceTint:
            return whiteBalanceTintWrite(label: label).map { [$0] } ?? []
        case .resolutionFrameRate:
            // iOS baseline: exact camera-advertised pack for the picked label only.
            return androidControlCatalog.screenSizeMode(
                for: label,
                properties: androidPropertySnapshot,
                usesNikonZRFallbacks: usesNikonZRFallbacks
            )
            .map { [PTPCameraPropertyWrite.screenSize(raw: $0.raw)] } ?? []
        case .codec:
            if let mode = androidControlCatalog.fileTypes.first(where: { $0.label == label }) {
                return [PTPCameraPropertyWrite.fileType(raw: mode.raw)]
            }
            // Accept long camera strings ("R3D NE 12-bit R3D") against short labels.
            let short = MonitorTextFormat.codecShortLabel(label)
            return androidControlCatalog.fileTypes.first(where: {
                $0.label == short || MonitorTextFormat.codecShortLabel($0.label) == short
            })
            .map { [PTPCameraPropertyWrite.fileType(raw: $0.raw)] } ?? []
        case .vibrationReduction:
            let writes = uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.vibrationReduction,
                property: .movieVibrationReduction)
            if !writes.isEmpty { return writes }
            return PTPCameraPropertyWrite.vibrationReduction(label: label).map { [$0] } ?? []
        case .electronicVR:
            return uint8DescriptorWrite(
                label: label,
                modes: androidControlCatalog.electronicVR,
                property: .electronicVR)
        case .exposureMode:
            return sharedControlWrites(control, label: label)
        case .stillShutter:
            // Prefer the exact camera-advertised raw for the label (the stills
            // enum narrows by program/flash state); shared fraction-packing
            // covers the ladder fallback.
            if let raw = androidControlCatalog.stillShutterSpeeds.first(where: {
                $0.label == label
            })?.raw {
                return [
                    PTPCameraPropertyWrite(
                        property: .stillShutterSpeed, data: Data(ByteCoding.uint32LE(raw)))
                ]
            }
            return sharedControlWrites(control, label: label)
        case .stillISOAuto:
            // Stills Auto ISO toggle — iOS's raw one-byte property write.
            switch label {
            case "On", "ON":
                return [
                    PTPCameraPropertyWrite(property: .stillISOAutoControl, data: Data([1]))
                ]
            case "Off", "OFF":
                return [
                    PTPCameraPropertyWrite(property: .stillISOAutoControl, data: Data([0]))
                ]
            default:
                return []
            }
        case .stillImageArea:
            // Photo sensor crop — the raw area byte, exactly like iOS's
            // `setStillImageArea` safe-point write.
            guard let area = StillImageArea.area(forLabel: label) else { return [] }
            return [
                PTPCameraPropertyWrite(property: .captureAreaCrop, data: Data([area.rawValue]))
            ]
        case .stillISO, .stillIris, .stillDrive, .stillFocusMode, .stillFocusArea,
            .stillFocusSubject, .stillMeter, .stillImageSize, .stillQuality,
            .stillRawCompression, .stillUserModeProgram, .stillPictureControl:
            // Stills writes ride the shared-core label encoders (the same
            // byte policy iOS queues); the body stays the final authority.
            return sharedControlWrites(control, label: label)
        }
    }

    /// Label → shared-core property write(s). Used for iOS-parity encode when the Android
    /// descriptor catalog has not yet advertised an exact raw value for the selection.
    private func sharedControlWrites(
        _ control: AndroidCameraControl,
        label: String
    ) -> [PTPCameraPropertyWrite] {
        guard let sharedControl = control.sharedControl else { return [] }
        return PTPCameraPropertyWrite.requests(
            control: sharedControl,
            label: label,
            snapshot: androidPropertySnapshot)
    }

    private func shutterDisplayMode(label: String) -> ShutterDisplayMode? {
        switch label {
        case "Angle": .angle
        case "Speed": .speed
        default: nil
        }
    }

    /// Strips ZR crop prefixes and normalizes middle-dot spacing for mode matching.
    fileprivate static func bareRecordingModeLabel(_ label: String) -> String {
        NikonZRRawCropPresentation.bareLabel(label)
    }

    /// True when `label` matches a capability option exactly or as a bare recording-mode form
    /// (`6K · 25p` ↔ `[FX] 6K · 25p`). Used so top-bar REC writes are not rejected by the
    /// exact-string capability gate before the raw screen-size match runs.
    fileprivate static func capabilityOptionsContainRecordingLabel(
        _ options: [String],
        label: String
    ) -> Bool {
        let bare = bareRecordingModeLabel(label)
        guard !bare.isEmpty else { return false }
        return options.contains { bareRecordingModeLabel($0) == bare }
    }

    private func currentAndroidCapabilityOptions(for control: AndroidCameraControl) -> [String] {
        let capabilities = androidControlCatalog.capabilities(
            properties: androidPropertySnapshot,
            whiteBalanceTint: androidWhiteBalanceTint,
            isScreenSizeReadbackCurrent: androidScreenSizeReadbackIsCurrent,
            usesNikonZRFallbacks: usesNikonZRFallbacks)
        return switch control {
        case .iso: capabilities.isoValues
        case .isoAuto: ["ON", "OFF"]
        case .shutter: capabilities.shutterValues
        case .iris: capabilities.irisValues
        case .whiteBalance: capabilities.whiteBalanceValues
        case .focusMode: capabilities.focusModes
        case .focusArea: capabilities.focusAreas
        case .focusSubject: capabilities.focusSubjects
        case .audioSensitivity: capabilities.audioSensitivities
        case .audioInput: capabilities.audioInputs
        case .windFilter: capabilities.windFilters
        case .attenuator: capabilities.attenuators
        case .audio32BitFloat: capabilities.audio32BitFloat
        case .baseISO: capabilities.baseISO
        case .shutterMode: capabilities.shutterModes
        case .shutterLock: capabilities.shutterLocks
        case .whiteBalanceTint: capabilities.whiteBalanceTints
        case .resolutionFrameRate: capabilities.resolutionFrameRates
        case .codec: capabilities.codecs
        case .vibrationReduction: capabilities.vibrationReduction
        case .electronicVR: capabilities.electronicVR
        case .exposureMode: []
        case .stillISO, .stillISOAuto, .stillShutter, .stillIris, .stillDrive,
            .stillFocusMode, .stillFocusArea, .stillFocusSubject, .stillMeter,
            .stillImageArea, .stillImageSize, .stillQuality, .stillRawCompression,
            .stillUserModeProgram, .stillPictureControl:
            // Stills controls skip capability validation (`isStillControl`).
            []
        }
    }

    private func shutterDescriptorWrite(label: String) -> PTPCameraPropertyWrite? {
        let property: PTPPropertyCode
        let modes: [AndroidRawControlMode<UInt32>]
        switch androidPropertySnapshot.shutterMode {
        case .angle:
            property = .movieShutterAngle
            modes = androidControlCatalog.shutterAngles
        case .speed:
            property = .movieShutterSpeed
            modes = androidControlCatalog.shutterSpeeds
        case nil:
            return nil
        }
        guard let raw = modes.first(where: { $0.label == label })?.raw else { return nil }
        return PTPCameraPropertyWrite(property: property, data: Data(ByteCoding.uint32LE(raw)))
    }

    private func uint8DescriptorWrite(
        label: String,
        modes: [AndroidRawControlMode<UInt8>],
        property: PTPPropertyCode
    ) -> [PTPCameraPropertyWrite] {
        guard let raw = modes.first(where: { $0.label == label })?.raw else { return [] }
        return [PTPCameraPropertyWrite(property: property, data: Data([raw]))]
    }

    private func uint16DescriptorWrite(
        label: String,
        modes: [AndroidRawControlMode<UInt16>],
        property: PTPPropertyCode
    ) -> [PTPCameraPropertyWrite] {
        guard let raw = modes.first(where: { $0.label == label })?.raw else { return [] }
        return [
            PTPCameraPropertyWrite(property: property, data: Data(ByteCoding.uint16LE(raw)))
        ]
    }

    private func whiteBalanceDescriptorWrites(label: String) -> [PTPCameraPropertyWrite] {
        // Accept any Kelvin in the documented 2500–10000 range (dial steps *and*
        // long-press ±10 fine-adjust values such as 5570K that are not on the
        // discrete dial ladder). Catalog membership alone would reject fine-tune.
        if let kelvin = WhiteBalanceKelvinPolicy.kelvin(from: label),
            let mode = androidControlCatalog.whiteBalanceModes.first(where: {
                $0.label == "Color temp"
            })?.raw
        {
            return [
                PTPCameraPropertyWrite(
                    property: .movieWhiteBalance, data: Data(ByteCoding.uint16LE(mode))),
                PTPCameraPropertyWrite(
                    property: .movieWBColorTemp,
                    data: Data(ByteCoding.uint16LE(UInt16(kelvin)))),
            ]
        }
        return uint16DescriptorWrite(
            label: label,
            modes: androidControlCatalog.whiteBalanceModes,
            property: .movieWhiteBalance)
    }

    private func whiteBalanceTintWrite(label: String) -> PTPCameraPropertyWrite? {
        guard let mode = androidPropertySnapshot.wbMode,
            let tint = androidControlCatalog.whiteBalanceTints.first(where: { $0.label == label })
        else { return nil }
        return WhiteBalanceTint.write(
            wbModeLabel: mode,
            amberBlueCell: tint.amberBlue,
            greenMagentaCell: tint.greenMagenta,
            // Photo mode writes the stills tune property for the active WB mode.
            photography: StillCapturePolicy.prefersPhotographyChrome(
                selector: androidPropertySnapshot.captureSelector))
    }

    private func confirmAndroidControlWrites(
        _ writes: [PTPCameraPropertyWrite],
        control: AndroidCameraControl,
        label: String,
        maxAttempts: Int? = nil
    ) throws {
        // Focus-family writes settle slower under live view (body often mirrors
        // after a few frames). Keep other drums snappy (6 × 40 ms).
        let isFocusFamily =
            control == .focusMode || control == .focusArea || control == .focusSubject
        let attempts = maxAttempts ?? (isFocusFamily ? 12 : 6)
        let sleepSeconds = isFocusFamily ? 0.08 : 0.04
        for attempt in 1...attempts {
            var allMatch = true
            for write in writes {
                let readback = try readProperty(write.property)
                androidPropertySnapshot = androidPropertySnapshot.applying(
                    property: write.property, data: readback)
                if !Self.propertyWriteMatchesReadback(write: write, readback: readback) {
                    allMatch = false
                }
            }
            if allMatch {
                if control == .whiteBalanceTint { androidWhiteBalanceTint = label }
                return
            }
            if attempt < attempts { Thread.sleep(forTimeInterval: sleepSeconds) }
        }
        throw PTPIPClientSessionError.controlReadbackMismatch(
            String(describing: control), label)
    }

    /// True when a property write is confirmed by readback.
    /// - `MovScreenSize`: decoded width/height/fps (camera may rewrite low packing bits).
    /// - `MovieFocusMode`: decoded label (MF raw 3 lens-ring and 4 menu are equivalent).
    /// - Movie ISO family: UINT32 value (payload may be padded beyond 4 bytes).
    /// - Other properties: byte-exact.
    static func propertyWriteMatchesReadback(
        write: PTPCameraPropertyWrite,
        readback: Data
    ) -> Bool {
        if write.property == .movieRecordScreenSize,
            write.data.count >= 8,
            readback.count >= 8
        {
            let written = ByteCoding.readUInt64LE([UInt8](write.data), at: 0)
            let live = ByteCoding.readUInt64LE([UInt8](readback), at: 0)
            let w = PTPCameraPropertyDecoders.screenSize(written)
            let r = PTPCameraPropertyDecoders.screenSize(live)
            return w.width == r.width && w.height == r.height && w.fps == r.fps
        }
        if write.property == .movieFocusMode,
            let written = write.data.first,
            let live = readback.first
        {
            // Label match: MF (3/4) and AF labels compare as decoded strings.
            return PTPCameraPropertyDecoders.movieFocusMode(written)
                == PTPCameraPropertyDecoders.movieFocusMode(live)
        }
        // Effective / dual-base / exposure-index / stills ISO — compare the UINT32, not raw length.
        if write.property == .movieExposureIndex
            || write.property == .movieISOSensitivity
            || write.property == .isoControlSensitivity
            || write.property == .exposureIndexEx,
            write.data.count >= 4,
            readback.count >= 4
        {
            let written = ByteCoding.readUInt32LE([UInt8](write.data), at: 0)
            let live = ByteCoding.readUInt32LE([UInt8](readback), at: 0)
            return written == live
        }
        return readback == write.data
    }

    /// Writes one shared-core-encoded camera property using the operation the
    /// Nikon body expects for that property width. Standard 16-bit `0xDxxx`
    /// properties must use `SetDevicePropValue` (0x1016); only 32-bit extended
    /// `0x0001_Dxxx` properties use Nikon's `SetDevicePropValueEx` (0x943C).
    private func writeCameraProperty(_ write: PTPCameraPropertyWrite) throws {
        let operation: PTPOperationCode =
            write.property.rawValue <= UInt32(UInt16.max)
            ? .setDevicePropValue
            : .setDevicePropValueEx
        try transactExpectingOK(
            operation,
            parameters: [write.property.rawValue],
            dataPhase: .dataOut,
            dataOut: write.data)
    }

    // MARK: - Autofocus area

    /// Moves the live-view AF area through Nikon `ChangeAfArea` while keeping
    /// coordinates semantic at the JNI boundary. The operation carries exactly
    /// two UINT32 parameters and no host-to-camera payload.
    public func changeAfArea(x: UInt32, y: UInt32) throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }
        try changeAfAreaTransaction(x: x, y: y)
    }

    /// Recentres the AF area using only current camera-owned focus dimensions,
    /// live-view tracking state, and freshly read focus properties.
    ///
    /// Subject-tracking release mirrors the iOS sequence and shared policies:
    /// release, optionally suspend/demote, wait 3...15 new headers, recenter,
    /// release again, then restore only unchanged interim settings. It never
    /// sends `StartTracking`.
    public func resetFocusPoint() throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }
        guard liveViewIsActive(), let initialFrame = authoritativeFocusFrame(),
            let initialFocus = initialFrame.focus,
            initialFocus.coordinateWidth > 0, initialFocus.coordinateHeight > 0,
            !initialFocus.boxes.isEmpty
        else {
            throw PTPIPClientSessionError.focusStateUnavailable
        }

        let savedProperties = try refreshAuthoritativeFocusProperties()
        guard let savedFocusMode = savedProperties.focusMode,
            let savedFocusArea = savedProperties.focusArea,
            let savedFocusSubject = savedProperties.focusSubject,
            PTPCameraPropertyDecoders.movieFocusModeCode(for: savedFocusMode) != nil,
            PTPCameraPropertyDecoders.movieFocusAreaCode(for: savedFocusArea) != nil,
            PTPCameraPropertyDecoders.movieAFSubjectCode(for: savedFocusSubject) != nil
        else {
            throw PTPIPClientSessionError.focusStateUnavailable
        }
        let centerX = UInt32(initialFocus.coordinateWidth / 2)
        let centerY = UInt32(initialFocus.coordinateHeight / 2)
        let shouldRelease =
            FocusResetReleasePolicy.isTrackingIndicatedOnHeader(initialFocus)
            || initialFocus.subjectDetectionActive
            || initialFocus.selectedBoxIndex != nil
            || initialFocus.boxes.count > 1
            || savedFocusArea == "Subject"
            || savedFocusSubject != "Off"
            || savedFocusMode == "AF-F"

        guard shouldRelease else {
            try changeAfAreaTransaction(x: centerX, y: centerY)
            return
        }

        let shouldDemote = FocusResetReleasePolicy.shouldDemoteSubjectArea(
            focusArea: savedFocusArea, liveViewFocus: initialFocus)
        let shouldSuspend = FocusResetReleasePolicy.shouldSuspendSubjectDetection(
            focusSubject: savedFocusSubject, liveViewFocus: initialFocus)

        try transactExpectingOK(.endTracking)
        _ = try? waitForDeviceReady()
        _ = try? transactExpectingOK(.afDriveCancel)
        _ = try? waitForDeviceReady()

        var suspended = false
        if shouldSuspend {
            if (try? applyFocusProperty(
                .focusSubject,
                label: FocusResetRestorePolicy.interimFocusSubject)) != nil
            {
                suspended = true
            }
            _ = try? waitForDeviceReady()
        }
        var demoted = false
        if shouldDemote {
            if (try? applyFocusProperty(
                .focusArea,
                label: FocusResetRestorePolicy.interimFocusArea)) != nil
            {
                demoted = true
            }
            _ = try? waitForDeviceReady()
        }

        guard let releaseFrame = authoritativeFocusFrame() else {
            throw PTPIPClientSessionError.focusStateUnavailable
        }
        _ = try waitForTrackingRelease(
            after: releaseFrame.generation,
            coordinateWidth: initialFocus.coordinateWidth,
            coordinateHeight: initialFocus.coordinateHeight)
        try changeAfAreaTransaction(x: centerX, y: centerY)
        _ = try? waitForDeviceReady()

        // ChangeAfArea can re-latch target tracking on ZR hardware. Repeat the
        // release pair before any guarded mode restoration.
        _ = try? transactExpectingOK(.endTracking)
        _ = try? transactExpectingOK(.afDriveCancel)
        _ = try? waitForDeviceReady()

        let currentProperties = try refreshAuthoritativeFocusProperties()
        let currentMode = currentProperties.focusMode
        if let currentArea = currentProperties.focusArea,
            FocusResetRestorePolicy.shouldRestoreFocusArea(
                demoted: demoted,
                currentFocusArea: currentArea,
                savedFocusArea: savedFocusArea,
                focusMode: currentMode)
        {
            _ = try? applyFocusProperty(.focusArea, label: savedFocusArea)
            _ = try? waitForDeviceReady()
        }

        let propertiesAfterAreaRestore = try refreshAuthoritativeFocusProperties()
        if let currentSubject = propertiesAfterAreaRestore.focusSubject,
            FocusResetRestorePolicy.shouldRestoreSubjectDetection(
                suspended: suspended,
                currentFocusSubject: currentSubject,
                savedFocusSubject: savedFocusSubject,
                focusMode: propertiesAfterAreaRestore.focusMode)
        {
            _ = try? applyFocusProperty(.focusSubject, label: savedFocusSubject)
            _ = try? waitForDeviceReady()
        }
    }

    private struct AuthoritativeFocusFrame {
        let focus: PTPLiveViewFocusInfo?
        let generation: UInt64
    }

    private func changeAfAreaTransaction(x: UInt32, y: UInt32) throws {
        try transactExpectingOK(
            .changeAfArea,
            parameters: [x, y],
            dataPhase: .noDataOrDataIn,
            dataOut: nil)
    }

    private func applyFocusProperty(_ control: PTPCameraControl, label: String) throws {
        guard let write = PTPCameraPropertyWrite.request(control: control, label: label) else {
            throw PTPIPClientSessionError.unsupportedControl(control, label)
        }
        try writeCameraProperty(write)
        androidPropertySnapshot = androidPropertySnapshot.applying(
            property: write.property, data: write.data)
    }

    /// Re-reads every reset-sensitive setting so restoration never uses a UI
    /// default or an old polling label.
    private func refreshAuthoritativeFocusProperties() throws -> PTPCameraPropertySnapshot {
        var focusSnapshot = PTPCameraPropertySnapshot()
        var updatedAndroidSnapshot = androidPropertySnapshot
        for property in [
            PTPPropertyCode.movieFocusMode,
            .movieFocusMeteringMode,
            .movieAFSubjectDetection,
        ] {
            let data: Data
            do {
                data = try readProperty(property)
            } catch let error as PTPIPClientSessionError {
                switch error {
                case .operationRejected, .unsupportedProperty:
                    throw PTPIPClientSessionError.focusStateUnavailable
                default:
                    throw error
                }
            }
            focusSnapshot = focusSnapshot.applying(property: property, data: data)
            updatedAndroidSnapshot = updatedAndroidSnapshot.applying(
                property: property, data: data)
        }
        guard focusSnapshot.focusMode != nil,
            focusSnapshot.focusArea != nil,
            focusSnapshot.focusSubject != nil
        else {
            throw PTPIPClientSessionError.focusStateUnavailable
        }
        androidPropertySnapshot = updatedAndroidSnapshot
        return focusSnapshot
    }

    private func liveViewIsActive() -> Bool {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        return liveViewPumpActive && !liveViewStopRequested
    }

    private func authoritativeFocusFrame() -> AuthoritativeFocusFrame? {
        focusFrameCondition.lock()
        defer { focusFrameCondition.unlock() }
        guard focusFrameGeneration > 0 else { return nil }
        return AuthoritativeFocusFrame(
            focus: latestLiveViewFocus, generation: focusFrameGeneration)
    }

    private func waitForTrackingRelease(
        after initialGeneration: UInt64,
        coordinateWidth: Int,
        coordinateHeight: Int
    ) throws -> AuthoritativeFocusFrame {
        var generation = initialGeneration
        var framesSinceRelease = 0
        let deadline = Date().addingTimeInterval(commandTransactionTimeout + 2)

        while framesSinceRelease < FocusResetSettlePolicy.maximumWaitFrames {
            focusFrameCondition.lock()
            while focusFrameGeneration <= generation && liveViewIsActive() {
                guard focusFrameCondition.wait(until: deadline) else {
                    focusFrameCondition.unlock()
                    throw PTPIPClientSessionError.focusStateUnavailable
                }
            }
            let next = AuthoritativeFocusFrame(
                focus: latestLiveViewFocus, generation: focusFrameGeneration)
            focusFrameCondition.unlock()

            guard liveViewIsActive(), next.generation > generation else {
                throw PTPIPClientSessionError.focusStateUnavailable
            }
            framesSinceRelease += Int(next.generation - generation)
            generation = next.generation
            if let focus = next.focus {
                guard focus.coordinateWidth == coordinateWidth,
                    focus.coordinateHeight == coordinateHeight
                else {
                    throw PTPIPClientSessionError.focusStateUnavailable
                }
            }
            // The iOS shell counts every new header after release. A missing focus object or an
            // empty box list is authoritative evidence that the prior tracked target is gone, not
            // a reason to resurrect the pre-release box requirement.
            let focusBoxStillPresent = next.focus?.boxes.isEmpty == false
            if FocusResetSettlePolicy.shouldRecenter(
                framesSinceRelease: framesSinceRelease,
                isTrackingLatched:
                    focusBoxStillPresent && (next.focus?.isSubjectTrackingLatched ?? false),
                trackingAFActive:
                    focusBoxStillPresent && (next.focus?.trackingAFActive ?? false))
            {
                return next
            }
        }
        throw PTPIPClientSessionError.focusStateUnavailable
    }

    // MARK: - Event channel

    /// Starts one bounded background reader for the PTP-IP event socket.
    ///
    /// The Nikon body pushes asynchronous notifications on this socket. If no
    /// reader drains it, the camera's send buffer can eventually stall an
    /// otherwise healthy session. Parsed events retain their raw code and
    /// parameters, so callers never have to guess the meaning of a vendor
    /// event that the shared core has not classified yet.
    ///
    /// Idle reads time out normally and keep draining. Any other transport
    /// failure ends only this event stream and is passed to [onEnded] as an
    /// operator-facing message. PTP-IP owns independent command and event
    /// sockets: a closed event socket does not by itself prove that the
    /// command or live-view channel has failed. Those paths retain their own
    /// health checks and stay available until they fail or the owner tears the
    /// session down. The callback is delivered at most once. A session owns
    /// one drain for its lifetime; disconnect closes the event socket and
    /// joins its reader before tearing down the command socket.
    public func startEventDrain(
        onEvent: @escaping @Sendable (PTPEvent) -> Void,
        onEnded: @escaping @Sendable (String?) -> Void
    ) throws {
        transactionLock.lock()
        let closed = isClosed
        transactionLock.unlock()
        guard !closed else { throw PTPIPClientSessionError.connectionClosed }

        eventDrainCondition.lock()
        guard !eventDrainActive else {
            eventDrainCondition.unlock()
            throw PTPIPClientSessionError.eventDrainAlreadyActive
        }
        eventDrainActive = true
        eventDrainStopRequested = false
        eventDrainCondition.unlock()

        Thread.detachNewThread { [self] in
            runEventDrain(onEvent: onEvent, onEnded: onEnded)
        }
    }

    /// Stops the event reader by closing its dedicated socket, then waits only
    /// until the reader observes that closure. This is intentionally private:
    /// an active PTP-IP session needs its event socket drained continuously.
    private func stopEventDrain() {
        eventDrainCondition.lock()
        guard eventDrainActive else {
            eventDrainCondition.unlock()
            return
        }
        eventDrainStopRequested = true
        eventDrainCondition.unlock()

        #if os(Android)
            if usbTransport == nil {
                // Closing the PTP-IP event descriptor interrupts a blocked
                // poll immediately. USB interrupt reads are independently
                // bounded to one second, so closing the whole claimed device
                // here would incorrectly tear down command traffic.
                event?.close()
            }
        #else
            // Closing the event descriptor interrupts a blocked poll
            // immediately; the bounded wait below is only a guard against a
            // platform-level wake race, not a normal ten-second socket timeout.
            event?.close()
        #endif

        eventDrainCondition.lock()
        let deadline = Date().addingTimeInterval(eventDrainStopTimeout + 2)
        while eventDrainActive {
            guard eventDrainCondition.wait(until: deadline) else { break }
        }
        eventDrainCondition.unlock()
    }

    private func runEventDrain(
        onEvent: @escaping @Sendable (PTPEvent) -> Void,
        onEnded: @escaping @Sendable (String?) -> Void
    ) {
        #if os(Android)
            if let usbTransport {
                runUSBEventDrain(
                    transport: usbTransport,
                    onEvent: onEvent,
                    onEnded: onEnded
                )
                return
            }
        #endif
        guard let event, command != nil else {
            finishEventDrain(
                onEnded: onEnded,
                failure: PTPIPClientSessionError.connectionClosed.localizedDescription
            )
            return
        }
        var failure: String?
        while !eventDrainStopIsRequested() {
            do {
                // Mirror the iOS transport: unexpected packets and malformed
                // event payloads are skipped, while valid-but-unknown event
                // codes still surface through PTPEvent.rawEventCode.
                let packet = try event.readPacket()
                guard let parsed = try? PTPEvent(from: packet) else { continue }
                onEvent(parsed)
            } catch let error as PTPIPClientSessionError {
                if case .timeout = error { continue }
                if !eventDrainStopIsRequested() {
                    failure = error.localizedDescription
                }
                break
            } catch {
                if !eventDrainStopIsRequested() {
                    failure = error.localizedDescription
                }
                break
            }
        }

        // The event reader is permanently finished for this socket. Release
        // its descriptor now while preserving the independent command link.
        if failure != nil { event.close() }
        finishEventDrain(onEnded: onEnded, failure: failure)
    }

    #if os(Android)
        /// USB PTP events arrive through the claimed interrupt endpoint. A
        /// short idle timeout is normal; any other failure closes the shared
        /// transport so Kotlin cannot continue presenting stale camera state.
        private func runUSBEventDrain(
            transport: AndroidUSBPTPTransport,
            onEvent: @escaping @Sendable (PTPEvent) -> Void,
            onEnded: @escaping @Sendable (String?) -> Void
        ) {
            var failure: String?
            while !eventDrainStopIsRequested() {
                do {
                    onEvent(try transport.nextEventSynchronously())
                } catch let error as AndroidUSBPTPTransportError {
                    if case .timeout = error { continue }
                    if !eventDrainStopIsRequested() {
                        failure = error.localizedDescription
                    }
                    break
                } catch {
                    if !eventDrainStopIsRequested() {
                        failure = error.localizedDescription
                    }
                    break
                }
            }

            if failure != nil {
                transport.close()
                transactionLock.lock()
                isClosed = true
                transactionLock.unlock()
            }
            finishEventDrain(onEnded: onEnded, failure: failure)
        }
    #endif

    /// Marks the single event reader inactive before calling Kotlin back: a
    /// listener may disconnect immediately, and must never wait for its own
    /// Swift-owned reader thread.
    private func finishEventDrain(
        onEnded: @escaping @Sendable (String?) -> Void,
        failure: String?
    ) {
        eventDrainCondition.lock()
        eventDrainActive = false
        eventDrainStopRequested = false
        eventDrainCondition.broadcast()
        eventDrainCondition.unlock()
        onEnded(failure)
    }

    private func eventDrainStopIsRequested() -> Bool {
        eventDrainCondition.lock()
        defer { eventDrainCondition.unlock() }
        return eventDrainStopRequested
    }

    private var eventDrainStopTimeout: TimeInterval {
        #if os(Android)
            if usbTransport != nil { return 1 }
        #endif
        return Double(event?.timeoutMilliseconds ?? 1_000) / 1_000
    }

    // MARK: - Media ownership and transfer

    /// Gives media playback or transfer exclusive ownership without performing
    /// browse-specific preparation.
    public func enterMediaMode() {
        _ = claimMediaMode(refreshStorage: false)
    }

    /// Refreshes card capacity and gives media browsing/playback exclusive
    /// ownership of the camera's serialized command channel.
    ///
    /// The storage refresh and ownership transition share
    /// `commandLifecycleLock`, so a property bootstrap cannot slip between
    /// them. This lets Android render authoritative cards even when Media is
    /// opened before the initial monitor bootstrap finishes. An already-active
    /// media visit keeps its captured storage snapshot while reserving a newer
    /// ownership generation, without issuing a redundant card refresh.
    func enterMediaModeForBrowse() -> AndroidMediaBrowsePreparation {
        claimMediaMode(refreshStorage: true)
    }

    private func claimMediaMode(refreshStorage: Bool) -> AndroidMediaBrowsePreparation {
        commandLifecycleLock.lock()
        liveViewCondition.lock()
        let wasAlreadyActive = mediaModeActive
        liveViewCondition.unlock()
        if refreshStorage, !wasAlreadyActive {
            _ = refreshAndroidStorage()
        }
        mediaModeOwnershipGeneration =
            mediaModeOwnershipGeneration == UInt64.max ? 1 : mediaModeOwnershipGeneration + 1
        liveViewCondition.lock()
        mediaModeActive = true
        liveViewCondition.unlock()
        let preparation = AndroidMediaBrowsePreparation(
            readback: androidPropertyReadback(result: .mediaBusy),
            ownershipGeneration: mediaModeOwnershipGeneration)
        commandLifecycleLock.unlock()
        stopLiveView()
        return preparation
    }

    /// Releases media ownership so monitor live view may start again.
    public func exitMediaMode() {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        stopMediaTransfer()
        releaseMediaMode()
    }

    /// Releases only the failed browse generation that made this claim. A
    /// newer concurrent begin keeps ownership and is never unlocked by stale
    /// failure cleanup.
    func exitMediaMode(ifOwnedBy ownershipGeneration: UInt64) {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard mediaModeOwnershipGeneration == ownershipGeneration else { return }
        stopMediaTransfer()
        releaseMediaMode()
    }

    /// Clears the media-ownership flag while `commandLifecycleLock` is held.
    private func releaseMediaMode() {
        liveViewCondition.lock()
        mediaModeActive = false
        liveViewCondition.broadcast()
        liveViewCondition.unlock()

        // A reset waiter sleeps on the focus condition. Stopping live view changes its exit gate
        // after the final focus-frame broadcast above, so wake it again after publishing inactive
        // state instead of making it wait for the transaction deadline.
        focusFrameCondition.lock()
        focusFrameCondition.broadcast()
        focusFrameCondition.unlock()
    }

    /// Whether the media surface currently owns the shared command channel.
    var isMediaModeActive: Bool {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        return mediaModeActive
    }

    /// Resolves the true object size. Normal PTP metadata is sufficient below
    /// 4 GiB; its UINT32 sentinel routes large objects through Nikon's 64-bit
    /// `GetObjectSize` operation.
    public func resolvedObjectSize(handle: UInt32, reportedSize: UInt64) throws -> UInt64 {
        guard reportedSize == UInt64(UInt32.max) else { return reportedSize }
        let result = try transactExpectingOK(
            .getObjectSize, parameters: [handle], dataPhase: .dataIn)
        return try PTPObjectSize(data: result.data).bytes
    }

    /// The object star-rating property (UINT16). Values 0/1/25/50/75/100 == Off…★★★★★;
    /// anything else rounds down to the nearest step. RAW stills don't carry it — a pair's
    /// JPEG/HEIF side does. [verify-on-HW]
    private static let ratingObjectPropCode: UInt32 = 0xDC8A

    /// Deletes one object from the card. Protected objects are refused by the body, and the
    /// release stays locked until the deletion completes. [verify-on-HW]
    public func deleteObject(handle: UInt32) throws {
        try transactExpectingOK(.deleteObject, parameters: [handle])
    }

    /// Reads one object's star rating (raw property value, not stars).
    public func objectRating(handle: UInt32) throws -> UInt16 {
        let result = try transactExpectingOK(
            .getObjectPropValue,
            parameters: [handle, Self.ratingObjectPropCode],
            dataPhase: .dataIn)
        guard result.data.count >= 2 else {
            throw PTPIPClientSessionError.operationRejected(.getObjectPropValue, .unknown)
        }
        return UInt16(result.data[result.data.startIndex])
            | (UInt16(result.data[result.data.startIndex + 1]) << 8)
    }

    /// Writes one object's star rating (raw property value).
    public func setObjectRating(handle: UInt32, value: UInt16) throws {
        try transactExpectingOK(
            .setObjectPropValue,
            parameters: [handle, Self.ratingObjectPropCode],
            dataPhase: .dataOut,
            dataOut: Data([UInt8(value & 0xFF), UInt8(value >> 8)]))
    }

    /// Starts a progressive object transfer on one facade-owned thread.
    ///
    /// Protocol policy stays in the shared core: the cursor selects standard
    /// `GetPartialObject` or Nikon `GetPartialObjectEx`, owns the 4 MiB chunk
    /// size, validates every advance, and maintains the 64-bit offset. All
    /// callbacks are serialized on the pump thread, with exactly one terminal
    /// callback after the final chunk.
    public func startMediaTransfer(
        handle: UInt32,
        reportedSize: UInt64,
        resumeOffset: UInt64 = 0,
        onStarted: @escaping @Sendable (UInt64) -> Void,
        onChunk: @escaping @Sendable (UInt64, Data) -> Bool,
        onCompleted: @escaping @Sendable (UInt64) -> Void,
        onStopped: @escaping @Sendable (UInt64) -> Void,
        onFailed: @escaping @Sendable (String) -> Void
    ) throws {
        guard isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeRequired
        }
        let totalBytes = try resolvedObjectSize(handle: handle, reportedSize: reportedSize)
        let cursor = try PTPObjectTransferCursor(
            objectHandle: handle,
            totalBytes: totalBytes,
            resumeOffset: resumeOffset,
            supportsExtendedReads: true)

        mediaTransferCondition.lock()
        guard !mediaTransferActive else {
            mediaTransferCondition.unlock()
            throw PTPIPClientSessionError.connectionFailed(
                "A camera-media transfer is already active.")
        }
        mediaTransferActive = true
        mediaTransferStopRequested = false
        mediaTransferCondition.unlock()

        Thread.detachNewThread { [self] in
            runMediaTransfer(
                cursor: cursor,
                onStarted: onStarted,
                onChunk: onChunk,
                onCompleted: onCompleted,
                onStopped: onStopped,
                onFailed: onFailed)
        }
    }

    /// Stops and joins the active object transfer. The in-flight camera read
    /// remains bounded by the command socket timeout. Safe when idle.
    public func stopMediaTransfer() {
        mediaTransferCondition.lock()
        defer { mediaTransferCondition.unlock() }
        guard mediaTransferActive else { return }
        mediaTransferStopRequested = true
        let deadline = Date().addingTimeInterval(
            commandTransactionTimeout + 2)
        while mediaTransferActive {
            guard mediaTransferCondition.wait(until: deadline) else { return }
        }
    }

    private func runMediaTransfer(
        cursor initialCursor: PTPObjectTransferCursor,
        onStarted: (UInt64) -> Void,
        onChunk: (UInt64, Data) -> Bool,
        onCompleted: (UInt64) -> Void,
        onStopped: (UInt64) -> Void,
        onFailed: (String) -> Void
    ) {
        var cursor = initialCursor
        onStarted(cursor.totalBytes)
        var failure: String?

        while !mediaTransferStopIsRequested(), !cursor.isComplete {
            do {
                guard let request = try cursor.nextRequest() else { break }
                let result = try transactExpectingOK(
                    request.operationCode,
                    parameters: request.parameters,
                    dataPhase: .dataIn)
                let offset = cursor.offset
                guard onChunk(offset, result.data) else {
                    throw PTPIPClientSessionError.connectionFailed(
                        "The progressive media cache rejected a camera chunk.")
                }
                // The JNI upcall is synchronous: Kotlin has persisted this
                // range before returning, so only now may the core cursor
                // advance its durable resume point.
                try cursor.advance(by: UInt64(result.data.count))
            } catch {
                failure = error.localizedDescription
                break
            }
        }

        if let failure {
            onFailed(failure)
        } else if mediaTransferStopIsRequested() {
            onStopped(cursor.offset)
        } else {
            onCompleted(cursor.totalBytes)
        }

        mediaTransferCondition.lock()
        mediaTransferActive = false
        mediaTransferStopRequested = false
        mediaTransferCondition.broadcast()
        mediaTransferCondition.unlock()
    }

    private func mediaTransferStopIsRequested() -> Bool {
        mediaTransferCondition.lock()
        defer { mediaTransferCondition.unlock() }
        return mediaTransferStopRequested
    }

    // MARK: - Live view

    /// Default poll cadence: fixed 60 Hz target (same as
    /// ``AndroidLiveViewPolicyWire/targetFrameRate``).
    public static let liveViewFrameIntervalNanoseconds: UInt64 =
        AndroidLiveViewPolicyWire.standardFrameIntervalNanoseconds

    /// Fastest accepted preview pull (~60 fps).
    public static let minimumLiveViewFrameIntervalNanoseconds: UInt64 =
        AndroidLiveViewPolicyWire.minimumFrameIntervalNanoseconds

    /// Slowest accepted configure interval (validation only; policy always
    /// targets 60 Hz).
    public static let maximumLiveViewFrameIntervalNanoseconds: UInt64 =
        AndroidLiveViewPolicyWire.maximumFrameIntervalNanoseconds

    /// Starts live view and pumps frames from a dedicated background thread.
    ///
    /// Synchronous start, asynchronous stream: `StartLiveView` plus the
    /// `DeviceReady` readiness poll (the iOS shell's 40 × 50 ms cadence) run on
    /// the caller's thread and throw on failure — when this returns, the pump
    /// thread is running and neither callback has fired yet. `onFrame` and
    /// `onEnded` are then all delivered from that one pump thread; `onEnded`
    /// fires exactly once, after the final frame, whether the stream ends by
    /// `stopLiveView`, `disconnect`, or a transport error.
    ///
    /// Backpressure is latest-wins by construction: frames are *pulled* one at
    /// a time and delivered synchronously, so a slow consumer polls less often
    /// and each poll returns the camera's newest frame — nothing queues.
    /// Poll pacing uses an absolute schedule (`start + n × interval`), never an
    /// elapsed-time gate, per the wall-clock aliasing lesson.
    public func startLiveView(
        frameIntervalNanoseconds: UInt64? = nil,
        onFrame: @escaping @Sendable (PTPLiveViewFrame, Int64) -> Void,
        onEnded: @escaping @Sendable () -> Void
    ) throws {
        liveViewCondition.lock()
        guard !mediaModeActive else {
            liveViewCondition.unlock()
            throw PTPIPClientSessionError.mediaModeActive
        }
        guard !liveViewPumpActive else {
            liveViewCondition.unlock()
            throw PTPIPClientSessionError.liveViewAlreadyActive
        }
        liveViewPumpActive = true
        liveViewStopRequested = false
        let effectiveFrameIntervalNanoseconds =
            frameIntervalNanoseconds ?? configuredLiveViewFrameIntervalNanoseconds
        liveViewCondition.unlock()

        do {
            focusFrameCondition.lock()
            latestLiveViewFocus = nil
            focusFrameGeneration = 0
            focusFrameCondition.unlock()
            try transactExpectingOK(.startLiveView)
            try waitForDeviceReady()
        } catch {
            liveViewCondition.lock()
            liveViewPumpActive = false
            liveViewCondition.unlock()
            throw error
        }

        Thread.detachNewThread { [self] in
            runLiveViewPump(
                frameIntervalNanoseconds: effectiveFrameIntervalNanoseconds,
                onFrame: onFrame, onEnded: onEnded)
        }
    }

    /// Stops the live-view pump and blocks until it has exited — which
    /// includes the pump's best-effort `EndLiveView`, so the camera is never
    /// left streaming (the heat-audit rule). Bounded by the socket timeout
    /// plus margin; a no-op when no pump is running. Safe to call repeatedly.
    public func stopLiveView() {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        guard liveViewPumpActive else { return }
        liveViewStopRequested = true
        let deadline = Date().addingTimeInterval(
            commandTransactionTimeout + 2)
        while liveViewPumpActive {
            guard liveViewCondition.wait(until: deadline) else { return }
        }
    }

    /// The iOS shell's post-`StartLiveView` readiness poll: `DeviceReady`
    /// until OK, 40 attempts 50 ms apart.
    private func waitForDeviceReady() throws {
        for _ in 0..<40 {
            let ready = try executeTransaction(.deviceReady)
            if ready.operationResponse.responseCode == .ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw PTPIPClientSessionError.timeout("Device readiness polling")
    }

    /// Pump body: fetch → deliver → sleep-to-schedule, until stop or a
    /// transport error, then best-effort `EndLiveView` and exactly one
    /// `onEnded`.
    private func runLiveViewPump(
        frameIntervalNanoseconds: UInt64,
        onFrame: (PTPLiveViewFrame, Int64) -> Void,
        onEnded: () -> Void
    ) {
        let startNanos = Self.monotonicNanoseconds()
        var pollIndex: UInt64 = 0
        while !liveViewStopIsRequested() {
            do {
                let result = try transactExpectingOK(.getLiveViewImageEx, dataPhase: .dataIn)
                let frame = try PTPLiveViewObject.frame(from: result.data)
                focusFrameCondition.lock()
                latestLiveViewFocus = frame.focus
                focusFrameGeneration &+= 1
                focusFrameCondition.broadcast()
                focusFrameCondition.unlock()
                onFrame(frame, Int64(Self.monotonicNanoseconds()))
            } catch is PTPLiveViewObjectError {
                // A single unparsable frame is stream jitter, not a stream
                // death — skip it, like the iOS watchdog's bad-frame budget.
            } catch let error as PTPIPClientSessionError {
                // Nikon returns DeviceBusy around movie-rec start/stop and during
                // body-side encoder handoff. Treating that as stream death called
                // EndLiveView, and StartLiveView often fails for the rest of the
                // take — operator-visible as a frozen feed until recording stops.
                if case .operationRejected(_, .deviceBusy) = error {
                    // Fall through to schedule sleep and retry the next poll.
                } else {
                    break  // Hard rejection / closed session: the stream is over.
                }
            } catch {
                break  // Transport error: the stream is over.
            }
            // Absolute schedule: poll k is due at start + k × interval. When a
            // fetch overruns, re-anchor to now instead of accumulating debt —
            // an elapsed>=interval gate against a paced source only ever locks
            // onto source/N (the wall-clock aliasing lesson, 4ae1544).
            pollIndex += 1
            let elapsed = Self.monotonicNanoseconds() - startNanos
            let due = pollIndex * frameIntervalNanoseconds
            if due > elapsed {
                Thread.sleep(forTimeInterval: Double(due - elapsed) / 1_000_000_000)
            } else {
                pollIndex = elapsed / frameIntervalNanoseconds
            }
        }

        // Release the camera's encoder before signalling the stream end —
        // never leave the body streaming to nobody (the heat-audit EndLiveView
        // rule). Best-effort: on a dead link this fails fast and teardown
        // proceeds.
        _ = try? transactExpectingOK(.endLiveView)

        // `onEnded` before the join broadcast, so a returned `stopLiveView`
        // (and therefore `disconnect`) guarantees the terminal callback has
        // already been delivered.
        onEnded()
        liveViewCondition.lock()
        liveViewPumpActive = false
        liveViewStopRequested = false
        liveViewCondition.unlock()

        // A reset waiter sleeps on the focus condition and checks live-view state while holding
        // it. Publish inactive state first, then clear/broadcast focus, so the waiter cannot wake,
        // still see an active pump, and sleep forever after the final frame.
        focusFrameCondition.lock()
        latestLiveViewFocus = nil
        focusFrameCondition.broadcast()
        focusFrameCondition.unlock()

        // Wake stopLiveView only after the focus waiter has observed the terminal state. This also
        // preserves the contract that onEnded ran before stopLiveView returns.
        liveViewCondition.lock()
        liveViewCondition.broadcast()
        liveViewCondition.unlock()
    }

    private func liveViewStopIsRequested() -> Bool {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        return liveViewStopRequested
    }

    /// `CLOCK_MONOTONIC` in nanoseconds — frame timestamps that match the
    /// semantics of Kotlin's `System.nanoTime()`.
    static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    /// Latest successful serialized PTP request/response duration, or nil
    /// before any transaction and after disconnect.
    public func latestCommandRoundTripMilliseconds() -> Double? {
        roundTripLock.lock()
        defer { roundTripLock.unlock() }
        return latestRoundTripMillisecondsStorage
    }

    private func recordRoundTrip(startNanoseconds: UInt64, endNanoseconds: UInt64) {
        guard endNanoseconds > startNanoseconds else { return }
        let milliseconds = Double(endNanoseconds - startNanoseconds) / 1_000_000
        guard milliseconds.isFinite, milliseconds > 0 else { return }
        roundTripLock.lock()
        latestRoundTripMillisecondsStorage = milliseconds
        roundTripLock.unlock()
    }

    private func clearRoundTrip() {
        roundTripLock.lock()
        latestRoundTripMillisecondsStorage = nil
        roundTripLock.unlock()
    }

    // MARK: - Teardown

    /// Graceful teardown: best-effort `CloseSession` so the camera releases its
    /// session slot immediately, THEN drop both sockets — the same semantics as
    /// the iOS reconnect-wedge fix (`NativeCameraSession.shutdown`). Bounded:
    /// the read timeout is dropped to 2 s **before** joining live view / media
    /// / CloseSession, so a dead link cannot stall teardown for the full
    /// 10 s command poll. Safe to call more than once.
    ///
    /// A running live-view pump is stopped (and joined) first, so the wire
    /// order on teardown is always `EndLiveView` → `CloseSession`.
    public func disconnect() {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        // Bound every remaining join before waiting: EndLiveView, media stop,
        // and CloseSession all inherit the shortened command timeout.
        command?.timeoutMilliseconds = 2_000
        #if os(Android)
            // USB shares the same 2 s teardown budget as Wi‑Fi CloseSession.
            // (executeTransactionSynchronously still takes an explicit deadline.)
        #endif
        stopEventDrain()
        stopMediaTransfer()
        releaseMediaMode()
        stopLiveView()
        transactionLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        transactionLock.unlock()
        guard !alreadyClosed else { return }

        #if os(Android)
            if let usbTransport {
                _ = try? usbTransport.executeTransactionSynchronously(
                    operationCode: .closeSession,
                    deadline: .seconds(2)
                )
                usbTransport.close()
                clearRoundTrip()
                return
            }
        #endif
        _ = try? executeTransaction(.closeSession)
        command?.close()
        event?.close()
        clearRoundTrip()
    }

    // MARK: - Transaction executor

    // Internal (not private): the media-browse slice (MediaBrowse.swift)
    // extends the session with object/storage transactions.
    @discardableResult
    func transactExpectingOK(
        _ operationCode: PTPOperationCode,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil
    ) throws -> PTPIPTransactionResult {
        let result = try executeTransaction(
            operationCode,
            parameters: parameters,
            dataPhase: dataPhase,
            dataOut: dataOut)
        guard result.operationResponse.responseCode == .ok else {
            throw PTPIPClientSessionError.operationRejected(
                operationCode, result.operationResponse.responseCode)
        }
        return result
    }

    /// Executes one full PTP transaction on the command channel: operation
    /// request, optional host-to-camera data phase, then packets in until
    /// `Operation_Response`, collected by the core.
    func executeTransaction(
        _ operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32? = nil,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil
    ) throws -> PTPIPTransactionResult {
        #if os(Android)
            if let usbTransport {
                let result = try usbTransport.executeTransactionSynchronously(
                    operationCode: operationCode,
                    transactionID: explicitTransactionID,
                    parameters: parameters,
                    dataPhase: dataPhase,
                    dataOut: dataOut
                )
                if let milliseconds = usbTransport.latestCommandRoundTripMilliseconds() {
                    roundTripLock.lock()
                    latestRoundTripMillisecondsStorage = milliseconds
                    roundTripLock.unlock()
                }
                return result
            }
        #endif
        transactionLock.lock()
        defer { transactionLock.unlock() }

        guard let command else {
            throw PTPIPClientSessionError.connectionClosed
        }
        let roundTripStart = Self.monotonicNanoseconds()

        let transactionID = explicitTransactionID ?? nextTransactionID
        if explicitTransactionID == nil {
            nextTransactionID += 1
        }
        let request = PTPOperationRequest(
            dataPhase: dataPhase,
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters)
        try command.send(
            PTPIPPacket(type: .operationRequest, payload: Data(request.payloadBytes)))
        if let dataOut {
            try command.send(
                PTPIPPacket(
                    type: .startData,
                    payload: Data(
                        PTPDataPayloads.startData(
                            transactionID: transactionID,
                            totalLength: UInt64(dataOut.count)))))
            try command.send(
                PTPIPPacket(
                    type: .endData,
                    payload: Data(
                        PTPDataPayloads.endData(transactionID: transactionID, data: dataOut))))
        }

        var packets: [PTPIPPacket] = []
        while true {
            let packet = try command.readPacket()
            packets.append(packet)
            if packet.type == .operationResponse {
                let result = try PTPIPTransactionCollector().collect(from: packets)
                recordRoundTrip(
                    startNanoseconds: roundTripStart,
                    endNanoseconds: Self.monotonicNanoseconds())
                return result
            }
            // Same desync guard as the iOS transport: a stream that never sends
            // operationResponse must not grow `packets` forever.
            guard packets.count <= 512 else {
                throw PTPIPClientSessionError.connectionFailed(
                    "PTP-IP transaction exceeded 512 packets without a response — stream desynchronized."
                )
            }
        }
    }

    /// Uppercase hex without `String(format:)` (which drags umbrella Foundation
    /// on Android — see the feasibility doc's ICU finding).
    static func hexString<Value: BinaryInteger>(_ value: Value) -> String {
        String(value, radix: 16, uppercase: true)
    }

    private var commandTransactionTimeout: TimeInterval {
        #if os(Android)
            if usbTransport != nil { return 10 }
        #endif
        return Double(command?.timeoutMilliseconds ?? 10_000) / 1_000
    }
}

/// A blocking POSIX TCP socket with poll-bounded I/O — the facade twin of the
/// iOS shell's `PTPIPSocket`, minus the Dispatch queue (callers here are plain
/// JVM/test threads). Compiles against Darwin, Glibc, and bionic libc.
// SAFETY: `@unchecked Sendable` — the descriptor is guarded by `descriptorLock`;
// I/O is serialized by the owning session's transaction lock.
final class PosixTCPSocket: @unchecked Sendable {
    init(host: String, port: UInt16, label: String, timeoutMilliseconds: Int32) {
        self.host = host
        self.port = port
        self.label = label
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    private let host: String
    private let port: UInt16
    private let label: String
    /// Per-poll timeout; mutable so teardown can shorten it (see `disconnect`).
    var timeoutMilliseconds: Int32
    private let descriptorLock = NSLock()
    private var descriptor: Int32 = -1
    private var readBuffer = PTPIPReadBuffer()

    func open() throws {
        close()

        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw PTPIPClientSessionError.connectionFailed(
                "Enter a numeric IPv4 camera address. Host names are not supported yet.")
        }

        let newDescriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP))
        guard newDescriptor >= 0 else {
            throw socketError(errno, context: "\(label) socket")
        }
        storeDescriptor(newDescriptor)

        var noDelay: Int32 = 1
        setsockopt(
            newDescriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay,
            socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            setsockopt(
                newDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size))
        #endif
        // ponytail: the iOS twin's keepalive timer tuning arrives with the
        // Android reconnect machinery — connect/read/disconnect doesn't idle.

        let flags = fcntl(newDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(newDescriptor, F_SETFL, flags | O_NONBLOCK)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(newDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            let code = errno
            guard code == EINPROGRESS else {
                close()
                throw socketError(code, context: "\(label) connection")
            }
            try waitForDescriptor(
                newDescriptor, events: Int16(POLLOUT), label: "\(label) connection")

            var connectError: Int32 = 0
            var connectErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard
                getsockopt(newDescriptor, SOL_SOCKET, SO_ERROR, &connectError, &connectErrorLength)
                    == 0
            else {
                close()
                throw socketError(errno, context: "\(label) connection")
            }
            guard connectError == 0 else {
                close()
                throw socketError(connectError, context: "\(label) connection")
            }
        }
    }

    func close() {
        descriptorLock.lock()
        let descriptorToClose = descriptor
        descriptor = -1
        descriptorLock.unlock()

        if descriptorToClose >= 0 {
            shutdown(descriptorToClose, Int32(SHUT_RDWR))
            #if canImport(Android)
                Android.close(descriptorToClose)
            #elseif canImport(Glibc)
                Glibc.close(descriptorToClose)
            #else
                Darwin.close(descriptorToClose)
            #endif
        }
    }

    func send(_ packet: PTPIPPacket) throws {
        let data = Data(packet.serializedBytes)
        let descriptor = try currentDescriptor()
        #if canImport(Darwin)
            let sendFlags: Int32 = 0
        #else
            let sendFlags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                try waitForDescriptor(descriptor, events: Int16(POLLOUT), label: "\(label) send")
                let sent = platformSend(
                    descriptor, base.advanced(by: offset), data.count - offset, sendFlags)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent == 0 {
                    throw PTPIPClientSessionError.connectionClosed
                }
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                    continue
                }
                throw socketError(code, context: "\(label) send")
            }
        }
    }

    /// Reads one length-prefixed PTP-IP packet, with the same framing guards as
    /// the iOS transport (8-byte header, 128 MiB payload ceiling).
    func readPacket() throws -> PTPIPPacket {
        let header = try readExact(byteCount: 8)
        let headerBytes = Array(header)
        let length = ByteCoding.readUInt32LE(headerBytes, at: 0)
        guard length >= 8 && length <= 128 * 1024 * 1024 else {
            throw PTPIPClientSessionError.invalidPacketLength(length)
        }
        let payloadLength = Int(length) - 8
        let payload = payloadLength > 0 ? try readExact(byteCount: payloadLength) : Data()
        return try PTPIPPacket(serializedBytes: headerBytes + Array(payload))
    }

    private func readExact(byteCount: Int) throws -> Data {
        let descriptor = try currentDescriptor()
        while readBuffer.availableCount < byteCount {
            try waitForDescriptor(descriptor, events: Int16(POLLIN), label: "\(label) receive")
            let remaining = byteCount - readBuffer.availableCount
            let maximumLength = min(max(remaining, 4096), 256 * 1024)
            var bytes = [UInt8](repeating: 0, count: maximumLength)
            let received = bytes.withUnsafeMutableBytes { rawBuffer in
                recv(descriptor, rawBuffer.baseAddress, maximumLength, 0)
            }
            if received > 0 {
                readBuffer.append(Data(bytes.prefix(received)))
                continue
            }
            if received == 0 {
                throw PTPIPClientSessionError.connectionClosed
            }
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                continue
            }
            throw socketError(code, context: "\(label) receive")
        }
        // SAFETY: the loop guarantees availableCount >= byteCount, so `take` cannot return nil.
        return readBuffer.take(byteCount)!
    }

    private func waitForDescriptor(_ descriptor: Int32, events: Int16, label: String) throws {
        // Loop rather than recurse on EINTR / spurious wakeups (same rationale
        // as the iOS twin: a signal storm must not grow the stack).
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&pollDescriptor, 1, min(timeoutMilliseconds, 30_000))
            if result > 0 {
                if (pollDescriptor.revents & events) != 0 {
                    return
                }
                if (pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                    throw PTPIPClientSessionError.connectionClosed
                }
                continue
            }
            if result == 0 {
                throw PTPIPClientSessionError.timeout(label)
            }
            if errno == EINTR {
                continue
            }
            throw socketError(errno, context: label)
        }
    }

    private func platformSend(
        _ descriptor: Int32, _ base: UnsafeRawPointer, _ count: Int, _ flags: Int32
    ) -> Int {
        #if canImport(Android)
            Android.send(descriptor, base, count, flags)
        #elseif canImport(Glibc)
            Glibc.send(descriptor, base, count, flags)
        #else
            Darwin.send(descriptor, base, count, flags)
        #endif
    }

    private func storeDescriptor(_ descriptor: Int32) {
        descriptorLock.lock()
        self.descriptor = descriptor
        descriptorLock.unlock()
    }

    private func currentDescriptor() throws -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        guard descriptor >= 0 else { throw PTPIPClientSessionError.connectionClosed }
        return descriptor
    }

    private func socketError(_ code: Int32, context: String) -> PTPIPClientSessionError {
        if code == ECONNREFUSED {
            return .connectionFailed(
                "No PTP-IP service answered at \(host):\(port). Confirm the camera is in PC/remote network mode."
            )
        }
        return .connectionFailed("\(context) failed: \(String(cString: strerror(code)))")
    }
}
