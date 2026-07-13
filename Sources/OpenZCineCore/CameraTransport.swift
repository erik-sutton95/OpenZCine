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
