import AccessorySetupKit
import Foundation
import NetworkExtension
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

    private let session = ASAccessorySession()
    private var isActivated = false
    private var activationWaiters: [CheckedContinuation<Void, Error>] = []
    private var pickerWaiter: CheckedContinuation<ASAccessory, Error>?
    private var pendingPickedAccessory: ASAccessory?

    private init() {
        session.activate(on: .main) { [weak self] event in
            Task { @MainActor in
                self?.handleSessionEvent(event)
            }
        }
    }

    /// Joins a camera network by exact SSID using the system accessory picker when needed.
    func joinCameraNetwork(ssid rawSSID: String, password: String?) async throws {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { throw JoinError.invalidSSID }

        if await isOnCameraNetwork() { return }

        let accessory = try await resolveAccessory(ssid: ssid)
        try await joinAuthorizedAccessory(accessory, password: password)
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
        try await waitForCameraSubnet(timeout: 45)
    }

    // MARK: - Accessory resolution

    private func resolveAccessory(ssid: String) async throws -> ASAccessory {
        try await ensureActivated()
        if let existing = authorizedAccessory(matchingSSID: ssid) {
            return existing
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.ssid = ssid
        return try await presentPicker(descriptor: descriptor, displayName: "Nikon camera")
    }

    private func resolveAccessory(ssidPrefix: String) async throws -> ASAccessory {
        try await ensureActivated()
        if let existing = authorizedAccessory(matchingPrefix: ssidPrefix) {
            return existing
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.ssidPrefix = ssidPrefix
        return try await presentPicker(descriptor: descriptor, displayName: "Nikon camera")
    }

    private func authorizedAccessory(matchingSSID ssid: String) -> ASAccessory? {
        session.accessories.first {
            $0.state == .authorized && $0.ssid == ssid
        }
    }

    private func authorizedAccessory(matchingPrefix prefix: String) -> ASAccessory? {
        session.accessories.first {
            guard $0.state == .authorized, let ssid = $0.ssid else { return false }
            return ssid.hasPrefix(prefix)
        }
    }

    private func presentPicker(
        descriptor: ASDiscoveryDescriptor,
        displayName: String
    ) async throws -> ASAccessory {
        guard let productImage = Self.productImage else {
            throw JoinError.unavailable
        }

        let item = ASPickerDisplayItem(
            name: displayName,
            productImage: productImage,
            descriptor: descriptor
        )

        return try await withCheckedThrowingContinuation { continuation in
            guard pickerWaiter == nil else {
                continuation.resume(
                    throwing: JoinError.pickerFailed("Accessory picker is already active."))
                return
            }
            pickerWaiter = continuation
            pendingPickedAccessory = nil

            session.showPicker(for: [item]) { error in
                Task { @MainActor in
                    if let error {
                        self.failPicker(
                            JoinError.pickerFailed(error.localizedDescription)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Hotspot join

    private func joinAuthorizedAccessory(_ accessory: ASAccessory, password: String?) async throws {
        do {
            if let password, !password.isEmpty {
                try await NEHotspotConfigurationManager.shared.joinAccessoryHotspot(
                    accessory,
                    passphrase: password
                )
            } else {
                try await NEHotspotConfigurationManager.shared.joinAccessoryHotspotWithoutSecurity(
                    accessory
                )
            }
        } catch {
            Self.logger.error(
                "joinAccessoryHotspot failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw JoinError.joinFailed(error.localizedDescription)
        }
    }

    // MARK: - Session events

    private func handleSessionEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isActivated = true
            resumeActivationWaiters()
        case .accessoryAdded:
            if let accessory = event.accessory {
                pendingPickedAccessory = accessory
            }
        case .pickerDidDismiss:
            if let accessory = pendingPickedAccessory {
                pendingPickedAccessory = nil
                pickerWaiter?.resume(returning: accessory)
                pickerWaiter = nil
            } else {
                failPicker(.userDenied)
            }
        case .pickerSetupFailed:
            let message = event.error?.localizedDescription ?? "Accessory setup failed."
            failPicker(.pickerFailed(message))
        case .invalidated:
            isActivated = false
            failPicker(.unavailable)
            failActivationWaiters(JoinError.unavailable)
        case .accessoryChanged, .accessoryRemoved, .migrationComplete,
            .pickerDidPresent, .pickerSetupBridging, .pickerSetupPairing,
            .pickerSetupRename, .accessoryDiscovered, .unknown:
            break
        @unknown default:
            break
        }
    }

    private func failPicker(_ error: JoinError) {
        pendingPickedAccessory = nil
        pickerWaiter?.resume(throwing: error)
        pickerWaiter = nil
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
            localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
            connectedSSID: await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
        )
    }

    private func waitForCameraSubnet(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            if await isOnCameraNetwork() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw JoinError.timedOut
    }

    private func waitForCameraNetwork(expectedSSID: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            // One Wi‑Fi info read per poll: the same SSID answers both the camera-AP check and the
            // exact-match check, so avoid a redundant `NEHotspotNetwork.fetchCurrent` per tick.
            let connectedSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
            if CameraWiFiJoinPolicy.isOnCameraAccessPoint(
                localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
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
