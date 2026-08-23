import Foundation

/// The physical link kind carrying a camera-control session.
public enum CameraTransportKind: String, Equatable, Sendable {
    /// PTP-IP over Wi-Fi / Ethernet (CIPA DC-005, TCP port 15740).
    case ptpIP
    /// USB-C tethered PTP/MTP (PIMA 15740 generic containers over the USB bulk pipe).
    case usb

    /// User-facing transport label stored on saved camera records.
    public var savedRecordLabel: String {
        switch self {
        case .ptpIP: "Wi-Fi"
        case .usb: PTPIPSavedCameraRecord.usbTransportLabel
        }
    }
}

/// A transaction-level camera transport.
///
/// One call to `executeTransaction` performs a complete PTP operation: the operation request, an
/// optional host-to-camera data phase (`dataOut`), any camera-to-host data phase, and the operation
/// response. The boundary is transaction-level (not packet-level) because iOS USB access via
/// ImageCaptureCore only exposes whole PTP transactions; PTP-IP packet framing and socket details
/// stay inside the conforming transport.
///
/// Conformers own transaction-ID assignment and must serialize transactions internally so callers
/// can issue them from any task without interleaving.
public protocol CameraTransport: Sendable {
    /// The link kind this transport speaks.
    var kind: CameraTransportKind { get }

    /// Executes one full PTP transaction and returns the response plus any data-in payload.
    ///
    /// - Parameters:
    ///   - operationCode: PTP operation to run.
    ///   - transactionID: Explicit transaction-ID override (`OpenSession` must use 0); `nil`
    ///     assigns the transport's next sequential ID.
    ///   - parameters: Up to five UINT32 request parameters.
    ///   - dataPhase: The request's data-phase discriminator.
    ///   - dataOut: Host-to-camera payload for data-out operations.
    ///   - deadline: Whole-transaction timeout; `nil` disables it (hot paths such as the
    ///     live-view frame loop provide their own watchdog).
    func executeTransaction(
        operationCode: PTPOperationCode,
        transactionID: UInt32?,
        parameters: [UInt32],
        dataPhase: PTPDataPhase,
        dataOut: Data?,
        deadline: Duration?
    ) async throws -> PTPIPTransactionResult

    /// Waits for the next camera-pushed PTP event.
    ///
    /// Transports may throw a timeout error while the channel is idle; callers treat that as
    /// benign and call again. Any other error means the link is gone.
    func nextEvent() async throws -> PTPEvent

    /// Tears the transport down. Safe to call more than once.
    func close()
}

/// Next action for opening an ImageCaptureCore session on iOS USB.
///
/// ICC owns the PTP session: attach-time pre-warm may already have it open, and a
/// retry after a failed first command must close that session for real before
/// requesting a new one. Adopting a session that `requestCloseSession` did not
/// actually close is how a cable-knock / background return stayed dead until
/// force-quit (#254).
public enum USBICCSessionOpenDecision: Equatable, Sendable {
    /// Attach-time `requestOpenSession` is still in flight — wait, do not duplicate it.
    case waitForPrewarm
    /// A previous connect parked a live session; take it over.
    case adoptExisting
    /// The retry path: close the adopted session, then open fresh.
    case recycleThenOpen
    /// Recycle ran, but ICC still reports the session open — do not adopt the corpse.
    case failStillOpenAfterRecycle
    /// No open session; issue `requestOpenSession`.
    case requestOpen
}

/// Pure decision table for the iOS USB transport's session-open path.
public enum USBICCSessionOpenPolicy {
    public static func decision(
        hasOpenSession: Bool,
        prewarmInFlight: Bool,
        recycleFirst: Bool,
        recycleCompleted: Bool
    ) -> USBICCSessionOpenDecision {
        if prewarmInFlight, !hasOpenSession {
            return .waitForPrewarm
        }
        if recycleFirst, hasOpenSession, !recycleCompleted {
            return .recycleThenOpen
        }
        if recycleFirst, hasOpenSession, recycleCompleted {
            return .failStillOpenAfterRecycle
        }
        if hasOpenSession {
            return .adoptExisting
        }
        return .requestOpen
    }
}

/// Closed USB handshake tokens for the privacy-safe diagnostic export.
///
/// Raw values match the Android anonymous-log vocabulary so a field report names
/// the same step on either shell (accessory discovery stays `usb.camera.attached`;
/// live-view setup stays `live-view.failed`).
public enum USBHandshakeDiagnostic: String, Sendable {
    case sessionOpen = "usb.session.open"
    case deviceInfo = "usb.handshake.device-info"
    case openSession = "usb.handshake.open-session"
    case appMode = "usb.handshake.app-mode"
    case identify = "usb.handshake.identify"

    /// Maps an establish `stage:` string (or the bare stage id) onto a closed token.
    /// Unknown or free-form text — camera names, raw ICC errors — returns `nil`.
    public static func from(stage raw: String) -> USBHandshakeDiagnostic? {
        var stage = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stage.lowercased().hasPrefix("stage:") {
            stage = String(stage.dropFirst("stage:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = stage.lowercased()
        guard !key.isEmpty else { return nil }
        if key.contains("capability probe") { return .deviceInfo }
        if key.contains("first command") || key.contains("opensession") { return .openSession }
        if key.contains("app-control") || key.contains("remote-mode") { return .appMode }
        if key == "device info" || key.contains("vendor") { return .identify }
        if key.contains("session") && key.contains("open") { return .sessionOpen }
        return nil
    }
}
