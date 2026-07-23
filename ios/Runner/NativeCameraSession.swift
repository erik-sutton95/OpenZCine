import Darwin
import Foundation
import os

private let connectionLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-connection"
)

/// Storage-readback diagnostics: when the top-bar media figure falls back to the placeholder,
/// filter Console for subsystem `OpenZCine`, category `camera-storage` to see which step failed.
private let storageLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-storage"
)

/// Media-browsing diagnostics (Media page clip listing/fetch). Filter Console for subsystem
/// `OpenZCine`, category `camera-media` to trace GetObjectHandles / GetObjectInfo / GetPartialObject.
private let mediaLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-media"
)

struct NativeCameraIdentity: Equatable {
    let host: String
    let cameraName: String
    let manufacturer: String
    let model: String
    let deviceVersion: String
    let serialNumber: String
    let establishmentSummary: String

    var displayName: String {
        CameraDisplayNamePolicy.displayName(
            cameraName: cameraName,
            manufacturer: manufacturer,
            model: model
        )
    }
}

enum NativeCameraSessionError: Error, LocalizedError {
    case noHost
    case connectionFailed(String)
    case connectionClosed
    case timeout(String)
    case unexpectedPacket(expected: String, actual: PTPIPPacketType)
    case initFailed(PTPIPInitFailReason)
    case operationRejected(PTPOperationCode, PTPResponseCode)
    case invalidPacketLength(UInt32)
    case localNetworkPermissionDenied
    case pairingRejected
    case pairingChallengeUnavailable
    case savedProfileRequired

    var errorDescription: String? {
        switch self {
        case .noHost:
            return "Enter the camera IP address, or connect to the camera's Wi-Fi network first."
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
        case .localNetworkPermissionDenied:
            return
                "iOS blocked local network socket access. If Local Network is enabled in Settings, confirm the phone is on the camera Wi-Fi/LAN and try again."
        case .pairingRejected:
            return "Pairing was rejected."
        case .pairingChallengeUnavailable:
            return
                "The Nikon did not provide a pairing code. Restart Connect to PC on the camera, then pair again."
        case .savedProfileRequired:
            return "The camera requires first-time pairing before app control can start."
        }
    }
}

typealias NativePairingChallengeHandler = @Sendable (PTPIPPairingChallenge) async -> Bool

@MainActor
final class NativeCameraConnectionStore {
    static let shared = NativeCameraConnectionStore()

    private let guidKey = "OpenZCine.PTPIP.GUID"
    private let pairedHostsKey = "OpenZCine.PTPIP.PairedHosts"
    private let savedCamerasKey = "OpenZCine.PTPIP.SavedCameras"
    private let knownPairedCamerasKey = "OpenZCine.PTPIP.KnownPairedCameras"

    private init() {
        migrateLegacyRebrandKeysIfNeeded()
    }

    /// One-time, idempotent migration of the pre-rebrand `OpenZCinemaControl.*` UserDefaults keys
    /// to `OpenZCine.*` — without it the rename orphans the saved/paired-camera list and cached
    /// app GUID, forcing a full camera re-pair.
    private func migrateLegacyRebrandKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let migrations = [
            ("OpenZCinemaControl.PTPIP.GUID", guidKey),
            ("OpenZCinemaControl.PTPIP.PairedHosts", pairedHostsKey),
            ("OpenZCinemaControl.PTPIP.SavedCameras", savedCamerasKey),
            ("OpenZCinemaControl.PTPIP.KnownPairedCameras", knownPairedCamerasKey),
        ]
        for (legacyKey, currentKey) in migrations {
            guard defaults.object(forKey: currentKey) == nil else { continue }
            guard let value = defaults.object(forKey: legacyKey) else { continue }
            defaults.set(value, forKey: currentKey)
            defaults.removeObject(forKey: legacyKey)
        }
    }

    func guid() -> Data {
        let defaults = UserDefaults.standard
        let persistedGUID = defaults.data(forKey: guidKey)
        let resolvedGUID = PTPIPInitiator.resolvedAppGUID(persistedGUID: persistedGUID)
        if persistedGUID != resolvedGUID {
            defaults.set(resolvedGUID, forKey: guidKey)
        }
        return resolvedGUID
    }

    func pairedHosts() -> [String] {
        knownPairedCameras().map(\.host)
    }

    func isPaired(host: String) -> Bool {
        PTPIPSavedCameraRecords.canonicalized(knownPairedCameras()).contains {
            $0.host == PTPIPPairedHosts.normalizedHost(host)
        }
    }

    func markPaired(host: String) {
        upsertKnownPairedCamera(
            host: host,
            displayName: "",
            transport: "Wi-Fi",
            lastSeenAt: Date()
        )
    }

    func upsertSavedCamera(host: String, displayName: String, transport: String) {
        var records = PTPIPSavedCameraRecords.upserting(
            host: host,
            displayName: displayName,
            transport: transport,
            lastSeenAt: Date(),
            into: savedCameras()
        )
        if let ssid = CameraWiFiSSID.deriveSSID(fromCameraName: displayName),
            transport.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(PTPIPSavedCameraRecord.usbTransportLabel) != .orderedSame
        {
            records = PTPIPSavedCameraRecords.updatingWiFiSSID(
                host: host,
                wifiSSID: ssid,
                in: records
            )
        }
        saveSavedCameras(records)
        upsertKnownPairedCamera(
            host: host,
            displayName: displayName,
            transport: transport,
            lastSeenAt: Date()
        )
    }

    func updateSavedCameraPresentation(
        host: String,
        customName: String?,
        borderColor: String?,
        icon: String?
    ) {
        let records = PTPIPSavedCameraRecords.updatingPresentation(
            host: host,
            customName: customName,
            borderColor: borderColor,
            icon: icon,
            in: savedCameras()
        )
        saveSavedCameras(records)
    }

    func forgetPairing(host: String) {
        saveSavedCameras(PTPIPSavedCameraRecords.removing(host, from: savedCameras()))
    }

    func forgetKnownPairing(host: String) {
        saveKnownPairedCameras(
            PTPIPSavedCameraRecords.removing(host, from: knownPairedCameras())
        )
        saveSavedCameras(PTPIPSavedCameraRecords.removing(host, from: savedCameras()))
    }

    func savedCameras() -> [PTPIPSavedCameraRecord] {
        let records = decodedSavedCameras()
        if !records.isEmpty {
            let canonical = PTPIPSavedCameraRecords.canonicalized(records)
            if canonical != records {
                saveSavedCameras(canonical)
            }
            return canonical
        }
        return []
    }

    func knownPairedCameras() -> [PTPIPSavedCameraRecord] {
        let records = decodedKnownPairedCameras()
        let legacyHosts = PTPIPPairedHosts.canonicalized(
            UserDefaults.standard.stringArray(forKey: pairedHostsKey) ?? []
        ).map {
            PTPIPSavedCameraRecord(
                host: $0,
                displayName: "Camera \($0)",
                transport: "Wi-Fi",
                lastSeenAt: nil
            )
        }
        let migrated = PTPIPSavedCameraRecords.canonicalized(
            records + legacyHosts + decodedSavedCameras()
        )
        if migrated != records {
            saveKnownPairedCameras(migrated)
        }
        return migrated
    }

    private func decodedSavedCameras() -> [PTPIPSavedCameraRecord] {
        decodedCameraRecords(forKey: savedCamerasKey)
    }

    private func decodedKnownPairedCameras() -> [PTPIPSavedCameraRecord] {
        decodedCameraRecords(forKey: knownPairedCamerasKey)
    }

    private func decodedCameraRecords(forKey key: String) -> [PTPIPSavedCameraRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let records = try? JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    private func upsertKnownPairedCamera(
        host: String,
        displayName: String,
        transport: String,
        lastSeenAt: Date?
    ) {
        let records = PTPIPSavedCameraRecords.upserting(
            host: host,
            displayName: displayName,
            transport: transport,
            lastSeenAt: lastSeenAt,
            into: knownPairedCameras()
        )
        saveKnownPairedCameras(records)
    }

    private func saveSavedCameras(_ records: [PTPIPSavedCameraRecord]) {
        let canonical = PTPIPSavedCameraRecords.canonicalized(records)
        if let data = try? JSONEncoder().encode(canonical) {
            UserDefaults.standard.set(data, forKey: savedCamerasKey)
        }
    }

    private func saveKnownPairedCameras(_ records: [PTPIPSavedCameraRecord]) {
        let canonical = PTPIPSavedCameraRecords.canonicalized(records)
        if let data = try? JSONEncoder().encode(canonical) {
            UserDefaults.standard.set(data, forKey: knownPairedCamerasKey)
        }
        UserDefaults.standard.set(canonical.map(\.host), forKey: pairedHostsKey)
    }
}

// SAFETY: `@unchecked Sendable` — `establishmentSummary` is mutated only during the serialized
// establishment sequence (`openAndIdentify` and its helpers run one transaction at a time); the
// transport serializes its own transactions and socket/device I/O internally.
final class NativeCameraSession: @unchecked Sendable {
    private init(
        host: String,
        transport: any CameraTransport,
        cameraName: String?,
        establishmentSummary: String,
        identity: NativeCameraIdentity
    ) {
        self.host = host
        self.transport = transport
        self.cameraName = cameraName
        self.establishmentSummary = establishmentSummary
        self.identity = identity
    }

    /// Stable camera key: the IPv4 address over Wi-Fi, or a `usb:<device-id>` host key over USB-C.
    let host: String
    let identity: NativeCameraIdentity

    private let transport: any CameraTransport
    private let cameraName: String?
    private var establishmentSummary: String
    private let metricsLock = NSLock()
    private(set) var lastCommandRoundTripMilliseconds: Double?

    /// The physical link kind carrying this session (drives transport labels in the UI).
    var transportKind: CameraTransportKind { transport.kind }

    func readLastCommandRoundTripMilliseconds() -> Double? {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return lastCommandRoundTripMilliseconds
    }

    private func recordCommandRoundTrip(startedAt: Date) {
        let milliseconds = Date().timeIntervalSince(startedAt) * 1000
        metricsLock.lock()
        lastCommandRoundTripMilliseconds = milliseconds
        metricsLock.unlock()
    }

    /// Establishes a Wi-Fi (PTP-IP) session: Init handshake on both TCP channels, then the shared
    /// open/pair/identify sequence.
    static func establish(
        host rawHost: String,
        guid: Data,
        friendlyName: String = PTPIPInitiator.friendlyName,
        requestPairing: Bool = true,
        onPairingChallenge: NativePairingChallengeHandler? = nil,
        onEstablishmentDiagnostic: (@Sendable (String) -> Void)? = nil
    ) async throws -> NativeCameraSession {
        let transport = try await PTPIPTransport.connect(
            host: rawHost,
            guid: guid,
            friendlyName: friendlyName
        )
        return try await establish(
            transport: transport,
            host: transport.host,
            cameraName: transport.cameraName,
            requestPairing: requestPairing,
            onPairingChallenge: onPairingChallenge,
            onEstablishmentDiagnostic: onEstablishmentDiagnostic
        )
    }

    /// Establishes a session over an already-connected transport (any link kind): OpenSession,
    /// optional pairing, app-control mode, and GetDeviceInfo. Closes the transport on failure.
    static func establish(
        transport: any CameraTransport,
        host: String,
        cameraName: String?,
        requestPairing: Bool,
        onPairingChallenge: NativePairingChallengeHandler? = nil,
        onEstablishmentDiagnostic: (@Sendable (String) -> Void)? = nil
    ) async throws -> NativeCameraSession {
        let session = NativeCameraSession(
            host: host,
            transport: transport,
            cameraName: cameraName,
            establishmentSummary: "",
            identity: NativeCameraIdentity(
                host: host,
                cameraName: cameraName ?? "Nikon camera",
                manufacturer: "",
                model: "",
                deviceVersion: "",
                serialNumber: "",
                establishmentSummary: ""
            )
        )
        do {
            return try await session.openAndIdentify(
                requestPairing: requestPairing,
                onPairingChallenge: onPairingChallenge,
                onStage: { onEstablishmentDiagnostic?("stage:\($0)") }
            )
        } catch {
            if !session.establishmentSummary.isEmpty {
                onEstablishmentDiagnostic?(session.establishmentSummary)
            }
            // If OpenSession succeeded but a later step threw, the camera still holds the session
            // slot; a bare socket close leaves it stale and wedges the next retry. Graceful
            // CloseSession first (best-effort; a no-op if OpenSession never ran).
            await session.shutdown()
            throw error
        }
    }

    /// Whether a failed establishment may be retried once in place, silently. Right after a
    /// camera-AP Wi-Fi join the ZR's PTP-IP endpoint can lag the network by a beat (connect
    /// refused / handshake timeout), or a just-released session slot can still read busy —
    /// transient failures an immediate second attempt clears.
    ///
    /// Never retried:
    /// - any attempt that requested pairing — a body on its pairing wizard must not be re-probed
    ///   (attempt 1 may have knocked it out of pairing mode) and a retry re-fires camera-side
    ///   pairing prompts;
    /// - failures with their own fallback or recovery copy (`savedProfileRequired` → re-pair
    ///   flow, `rejectedInitiator` → "create a Connect to PC profile", Local Network permission,
    ///   pairing errors);
    /// - cancellation (the operator already abandoned the attempt).
    ///
    /// Errors outside `NativeCameraSessionError` are raw socket/NW failures — transient.
    static func isRetryableEstablishFailure(_ error: Error, requestPairing: Bool) -> Bool {
        if requestPairing { return false }
        if error is CancellationError { return false }
        guard let sessionError = error as? NativeCameraSessionError else { return true }
        switch sessionError {
        case .noHost, .localNetworkPermissionDenied, .pairingRejected,
            .pairingChallengeUnavailable, .savedProfileRequired,
            .initFailed(.rejectedInitiator):
            return false
        case .connectionFailed, .connectionClosed, .timeout, .unexpectedPacket,
            .invalidPacketLength, .operationRejected, .initFailed:
            return true
        }
    }

    func close() {
        transport.close()
    }

    /// Graceful teardown: best-effort `CloseSession` (0x1003) so the camera releases its PTP
    /// session and connection slot immediately, THEN drop the sockets.
    ///
    /// Root cause of the field reconnect-wedge: the app used to close sockets without ever sending
    /// `CloseSession`. On a dropped/half-dead link the TCP FIN may never arrive, so the ZR holds
    /// the session slot until its own keepalive expires (30s+); a reconnect inside that window can
    /// wedge its PTP state machine hard enough to need a battery pull.
    ///
    /// Bounded so it can never stall teardown: the transact carries a 2s deadline, and on breach
    /// `executeTransaction` closes the command socket itself (waking any blocked send), so this
    /// returns within ~2s even on a dead link before `transport.close()` drops both sockets
    /// (command + event, so the event channel can't leak its own slot). `try?`: CloseSession to a
    /// dead/never-opened session fails fast and is ignored — teardown proceeds regardless.
    ///
    /// [verify-on-HW: confirm CloseSession-then-close makes the ZR release the slot and accept the
    /// next Init without the timeout→retry dance the logs show today.]
    func shutdown() async {
        // Over USB, ImageCaptureCore owns the PTP session (it opened it — that's why OpenSession
        // tolerates Session_Already_Open). Closing it behind ICC's back leaves the parked warm
        // session pointing at a dead PTP session, and the next adopt fails its first command
        // (ICC -21400). Wi-Fi keeps the graceful CloseSession — a wedged ZR slot otherwise
        // rejects the next Init. [verify-on-HW: USB disconnect → reconnect]
        if transport.kind != .usb {
            _ = try? await transact(operationCode: .closeSession, deadline: .seconds(2))
        }
        transport.close()
    }

    /// Reads the next event pushed on the camera's event channel. The session owner drains this in
    /// a loop: the ZR pushes async events (record start/stop `0xC10A`/`0xC108`, DevicePropChanged
    /// `0x4006`, store-full `0x400A`, …) and an undrained channel backs up the camera's send buffer
    /// — deep into a long take that can stall or drop the whole session. A routine idle gap
    /// surfaces as benign `.timeout` (the channel is sparse); a hard failure throws and ends the
    /// drain so the session can reconnect.
    func nextEvent() async throws -> PTPEvent {
        try await transport.nextEvent()
    }

    func startLiveView() async throws {
        let start = try await transact(operationCode: .startLiveView)
        guard start.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .startLiveView,
                start.operationResponse.responseCode
            )
        }

        for _ in 0..<40 {
            let ready = try await transact(operationCode: .deviceReady)
            if ready.operationResponse.responseCode == .ok {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NativeCameraSessionError.timeout("Device readiness polling")
    }

    func stopLiveView() async {
        _ = try? await transact(operationCode: .endLiveView)
    }

    /// Starts / stops movie recording to the card (Nikon StartMovieRecInCard / EndMovieRec).
    func startRecording() async throws {
        let result = try await transact(operationCode: .startMovieRecInCard)
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .startMovieRecInCard, result.operationResponse.responseCode)
        }
    }

    func stopRecording() async throws {
        let result = try await transact(operationCode: .endMovieRec)
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .endMovieRec, result.operationResponse.responseCode)
        }
    }

    func configureLiveView(size: UInt8 = 2, compression: UInt8 = 2) async {
        await setLiveViewByte(label: "lvSize", property: .liveViewImageSize, value: size)
        await setLiveViewByte(
            label: "lvComp", property: .liveViewImageCompression, value: compression)
    }

    func liveViewFrameJPEG() async throws -> Data {
        try await liveViewFrame().jpeg
    }

    /// Fetches the next live-view frame. `deadline` bounds the fetch so a camera that accepts
    /// `GetLiveViewImageEx` but delivers no bytes can't hang forever: on breach the whole-
    /// transaction deadline closes the command socket, the fetch throws, and the streaming loop
    /// recovers (restart → reconnect). `nil` is unbounded — used only where a hang is separately
    /// backstopped. The streaming loop MUST pass a finite value: `LiveViewWatchdog` is a pure timer
    /// checked only BETWEEN frames, so it cannot interrupt a single fetch that never returns — and
    /// a stuck nil-deadline fetch holds the serial transaction gate, starving every other command
    /// ("connected but frozen, and all control dead").
    func liveViewFrame(deadline: Duration? = nil) async throws -> PTPLiveViewFrame {
        let startedAt = Date()
        let result = try await transact(
            operationCode: .getLiveViewImageEx, dataPhase: .dataIn, deadline: deadline)
        recordCommandRoundTrip(startedAt: startedAt)
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getLiveViewImageEx,
                result.operationResponse.responseCode
            )
        }
        return try PTPLiveViewObject.frame(from: result.data)
    }

    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
        let result = try await transact(
            operationCode: .getDevicePropValueEx,
            parameters: [property.rawValue],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getDevicePropValueEx,
                result.operationResponse.responseCode
            )
        }
        return result.data
    }

    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
        // Observed interoperability behavior: 2-byte `0xDxxx` properties
        // use the standard PTP SetDevicePropValue (0x1016); only 4-byte extended `0x0001_Dxxx`
        // properties use the Nikon SetDevicePropValueEx (0x943C). Ex-writing a 2-byte
        // recording-format property (MovScreenSize/MovFileType) makes the ZR slam the connection.
        let op: PTPOperationCode =
            write.property.rawValue <= 0xFFFF ? .setDevicePropValue : .setDevicePropValueEx
        let result = try await transact(
            operationCode: op,
            parameters: [write.property.rawValue],
            dataPhase: .dataOut,
            dataOut: write.data
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                op, result.operationResponse.responseCode)
        }
    }

    /// Moves the live-view AF area to `(x, y)` in the camera's live-view coordinate space
    /// (`ChangeAfArea`, 2 params, no data phase). Unverified against hardware.
    func changeAfArea(x: UInt32, y: UInt32) async throws {
        let result = try await transact(
            operationCode: .changeAfArea,
            parameters: [x, y],
            dataPhase: .noDataOrDataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .changeAfArea,
                result.operationResponse.responseCode
            )
        }
    }

    func afDriveCancel() async throws {
        let result = try await transact(
            operationCode: .afDriveCancel,
            parameters: [],
            dataPhase: .noDataOrDataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .afDriveCancel,
                result.operationResponse.responseCode
            )
        }
    }

    func endTracking() async throws {
        let result = try await transact(
            operationCode: .endTracking,
            parameters: [],
            dataPhase: .noDataOrDataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .endTracking,
                result.operationResponse.responseCode
            )
        }
    }

    func waitUntilDeviceReady(maxAttempts: Int = 20, interval: Duration = .milliseconds(50))
        async throws
    {
        for _ in 0..<maxAttempts {
            let ready = try await transact(operationCode: .deviceReady)
            if ready.operationResponse.responseCode == .ok { return }
            try await Task.sleep(for: interval)
        }
        throw NativeCameraSessionError.timeout("Device readiness polling after focus reset")
    }

    /// Reads the `MovScreenSize` descriptor and returns the camera's advertised recording modes
    /// (exact packed values + labels) so the app only ever writes valid ones.
    func screenSizeModes() async throws -> [PTPCameraScreenSizeMode] {
        let result = try await transact(
            operationCode: .getDevicePropDescEx,
            parameters: [PTPPropertyCode.movieRecordScreenSize.rawValue],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getDevicePropDescEx, result.operationResponse.responseCode)
        }
        return PTPCameraPropertyDecoders.screenSizeModes(fromDescriptor: result.data)
    }

    /// Reads the `MovFileType` descriptor and returns the camera's advertised codecs (exact values
    /// + labels), so the app only ever writes a codec/depth/container the body supports.
    func fileTypeModes() async throws -> [PTPCameraFileTypeMode] {
        let values = try await describeCameraPropertyEnum(.movieFileType, valueByteCount: 4)
        return PTPCameraPropertyDecoders.fileTypeModes(fromEnum: values)
    }

    /// Reads a moded control's descriptor enum (`property`, value width `valueByteCount`) and maps it
    /// to picker option labels the body supports — empty if the property isn't an enumeration here.
    /// Used to drive the AF / shutter / WB-preset wheels from the camera rather than hardcoded lists.
    func controlOptions(
        for property: PTPPropertyCode,
        valueByteCount: Int
    ) async throws -> [String] {
        let values = try await describeCameraPropertyEnum(property, valueByteCount: valueByteCount)
        return PTPCameraPropertyDecoders.optionLabels(for: property, rawValues: values)
    }

    func describeCameraPropertyEnum(
        _ property: PTPPropertyCode,
        valueByteCount: Int
    ) async throws -> [UInt32] {
        let result = try await transact(
            operationCode: .getDevicePropDescEx,
            parameters: [property.rawValue],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getDevicePropDescEx,
                result.operationResponse.responseCode
            )
        }
        return PTPCameraPropertyDecoders.devicePropDescEnumValues(
            data: result.data,
            valueByteCount: valueByteCount
        )
    }

    /// Reads the recording card's capacity and free space.
    ///
    /// The ZR is dual-slot and its plain `GetStorageIDs` returns placeholder per-slot IDs (the
    /// "no card" form, low bit 0) even with a card present — `GetStorageInfo` rejects those with
    /// `Store_Not_Available` (why the first attempt failed on a real body). So gather the *valid*
    /// IDs from `GetVendorStorageIDs` (falling back to the standard list), probe each, and return
    /// the first slot holding a card; nil only when no slot answers (empty / all rejected).
    func readStorageInfo() async throws -> PTPStorageInfo? {
        let slots = await readAllStorageInfo()
        return slots.first?.info
    }

    /// Reads capacity and free space for every usable storage slot (dual-slot bodies).
    func readAllStorageInfo() async -> [(id: UInt32, info: PTPStorageInfo)] {
        let usableIDs = await usableStorageIDs()
        guard !usableIDs.isEmpty else {
            storageLogger.error("no usable storage IDs from GetVendorStorageIDs / GetStorageIDs")
            return []
        }

        var results: [(UInt32, PTPStorageInfo)] = []
        for storageID in usableIDs {
            guard
                let infoResult = try? await transact(
                    operationCode: .getStorageInfo,
                    parameters: [storageID],
                    dataPhase: .dataIn
                ), infoResult.operationResponse.responseCode == .ok,
                let info = PTPStorageInfo(Array(infoResult.data))
            else {
                continue
            }
            results.append((storageID, info))
        }
        if results.isEmpty {
            storageLogger.error(
                "no storage slot returned usable info (cards empty or all rejected)")
        }
        return results
    }

    /// Fetches and parses a StorageIDArray via the given op (`GetStorageIDs`/`GetVendorStorageIDs`),
    /// logging the result. Returns [] on rejection so the caller can fall back to the other op.
    private func storageIDList(via operationCode: PTPOperationCode) async -> [UInt32] {
        guard let result = try? await transact(operationCode: operationCode, dataPhase: .dataIn),
            result.operationResponse.responseCode == .ok
        else {
            return []
        }
        return PTPStorageIDs.parse(Array(result.data))
    }

    /// Gathers the *valid* (card-present) storage IDs, preferring `GetVendorStorageIDs` and falling
    /// back to the standard list, de-duplicated and stripped of placeholder/empty IDs. Shared by
    /// `readStorageInfo` (capacity) and `listClips` (object enumeration).
    private func usableStorageIDs() async -> [UInt32] {
        var candidates: [UInt32] = []
        candidates += await storageIDList(via: .getVendorStorageIDs)
        candidates += await storageIDList(via: .getStorageIDs)
        var seen = Set<UInt32>()
        return candidates.filter { $0 != 0 && $0 != 0xFFFF_FFFF && seen.insert($0).inserted }
    }

    // MARK: - Media object browsing (Media page) — [ZR · verify-on-HW]

    /// One movie object discovered on a camera card.
    struct CameraClip: Sendable, Equatable {
        let storageID: UInt32
        let handle: UInt32
        let info: PTPObjectInfo
    }

    /// Lists media object handles across all card slots without per-object `GetObjectInfo` calls.
    func listMediaObjectHandles() async -> [MediaObjectHandle] {
        let storageIDs = await usableStorageIDs()
        var handles: [MediaObjectHandle] = []
        for storageID in storageIDs {
            if Task.isCancelled { break }
            let objectHandles = (try? await getObjectHandles(storageID: storageID)) ?? []
            for handle in objectHandles {
                handles.append(MediaObjectHandle(storageID: storageID, handle: handle))
            }
        }
        mediaLogger.info(
            "listMediaObjectHandles: \(handles.count, privacy: .public) handle(s) across \(storageIDs.count, privacy: .public) slot(s)"
        )
        return handles
    }

    /// Lists media object handles limited to the given PTP object formats — one
    /// `GetObjectHandles(storage, format)` per pair. Unlike the unfiltered variant this
    /// **throws** on rejection (e.g. `Specification_By_Format_Unsupported`), so the caller can
    /// fall back to the full listing instead of mistaking "camera refused the filter" for
    /// "no such clips". [ZR · verify-on-HW]
    func listMediaObjectHandles(formats: [UInt32]) async throws -> [MediaObjectHandle] {
        let storageIDs = await usableStorageIDs()
        var handles: [MediaObjectHandle] = []
        for storageID in storageIDs {
            for format in formats {
                try Task.checkCancellation()
                let objectHandles = try await getObjectHandles(
                    storageID: storageID, format: format)
                for handle in objectHandles {
                    handles.append(MediaObjectHandle(storageID: storageID, handle: handle))
                }
            }
        }
        mediaLogger.info(
            "listMediaObjectHandles(formats: \(formats.count, privacy: .public)) → \(handles.count, privacy: .public) handle(s)"
        )
        return handles
    }

    /// Fetches metadata for one media object — `GetObjectInfo` plus media-library filtering.
    func fetchMediaClip(handle: UInt32, storageID: UInt32) async -> CameraClip? {
        guard let info = try? await getObjectInfo(handle: handle),
            info.isMediaLibraryObject
        else { return nil }
        return CameraClip(storageID: storageID, handle: handle, info: info)
    }

    /// Streams media objects as discovered across all card slots: usable storage IDs →
    /// `GetObjectHandles` → `GetObjectInfo`, yielding playable proxies (MP4/MOV), stills, and R3D
    /// masters for resolution pairing.
    ///
    /// Handles arrive per volume in one round-trip, but each object needs its own `GetObjectInfo`
    /// (metadata only). Yields incrementally so the UI refreshes per clip; serial round-trips
    /// through the transaction gate. Once the ZR's movie object-format code is hardware-confirmed,
    /// pass it as the `GetObjectHandles` `format` filter to skip per-still `GetObjectInfo` calls.
    /// [ZR · verify-on-HW]
    func streamClips() -> AsyncStream<CameraClip> {
        AsyncStream { continuation in
            let task = Task {
                let storageIDs = await usableStorageIDs()
                guard !storageIDs.isEmpty else {
                    mediaLogger.error("streamClips: no usable storage IDs")
                    continuation.finish()
                    return
                }
                var clipCount = 0
                let yieldStride = 16
                for storageID in storageIDs {
                    if Task.isCancelled { break }
                    let handles = (try? await getObjectHandles(storageID: storageID)) ?? []
                    for (index, handle) in handles.enumerated() {
                        if Task.isCancelled { break }
                        guard let info = try? await getObjectInfo(handle: handle),
                            info.isMediaLibraryObject
                        else { continue }
                        let clip = CameraClip(storageID: storageID, handle: handle, info: info)
                        clipCount += 1
                        continuation.yield(clip)
                        if index % yieldStride == yieldStride - 1 {
                            await Task.yield()
                        }
                    }
                }
                mediaLogger.info(
                    "streamClips: \(clipCount, privacy: .public) media object(s) across \(storageIDs.count, privacy: .public) slot(s)"
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects all movie clips from `streamClips()` — convenience when incremental delivery is not
    /// needed.
    func listClips() async throws -> [CameraClip] {
        var clips: [CameraClip] = []
        for await clip in streamClips() { clips.append(clip) }
        return clips
    }

    /// Lists object handles on a storage volume — `GetObjectHandles` (0x1007). `format` filters by
    /// object-format code (0 = all formats); `association` scopes to a folder (0 = all). A
    /// GetObjectHandles dataset is a PTP UINT32 array — byte-identical to a StorageID array — so it
    /// decodes with `PTPStorageIDs.parse`. Wire behaviour is unverified — [ZR · verify-on-HW].
    func getObjectHandles(
        storageID: UInt32,
        format: UInt32 = 0,
        association: UInt32 = 0
    ) async throws -> [UInt32] {
        let result = try await transact(
            operationCode: .getObjectHandles,
            parameters: [storageID, format, association],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getObjectHandles, result.operationResponse.responseCode)
        }
        let handles = PTPStorageIDs.parse(Array(result.data))
        mediaLogger.info(
            "GetObjectHandles(0x\(String(format: "%08X", storageID), privacy: .public)) → \(handles.count, privacy: .public) handles"
        )
        return handles
    }

    /// Reads one object's metadata — `GetObjectInfo` (0x1008), decoded by `PTPObjectInfo`.
    /// [ZR · verify-on-HW]
    func getObjectInfo(handle: UInt32) async throws -> PTPObjectInfo {
        let result = try await transact(
            operationCode: .getObjectInfo,
            parameters: [handle],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getObjectInfo, result.operationResponse.responseCode)
        }
        return try PTPObjectInfo(result.data)
    }

    /// Reads the camera's embedded thumbnail for one object — `GetThumb` (0x100A). Returns nil when
    /// the camera reports no thumbnail (e.g. `NoThumbnailPresent`). [ZR · verify-on-HW]
    func getThumb(handle: UInt32) async throws -> Data? {
        let result = try await transact(
            operationCode: .getThumb,
            parameters: [handle],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else { return nil }
        return result.data.isEmpty ? nil : result.data
    }

    /// Reads a byte range of one object — `GetPartialObject` (0x101B): p1=handle, p2=offset,
    /// p3=maxBytes. Offset/length are 32-bit here; clips ≥ 4 GiB need NIKON `GetPartialObjectEx`
    /// 0x9431 (64-bit). Returns the chunk (may be shorter than `length` at end-of-object).
    /// [ZR · verify-on-HW]
    func getPartialObject(handle: UInt32, offset: UInt32, length: UInt32) async throws -> Data {
        let result = try await transact(
            operationCode: .getPartialObject,
            parameters: [handle, offset, length],
            dataPhase: .dataIn
        )
        guard result.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getPartialObject, result.operationResponse.responseCode)
        }
        return result.data
    }

    /// Lightweight keep-alive: a side-effect-free `DeviceReady` through the transaction gate (so it
    /// can't interleave with other PTP traffic), keeping an idle command channel warm — e.g. live
    /// view paused in command mode — so Wi-Fi / iPhone-hotspot NAT doesn't drop the TCP session.
    /// Still a full PTP round-trip (a `Device_Busy` reply counts as a live channel) but, unlike
    /// `GetDeviceInfo`, the camera sends no multi-KB blob — a shorter radio-awake window per ping.
    /// Throws if the channel is already dead, so the caller can log it.
    func sendKeepAlive() async throws {
        let startedAt = Date()
        _ = try await transact(operationCode: .deviceReady)
        recordCommandRoundTrip(startedAt: startedAt)
    }

    private func openAndIdentify(
        requestPairing: Bool,
        onPairingChallenge: NativePairingChallengeHandler?,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> NativeCameraSession {
        // Over USB the first transaction can sit behind ImageCaptureCore's own card enumeration,
        // which scales with card fullness (thousands of stills = minutes, not seconds) — the 15 s
        // wedge backstop would mistake that wait for a dead camera. Wi-Fi keeps the short deadline.
        // [verify-on-HW: ZR over USB-C with a full card]
        onStage?("first command (OpenSession)")
        let open = try await transact(
            operationCode: .openSession,
            transactionID: 0,
            parameters: [1],
            deadline: transport.kind == .usb ? .seconds(180) : Self.commandTransactionTimeout
        )
        // `Session_Already_Open` is success: over USB, ImageCaptureCore opens the PTP session
        // itself before handing the device to the app. [VERIFY-ON-HW] on the ZR over USB-C.
        let openResponse = open.operationResponse.responseCode
        guard openResponse == .ok || openResponse == .sessionAlreadyOpen else {
            throw NativeCameraSessionError.operationRejected(.openSession, openResponse)
        }

        // USB has no pairing surface: GetPairingInfo/ConfirmPairing are absent from the camera's
        // USB OperationsSupported, so polling them only times the connect out — the cable itself is
        // the trust boundary. [verify-on-HW: ZR over USB-C]
        let isUSB = transport.kind == .usb
        if requestPairing, !isUSB {
            onStage?("pairing")
            try await completePairing(onPairingChallenge: onPairingChallenge)
        } else {
            establishmentSummary += isUSB ? "pairing=usb " : "pairing=skipped "
        }
        onStage?("app-control switch")
        var appModeResponse = try await enableCameraControl()
        if isUSB, appModeResponse != .ok {
            // Over USB the ZR boots into PC-camera mode and denies the vendor app-control switch
            // that Wi-Fi sessions get for free. Remote mode is accepted and unlocks control, though
            // the camera body stays on its "Connected to computer" screen.
            // [verify-on-HW: ZR over USB-C, 2026-07-17 — connects, streams, full metadata]
            onStage?("remote-mode fallback")
            let remote = try await transact(operationCode: .changeCameraMode, parameters: [1])
            let remoteResponse = remote.operationResponse.responseCode
            establishmentSummary += "remoteMode=0x\(String(remoteResponse.rawValue, radix: 16)) "
            if remoteResponse == .ok { appModeResponse = .ok }
        }
        if !requestPairing {
            guard
                PTPIPSavedProfileProbePolicy.resolve(
                    applicationModeResponse: appModeResponse
                ) == .accepted
            else {
                throw NativeCameraSessionError.savedProfileRequired
            }
        }

        onStage?("device info")
        let infoResult = try await transact(operationCode: .getDeviceInfo, dataPhase: .dataIn)
        guard infoResult.operationResponse.responseCode == .ok else {
            throw NativeCameraSessionError.operationRejected(
                .getDeviceInfo,
                infoResult.operationResponse.responseCode
            )
        }
        let info = try PTPDeviceInfo(data: infoResult.data)
        let updatedIdentity = NativeCameraIdentity(
            host: host,
            cameraName: cameraName ?? info.model,
            manufacturer: info.manufacturer,
            model: info.model,
            deviceVersion: info.deviceVersion,
            serialNumber: info.serialNumber,
            establishmentSummary: establishmentSummary.trimmingCharacters(in: .whitespaces)
        )
        return NativeCameraSession(
            host: host,
            transport: transport,
            cameraName: cameraName,
            establishmentSummary: establishmentSummary.trimmingCharacters(in: .whitespaces),
            identity: updatedIdentity
        )
    }

    private func completePairing(onPairingChallenge: NativePairingChallengeHandler?) async throws {
        let challenge = try await waitForPairingChallenge()

        if let onPairingChallenge {
            let accepted = await onPairingChallenge(challenge)
            guard accepted else { throw NativeCameraSessionError.pairingRejected }
        }

        do {
            let confirm = try await transact(
                operationCode: .confirmPairing,
                parameters: [PTPIPSessionScript.pairingConfirmValue]
            )
            establishmentSummary +=
                "pairConfirm=0x\(String(confirm.operationResponse.responseCode.rawValue, radix: 16)) "
            guard confirm.operationResponse.responseCode == .ok else {
                throw NativeCameraSessionError.operationRejected(
                    .confirmPairing,
                    confirm.operationResponse.responseCode
                )
            }
        } catch {
            establishmentSummary += "pairConfirm=err "
            throw error
        }
    }

    private func waitForPairingChallenge() async throws -> PTPIPPairingChallenge {
        var lastError: Error?
        for attempt in 1...10 {
            do {
                let pairInfo = try await transact(
                    operationCode: .getPairingInfo,
                    dataPhase: .dataIn
                )
                let responseHex = String(
                    pairInfo.operationResponse.responseCode.rawValue, radix: 16)
                establishmentSummary += "pairInfo\(attempt)=0x\(responseHex) "
                let result = PTPIPPairingInfoPolicy.resolve(
                    response: pairInfo.operationResponse.responseCode,
                    byteCount: pairInfo.data.count
                )
                connectionLogger.debug(
                    "pairInfo poll=\(attempt, privacy: .public) response=0x\(responseHex, privacy: .public) bytes=\(pairInfo.data.count, privacy: .public) result=\(String(describing: result), privacy: .public)"
                )
                if result == .promptUser {
                    let parsedChallenge = PTPIPPairingChallenge(
                        data: pairInfo.data,
                        cameraName: cameraName
                    )
                    establishmentSummary += "pairData=redacted "
                    connectionLogger.debug(
                        "pairing challenge found pin=*** bytes=\(pairInfo.data.count, privacy: .public)"
                    )
                    return parsedChallenge
                }
            } catch {
                lastError = error
                establishmentSummary += "pairInfo\(attempt)=err "
                connectionLogger.debug(
                    "pairInfo poll=\(attempt, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if let lastError {
            establishmentSummary += "pairInfoLastError=\(lastError.localizedDescription) "
        }
        connectionLogger.notice("pairing challenge unavailable after 10 polls")
        throw NativeCameraSessionError.pairingChallengeUnavailable
    }

    private func enableCameraControl() async throws -> PTPResponseCode {
        let appMode = try await transact(operationCode: .changeApplicationMode, parameters: [1])
        let appModeResponse = appMode.operationResponse.responseCode
        establishmentSummary +=
            "appMode=0x\(String(appMode.operationResponse.responseCode.rawValue, radix: 16)) "

        do {
            let rec = try await transact(
                operationCode: .getDevicePropValueEx,
                parameters: [PTPPropertyCode.movieRecProhibitionCondition.rawValue],
                dataPhase: .dataIn
            )
            let value =
                rec.data.count >= 4
                ? ByteCoding.readUInt32LE(Array(rec.data), at: 0)
                : UInt32.max
            establishmentSummary += "recProhib=0x\(String(value, radix: 16)) "
        } catch {
            establishmentSummary += "recProhib=err "
        }
        return appModeResponse
    }

    private func setLiveViewByte(label: String, property: PTPPropertyCode, value: UInt8) async {
        do {
            let result = try await transact(
                operationCode: .setDevicePropValueEx,
                parameters: [property.rawValue],
                dataPhase: .dataOut,
                dataOut: Data([value])
            )
            establishmentSummary +=
                "\(label)=0x\(String(result.operationResponse.responseCode.rawValue, radix: 16)) "
        } catch {
            establishmentSummary += "\(label)=err "
        }
    }

    /// Default whole-transaction deadline for command transactions. A healthy command completes in
    /// well under a second; this is the backstop that stops a wedged or byte-dribbling camera from
    /// holding the transport's transaction gate — and thus blocking record-stop, AF, and every
    /// other command — indefinitely.
    private static let commandTransactionTimeout: Duration = .seconds(15)

    private func transact(
        operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32? = nil,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil,
        deadline: Duration? = commandTransactionTimeout
    ) async throws -> PTPIPTransactionResult {
        try await transport.executeTransaction(
            operationCode: operationCode,
            transactionID: explicitTransactionID,
            parameters: parameters,
            dataPhase: dataPhase,
            dataOut: dataOut,
            deadline: deadline
        )
    }
}
