import AccessorySetupKit
import Foundation
import NetworkExtension
import OpenZCineCore
import UIKit
import os

/// Wi‑Fi camera pairing via Apple's AccessorySetupKit (iOS 18+).
///
/// Presents the system accessory picker (product image + device name) for Nikon Z hotspots, then
/// joins with `joinAccessoryHotspot` / `joinAccessoryHotspotWithoutSecurity`.
/// See WWDC24 session 10203 and ``ASAccessorySession``.
@available(iOS 18.0, *)
@MainActor
final class AccessorySetupWiFiCoordinator {
    private static let logger = Logger(subsystem: "OpenZCine", category: "ask-wifi")
    static let shared = AccessorySetupWiFiCoordinator()

    enum JoinError: LocalizedError {
        case userDenied
        case invalidSSID
        case timedOut
        case pickerFailed(String)
        case joinFailed(String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .userDenied:
                return "Join the camera Wi‑Fi network to continue."
            case .invalidSSID:
                return "Couldn't identify the camera Wi‑Fi network."
            case .timedOut:
                return "Timed out waiting for the camera Wi‑Fi network. Try again."
            case .pickerFailed(let message):
                return message
            case .joinFailed(let message):
                return message
            case .unavailable:
                return "Accessory setup is unavailable."
            }
        }

        /// Whether ``WiFiJoinCoordinator`` may fall back to `NEHotspotConfiguration.apply`.
        var allowsHotspotConfigurationFallback: Bool {
            switch self {
            case .userDenied, .joinFailed:
                return false
            case .invalidSSID, .timedOut, .pickerFailed, .unavailable:
                return true
            }
        }
    }

    struct Accessory {
        var ssid: String?
        var authorized: Bool
        var native: ASAccessory?
    }
    enum Event {
        case activated
        case accessoryAdded(Accessory)
        case pickerDidDismiss
        case pickerSetupFailed(String)
        case invalidated
    }
    struct Native {
        var activate: (@escaping @MainActor (Event) -> Void) -> Void
        var accessories: () -> [Accessory]
        var showPicker: ([ASPickerDisplayItem], @escaping @MainActor (Error?) -> Void) -> Void
        var join: (Accessory, String?) async throws -> Void
        var invalidate: () -> Void
        var localAddresses: () -> [String]
        var currentSSID: () async -> String?

        static func live() -> Self {
            let session = ASAccessorySession()
            return Self(
                activate: { handler in
                    session.activate(on: .main) { event in
                        Task { @MainActor in
                            switch event.eventType {
                            case .activated: handler(.activated)
                            case .accessoryAdded:
                                if let accessory = event.accessory {
                                    handler(
                                        .accessoryAdded(
                                            .init(
                                                ssid: accessory.ssid,
                                                authorized: accessory.state == .authorized,
                                                native: accessory)))
                                }
                            case .pickerDidDismiss: handler(.pickerDidDismiss)
                            case .pickerSetupFailed:
                                handler(
                                    .pickerSetupFailed(
                                        event.error?.localizedDescription
                                            ?? "Accessory setup failed."))
                            case .invalidated: handler(.invalidated)
                            default: break
                            }
                        }
                    }
                },
                accessories: {
                    session.accessories.map {
                        .init(ssid: $0.ssid, authorized: $0.state == .authorized, native: $0)
                    }
                },
                showPicker: { items, completion in
                    session.showPicker(for: items) { error in
                        Task { @MainActor in completion(error) }
                    }
                },
                join: { accessory, password in
                    guard let accessory = accessory.native else { throw JoinError.unavailable }
                    if let password, !password.isEmpty {
                        try await NEHotspotConfigurationManager.shared.joinAccessoryHotspot(
                            accessory, passphrase: password)
                    } else {
                        try await NEHotspotConfigurationManager.shared
                            .joinAccessoryHotspotWithoutSecurity(accessory)
                    }
                }, invalidate: { session.invalidate() },
                localAddresses: { NativeNetworkInterfaceSnapshot.localIPv4Addresses() },
                currentSSID: { await NativeNetworkInterfaceSnapshot.currentWiFiSSID() })
        }
    }

    private let makeNative: () -> Native
    /// The current native session; nil once retired, until the next join installs a fresh one.
    private var session: Native?
    /// Advances when a session is installed or retired, so a retired session's late events
    /// (accessoryAdded, pickerDidDismiss, invalidated) never reach its successor.
    private var sessionID = 0
    private var isActivated = false
    private var activationWaiters: [CheckedContinuation<Void, Error>] = []
    private var pickerWaiter: CheckedContinuation<Accessory, Error>?
    /// The picker attempt `pickerWaiter` belongs to; a cancelled attempt resolves only its own.
    private final class PickerAttempt: Sendable {}
    private var currentPicker: PickerAttempt?
    private var pendingPickedAccessory: Accessory?

    init(makeNative: @escaping () -> Native = Native.live) {
        self.makeNative = makeNative
        installSession()
    }

    /// A fresh native session whose events alone reach this coordinator.
    @discardableResult private func installSession() -> Native {
        sessionID += 1
        let id = sessionID
        isActivated = false
        let fresh = makeNative()
        session = fresh
        fresh.activate { [weak self] event in
            guard let self, self.sessionID == id else { return }
            self.handleSessionEvent(event)
        }
        return fresh
    }

    private var native: Native { session ?? installSession() }

    /// Ends a session whose picker was cancelled: invalidation stops its operations, and its late
    /// events are ignored, so the next picker runs on a new session. Authorized accessories and
    /// saved credentials are untouched (no accessory removal).
    private func retireSession() {
        guard let retiring = session else { return }
        sessionID += 1
        session = nil
        isActivated = false
        retiring.invalidate()
    }

    /// Joins a camera network by exact SSID using the system accessory picker when needed.
    func joinCameraNetwork(ssid rawSSID: String, password: String?) async throws {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { throw JoinError.invalidSSID }

        if await isOnCameraNetwork() { return }

        let accessory = try await resolveAccessory(ssid: ssid)
        try await joinAuthorizedAccessory(accessory, password: password)
        try Task.checkCancellation()
        try await waitForCameraNetwork(expectedSSID: ssid, timeout: 45)
    }

    /// Joins the first authorized nearby network whose SSID starts with `ssidPrefix`.
    func joinCameraNetwork(ssidPrefix rawPrefix: String, password: String?) async throws {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { throw JoinError.invalidSSID }

        if await isOnCameraNetwork() { return }

        let accessory = try await resolveAccessory(ssidPrefix: prefix)
        let resolvedPassword =
            password
            ?? accessory.ssid.flatMap { CameraWiFiCredentialStore.password(forSSID: $0) }
            ?? CameraWiFiCredentialStore.password(forPrefix: prefix)
        try await joinAuthorizedAccessory(accessory, password: resolvedPassword)
        try Task.checkCancellation()
        try await waitForCameraSubnet(timeout: 45)
    }

    // MARK: - Accessory resolution

    private func resolveAccessory(ssid: String) async throws -> Accessory {
        try await ensureActivated()
        if let existing = authorizedAccessory(matchingSSID: ssid) {
            return existing
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.ssid = ssid
        return try await presentPicker(descriptor: descriptor, displayName: "Nikon camera")
    }

    private func resolveAccessory(ssidPrefix: String) async throws -> Accessory {
        try await ensureActivated()
        if let existing = authorizedAccessory(matchingPrefix: ssidPrefix) {
            return existing
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.ssidPrefix = ssidPrefix
        return try await presentPicker(descriptor: descriptor, displayName: "Nikon camera")
    }

    private func authorizedAccessory(matchingSSID ssid: String) -> Accessory? {
        native.accessories().first {
            $0.authorized && $0.ssid == ssid
        }
    }

    private func authorizedAccessory(matchingPrefix prefix: String) -> Accessory? {
        native.accessories().first {
            guard $0.authorized, let ssid = $0.ssid else { return false }
            return ssid.hasPrefix(prefix)
        }
    }

    private func presentPicker(
        descriptor: ASDiscoveryDescriptor,
        displayName: String
    ) async throws -> Accessory {
        guard let productImage = Self.productImage else {
            throw JoinError.unavailable
        }

        let item = ASPickerDisplayItem(
            name: displayName,
            productImage: productImage,
            descriptor: descriptor
        )

        // Cancellation MUST resume the waiter: the phase watchdog and operator cancels end the
        // connect attempt by cancelling its task, and an unresumed continuation latched
        // `pickerWaiter` forever (every later Wi-Fi join then failed instantly with
        // "Accessory picker is already active." until an app restart). It resumes as
        // cancellation, never as a picker failure, so no hotspot fallback runs after it.
        let attempt = PickerAttempt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pickerWaiter == nil else {
                    continuation.resume(
                        throwing: JoinError.pickerFailed("Accessory picker is already active."))
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pickerWaiter = continuation
                currentPicker = attempt
                pendingPickedAccessory = nil

                native.showPicker([item]) { error in
                    guard self.currentPicker === attempt else { return }
                    if let error { self.failPicker(.pickerFailed(error.localizedDescription)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelPicker(attempt) }
        }
    }

    private func cancelPicker(_ attempt: PickerAttempt) {
        guard currentPicker === attempt, let waiter = pickerWaiter else { return }
        pickerWaiter = nil
        currentPicker = nil
        pendingPickedAccessory = nil
        // The picker may still be on screen; its dismissal belongs to the retired session.
        retireSession()
        waiter.resume(throwing: CancellationError())
    }

    // MARK: - Hotspot join

    private func joinAuthorizedAccessory(_ accessory: Accessory, password: String?) async throws {
        do {
            try await native.join(accessory, password)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error(
                "joinAccessoryHotspot failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw JoinError.joinFailed(error.localizedDescription)
        }
    }

    // MARK: - Session events

    private func handleSessionEvent(_ event: Event) {
        switch event {
        case .activated:
            isActivated = true
            resumeActivationWaiters()
        case .accessoryAdded(let accessory):
            pendingPickedAccessory = accessory
        case .pickerDidDismiss:
            if let accessory = pendingPickedAccessory {
                pendingPickedAccessory = nil
                pickerWaiter?.resume(returning: accessory)
                pickerWaiter = nil
                currentPicker = nil
            } else {
                failPicker(.userDenied)
            }
        case .pickerSetupFailed(let message):
            failPicker(.pickerFailed(message))
        case .invalidated:
            // An invalidated session is unusable; the next join installs a fresh one.
            sessionID += 1
            session = nil
            isActivated = false
            failPicker(.unavailable)
            failActivationWaiters(JoinError.unavailable)
        }
    }

    private func failPicker(_ error: JoinError) {
        pendingPickedAccessory = nil
        pickerWaiter?.resume(throwing: error)
        pickerWaiter = nil
        currentPicker = nil
    }

    private func ensureActivated() async throws {
        if isActivated { return }
        try await withCheckedThrowingContinuation { continuation in
            activationWaiters.append(continuation)
            Task {
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run {
                    guard !self.isActivated else { return }
                    self.failActivationWaiters(JoinError.unavailable)
                }
            }
        }
    }

    private func resumeActivationWaiters() {
        let waiters = activationWaiters
        activationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failActivationWaiters(_ error: JoinError) {
        let waiters = activationWaiters
        activationWaiters = []
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Network polling

    private func isOnCameraNetwork() async -> Bool {
        CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: native.localAddresses(),
            connectedSSID: await native.currentSSID()
        )
    }

    private func waitForCameraSubnet(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A cancelled join is cancelled, never "ready".
            try Task.checkCancellation()
            if await isOnCameraNetwork() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw JoinError.timedOut
    }

    private func waitForCameraNetwork(expectedSSID: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A cancelled join is cancelled, never "ready".
            try Task.checkCancellation()
            // One Wi‑Fi info read per poll: the same SSID answers both the camera-AP check and the
            // exact-match check, so avoid a redundant `NEHotspotNetwork.fetchCurrent` per tick.
            let connectedSSID = await native.currentSSID()
            if CameraWiFiJoinPolicy.isOnCameraAccessPoint(
                localAddresses: native.localAddresses(),
                connectedSSID: connectedSSID
            ) {
                return
            }
            if connectedSSID == expectedSSID { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw JoinError.timedOut
    }

    /// Product image for the system accessory picker (180×120 pt container).
    private static var productImage: UIImage? {
        UIImage(systemName: "camera.aperture")
            ?? UIImage(named: "IconCameraBattery")
    }
}
