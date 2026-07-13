import Foundation
import ImageCaptureCore
import os

private let usbLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-usb"
)

/// Enumerates USB-attached PTP cameras via ImageCaptureCore's `ICDeviceBrowser` and vends the
/// live `ICCameraDevice` for a discovered host key. The discovery loop polls `attachedCameras()`,
/// so plugging a camera in surfaces it on the next pass (effectively instantly).
// SAFETY: `@unchecked Sendable` — `devices` and `authorizationStatus` are guarded by `lock`
// (`NSLock`); ICDeviceBrowser delegate callbacks and readers never touch them off it.
final class USBCameraDeviceBrowser: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    static let shared = USBCameraDeviceBrowser()

    private let browser = ICDeviceBrowser()
    private let lock = NSLock()
    private var devices: [ICCameraDevice] = []
    private var isStarted = false
    private var authorizationStatus: ICAuthorizationStatus = .notDetermined

    /// Starts device browsing, requesting camera-control authorization first when it has not been
    /// determined yet. Idempotent. Must be called after first render — requesting the ICC
    /// authorization too early in launch is a known hang.
    func start() {
        lock.lock()
        let alreadyStarted = isStarted
        isStarted = true
        lock.unlock()
        guard !alreadyStarted else { return }

        browser.delegate = self
        let status = browser.controlAuthorizationStatus
        setAuthorizationStatus(status)
        if status == .notDetermined {
            browser.requestControlAuthorization { [weak self] granted in
                guard let self else { return }
                self.setAuthorizationStatus(granted)
                usbLogger.info(
                    "USB control authorization resolved: \(granted.rawValue, privacy: .public)")
                self.browser.start()
            }
        } else {
            browser.start()
        }
    }

    /// Whether iOS has denied camera-control access (drives the permission-recovery copy).
    var isControlAuthorizationDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Snapshot of currently attached USB cameras as discovery entries.
    func attachedCameras() -> [DiscoveredCamera] {
        currentDevices().map { device in
            DiscoveredCamera(
                ip: Self.hostKey(for: device),
                name: device.name,
                source: .usb
            )
        }
    }

    /// Resolves the live device for a `usb:<device-id>` host key, if it is still attached.
    func device(forHostKey hostKey: String) -> ICCameraDevice? {
        guard let normalized = PTPIPPairedHosts.normalizedHost(hostKey) else { return nil }
        return currentDevices().first {
            PTPIPPairedHosts.normalizedHost(Self.hostKey(for: $0)) == normalized
        }
    }

    /// Stable `usb:<device-id>` host key for a device — the saved-record identity for USB cameras.
    /// Prefers ICC's device UUID (the only stable identifier ICC exposes on iOS), falling back to
    /// the device name.
    static func hostKey(for device: ICDevice) -> String {
        let identifier = device.uuidString ?? device.name ?? "unknown"
        return DiscoveredCamera.usbHostKeyPrefix + identifier
    }

    private func currentDevices() -> [ICCameraDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices
    }

    private func setAuthorizationStatus(_ status: ICAuthorizationStatus) {
        lock.lock()
        authorizationStatus = status
        lock.unlock()
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        lock.lock()
        if !devices.contains(where: { $0 === camera }) {
            devices.append(camera)
        }
        lock.unlock()
        usbLogger.info(
            "USB camera attached: \(device.name ?? "unnamed", privacy: .private(mask: .hash))")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lock.lock()
        devices.removeAll { $0 === device }
        lock.unlock()
        usbLogger.info(
            "USB camera detached: \(device.name ?? "unnamed", privacy: .private(mask: .hash))")
    }
}

/// USB-C camera transport over ImageCaptureCore: `requestSendPTPCommand` maps one call onto one
/// PTP transaction (PIMA 15740 generic containers), and `didReceivePTPEvent` delegate callbacks
/// feed the event channel. ICC owns the USB endpoints and the underlying PTP session; unplugging
/// the cable surfaces as `connectionClosed` on the next transaction or event read.
// SAFETY: `@unchecked Sendable` — mutable state (`nextTransactionID`, continuations, event
// buffer) is guarded by `lock`; transactions are serialized by `transactionGate`.
final class USBCameraTransport: NSObject, CameraTransport, ICCameraDeviceDelegate,
    @unchecked Sendable
{
    init(device: ICCameraDevice) {
        self.device = device
        let (stream, continuation) = AsyncStream<PTPEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        eventStreamIterator = stream.makeAsyncIterator()
        eventContinuation = continuation
        super.init()
    }

    let device: ICCameraDevice

    var kind: CameraTransportKind { .usb }

    /// Stable `usb:<device-id>` host key for this transport's device.
    var hostKey: String { USBCameraDeviceBrowser.hostKey(for: device) }

    private let transactionGate = AsyncSerialGate()
    private let lock = NSLock()
    private var nextTransactionID: UInt32 = 1
    private var isClosed = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var didOpenSession = false
    private var didBecomeReady = false
    // Events are pushed by delegate callbacks and pulled by the session's drain loop (a single
    // consumer), buffered so a sparse reader never loses a record start/stop notification.
    private var eventStreamIterator: AsyncStream<PTPEvent>.AsyncIterator
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation

    /// Opens the ICC session and resumes as soon as the session is open (see `resumeOpenIfReady`) —
    /// deliberately NOT waiting for the content-catalog "ready" signal, which for the ZR is the slow
    /// part of USB connect. ImageCaptureCore still enumerates the catalog in the background; the app
    /// ignores it.
    func open(timeout: Duration = .seconds(30)) async throws {
        device.delegate = self
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeOpen(
                throwing: NativeCameraSessionError.timeout("USB camera session open"))
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            openContinuation = continuation
            lock.unlock()
            device.requestOpenSession()
        }
    }

    func executeTransaction(
        operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32?,
        parameters: [UInt32],
        dataPhase: PTPDataPhase,
        dataOut: Data?,
        deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        // Throws `CancellationError` if this task is cancelled while queued — the gate was never
        // acquired, so no `signal()` (the defer below is only registered after acquisition).
        try await transactionGate.wait()
        defer { transactionGate.signal() }
        try Task.checkCancellation()

        let (closed, transactionID) = claimTransactionID(explicit: explicitTransactionID)
        guard !closed else { throw NativeCameraSessionError.connectionClosed }

        // The USB command container has no DataPhaseInfo field (PTP-IP-specific); ICC infers the
        // data direction from `outData` and the operation itself.
        _ = dataPhase
        let command = PTPUSBTransaction.commandContainer(
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters
        )

        // Resume-once box: ICC's completion has no cancellation, so on deadline breach we resume
        // with a timeout and let the eventual completion fall into the already-resumed box.
        let box = OneShotResultContinuation()
        return try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
            let deadlineTask: Task<Void, Never>? = deadline.map { limit in
                Task {
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    box.resume(
                        throwing: NativeCameraSessionError.timeout(
                            "USB \(String(describing: operationCode)) transaction"))
                }
            }
            device.requestSendPTPCommand(command, outData: dataOut) { first, second, error in
                defer { deadlineTask?.cancel() }
                if let error {
                    box.resume(throwing: error)
                    return
                }
                // [VERIFY-ON-HW] ICC's completion argument order is inconsistently documented
                // (response/data vs command/data/response echoes), so identify the response
                // container by shape instead of position.
                do {
                    box.resume(
                        returning: try Self.decodeTransaction(
                            operationCode: operationCode, first: first, second: second))
                } catch {
                    box.resume(throwing: error)
                }
            }
        }
    }

    func nextEvent() async throws -> PTPEvent {
        guard let event = await eventStreamIterator.next() else {
            throw NativeCameraSessionError.connectionClosed
        }
        return event
    }

    func close() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        eventContinuation.finish()
        resumeOpen(throwing: NativeCameraSessionError.connectionClosed)
        device.requestCloseSession()
        device.delegate = nil
    }

    /// Identifies which completion blob is the response container and decodes the pair.
    private static func decodeTransaction(
        operationCode: PTPOperationCode,
        first: Data,
        second: Data
    ) throws -> PTPIPTransactionResult {
        if let result = try? PTPUSBTransaction.result(
            operationCode: operationCode, responseBytes: second, dataBytes: first)
        {
            return result
        }
        return try PTPUSBTransaction.result(
            operationCode: operationCode, responseBytes: first, dataBytes: second)
    }

    /// Atomically checks the closed flag and assigns the next transaction ID (synchronous, so it
    /// can lock safely when called from async contexts).
    private func claimTransactionID(explicit: UInt32?) -> (isClosed: Bool, transactionID: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        let transactionID = explicit ?? nextTransactionID
        if explicit == nil {
            nextTransactionID += 1
        }
        return (isClosed, transactionID)
    }

    private func resumeOpen(throwing error: Error) {
        lock.lock()
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func resumeOpenIfReady() {
        lock.lock()
        // Resume as soon as the SESSION is open — do NOT wait for `didBecomeReady`. That readiness
        // signal is `deviceDidBecomeReady(withCompleteContentCatalog:)`, which ICC fires only after
        // enumerating the ENTIRE card — a catalog this app never uses (media listing is our own PTP
        // `GetObjectHandles`; the `ICCameraItem` delegates below are empty). Blocking `open()` on
        // it made USB "Connecting" scale with card fullness; passthrough `requestSendPTPCommand`
        // needs only an open session, so gate on `didOpenSession` alone. [VERIFY-ON-HW: confirm
        // the first GetDeviceInfo transaction succeeds immediately after session-open on the ZR.]
        let ready = didOpenSession
        let continuation = ready ? openContinuation : nil
        if ready { openContinuation = nil }
        lock.unlock()
        continuation?.resume()
    }

    // MARK: - ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            usbLogger.error(
                "USB session open failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            resumeOpen(
                throwing: NativeCameraSessionError.connectionFailed(
                    "The camera refused the USB session: \(error.localizedDescription)"))
            return
        }
        lock.lock()
        didOpenSession = true
        lock.unlock()
        resumeOpenIfReady()
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        lock.lock()
        didBecomeReady = true
        lock.unlock()
        resumeOpenIfReady()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        close()
    }

    func didRemove(_ device: ICDevice) {
        // Unplugged: end the event stream (the drain loop surfaces connectionClosed) and fail
        // any in-flight open.
        close()
    }

    // MARK: - ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        lock.lock()
        didBecomeReady = true
        lock.unlock()
        resumeOpenIfReady()
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard let event = try? PTPUSBTransaction.event(from: eventData) else {
            usbLogger.debug(
                "Unparsable USB PTP event (\(eventData.count, privacy: .public) bytes)")
            return
        }
        eventContinuation.yield(event)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?)
    {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// Resume-once wrapper for a transaction continuation racing a deadline.
// SAFETY: `@unchecked Sendable` — the stored continuation is guarded by `lock` (`NSLock`).
private final class OneShotResultContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PTPIPTransactionResult, Error>?

    func store(_ continuation: CheckedContinuation<PTPIPTransactionResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: PTPIPTransactionResult) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<PTPIPTransactionResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let output = continuation
        continuation = nil
        return output
    }
}
