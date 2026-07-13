import Foundation
import NetworkExtension
import os

/// Joins a Nikon ZR camera Wi‑Fi network.
///
/// On iOS 18+, prefers Apple's AccessorySetupKit system picker (``AccessorySetupWiFiCoordinator``)
/// and `joinAccessoryHotspot`; falls back to `NEHotspotConfiguration.apply` on iOS 17 or when ASK
/// is unavailable.
@MainActor
final class WiFiJoinCoordinator {
    private static let logger = Logger(subsystem: "OpenZCine", category: "wifi-join")
    private nonisolated static let hotspotLogger = Logger(
        subsystem: "OpenZCine", category: "wifi-join")
    static let shared = WiFiJoinCoordinator()

    enum JoinError: LocalizedError {
        case userDenied
        case invalidSSID
        case timedOut
        case system(String)

        var errorDescription: String? {
            switch self {
            case .userDenied:
                return "Join the camera Wi‑Fi network to continue."
            case .invalidSSID:
                return "Couldn't identify the camera Wi‑Fi network."
            case .timedOut:
                return "Timed out waiting for the camera Wi‑Fi network. Try again."
            case .system(let message):
                return message
            }
        }
    }

    /// Whether the next join attempt uses AccessorySetupKit instead of a custom progress sheet.
    static var usesSystemAccessoryPicker: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// How a join attempt should reach the system Wi‑Fi sheet.
    enum JoinStrategy: Equatable, Sendable {
        /// iOS 18+: AccessorySetupKit picker with `NEHotspotConfiguration` fallback.
        case automatic
        /// `NEHotspotConfiguration.apply` only — used for proactive launch joins where ASK
        /// often fails to discover Nikon camera soft-APs.
        case hotspotConfigurationOnly
    }

    private init() {}

    /// Applies the best available join path and waits until the phone is on the camera subnet.
    func joinCameraNetwork(
        ssid rawSSID: String,
        password: String?,
        strategy: JoinStrategy = .automatic
    ) async throws {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { throw JoinError.invalidSSID }

        if await isConnected(toSSID: ssid),
            CameraWiFiJoinPolicy.isOnCameraAccessPoint(
                localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
                connectedSSID: await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
            )
        {
            return
        }

        if strategy != .hotspotConfigurationOnly, #available(iOS 18.0, *) {
            do {
                try await AccessorySetupWiFiCoordinator.shared.joinCameraNetwork(
                    ssid: ssid,
                    password: password
                )
                return
            } catch let error as AccessorySetupWiFiCoordinator.JoinError {
                if error.allowsHotspotConfigurationFallback {
                    Self.logger.info(
                        "AccessorySetupKit join failed; falling back to NEHotspotConfiguration"
                    )
                } else {
                    throw mapAccessorySetupError(error)
                }
            }
        }

        let preJoinAddresses = Set(NativeNetworkInterfaceSnapshot.localIPv4Addresses())
        try await joinViaHotspotConfiguration(ssid: ssid, password: password)
        try await waitForCameraNetwork(
            expectedSSID: ssid,
            preJoinAddresses: preJoinAddresses,
            timeout: 45
        )
    }

    /// Joins the first nearby network whose SSID starts with `ssidPrefix`.
    func joinCameraNetwork(
        ssidPrefix rawPrefix: String,
        password: String?,
        strategy: JoinStrategy = .automatic
    ) async throws {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { throw JoinError.invalidSSID }

        if CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
            connectedSSID: await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
        ) {
            return
        }

        if strategy != .hotspotConfigurationOnly, #available(iOS 18.0, *) {
            do {
                try await AccessorySetupWiFiCoordinator.shared.joinCameraNetwork(
                    ssidPrefix: prefix,
                    password: password
                )
                return
            } catch let error as AccessorySetupWiFiCoordinator.JoinError {
                if error.allowsHotspotConfigurationFallback {
                    Self.logger.info(
                        "AccessorySetupKit prefix join failed; falling back to NEHotspotConfiguration"
                    )
                } else {
                    throw mapAccessorySetupError(error)
                }
            }
        }

        let preJoinAddresses = Set(NativeNetworkInterfaceSnapshot.localIPv4Addresses())
        try await joinViaHotspotConfiguration(ssidPrefix: prefix, password: password)
        try await waitForCameraSubnet(preJoinAddresses: preJoinAddresses, timeout: 45)
    }

    /// Removes the camera network's hotspot configuration so iOS drops the AP and falls back to a
    /// preferred network or cellular — the RED LUT "internet hop". The keychain password survives,
    /// so a later ``reapplyCameraNetwork(ssid:)`` restores the link (iOS may re-ask to join once,
    /// since removing the configuration forgets the operator's prior approval).
    func leaveCameraNetwork(ssid rawSSID: String) {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        Self.hotspotLogger.info(
            "NEHotspotConfiguration removed ssid=\(ssid, privacy: .private(mask: .hash)) for internet hop"
        )
    }

    /// Fire-and-forget re-apply of a known camera network's hotspot config. Pulls the phone back
    /// onto the camera AP after a pairing-triggered AP restart (the camera drops and re-raises its
    /// Wi‑Fi), when the credentials are already saved. No wait — discovery confirms the return, and
    /// re-applying a network this app already configured does not re-prompt the operator.
    func reapplyCameraNetwork(ssid rawSSID: String) {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { return }
        Task { [weak self] in await self?.performReapply(ssid: ssid) }
    }

    private func performReapply(ssid: String) async {
        // Already back on the camera AP → re-applying its own configuration only races the live
        // association and draws an `.alreadyAssociated`/`.internal` error from iOS with no benefit.
        // Discovery is the final arbiter of the return, so there is nothing to do here.
        if await isConnected(toSSID: ssid) { return }

        let password = CameraWiFiCredentialStore.password(forSSID: ssid)
        let configuration: NEHotspotConfiguration
        if let password, !password.isEmpty {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid)
        }
        configuration.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(configuration) { error in
            guard let error else { return }
            // A best-effort reapply races the camera's pairing-triggered AP restart. iOS answers
            // `.alreadyAssociated` when the phone is already back on the network and `.internal`
            // (code 8) when the config can't be applied right now — also on the simulator, which
            // has no Wi‑Fi radio. Neither is actionable, so keep them out of the error stream.
            if Self.isBenignReapplyError(error) {
                Self.hotspotLogger.info(
                    "NEHotspotConfiguration reapply ssid=\(ssid, privacy: .private(mask: .hash)) deferred to discovery (\(error.localizedDescription, privacy: .private(mask: .hash)))"
                )
            } else {
                Self.logHotspotError(error, context: "reapply ssid=\(ssid)")
            }
        }
    }

    // MARK: - NEHotspotConfiguration fallback (iOS 17 and ASK failure)

    private func joinViaHotspotConfiguration(ssid: String, password: String?) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let configuration: NEHotspotConfiguration
            if let password, !password.isEmpty {
                configuration = NEHotspotConfiguration(
                    ssid: ssid,
                    passphrase: password,
                    isWEP: false
                )
            } else {
                configuration = NEHotspotConfiguration(ssid: ssid)
            }
            configuration.joinOnce = false

            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error {
                    if Self.isBenignHotspotError(error) {
                        continuation.resume()
                    } else {
                        Self.logHotspotError(error, context: "ssid=\(ssid)")
                        continuation.resume(throwing: Self.mapHotspotError(error))
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func joinViaHotspotConfiguration(ssidPrefix: String, password: String?) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let configuration: NEHotspotConfiguration
            if let password, !password.isEmpty {
                configuration = NEHotspotConfiguration(
                    ssidPrefix: ssidPrefix,
                    passphrase: password,
                    isWEP: false
                )
            } else {
                configuration = NEHotspotConfiguration(ssidPrefix: ssidPrefix)
            }
            configuration.joinOnce = false

            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error {
                    if Self.isBenignHotspotError(error) {
                        continuation.resume()
                    } else {
                        Self.logHotspotError(error, context: "ssidPrefix=\(ssidPrefix)")
                        continuation.resume(throwing: Self.mapHotspotError(error))
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func isConnected(toSSID ssid: String) async -> Bool {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid == ssid)
            }
        }
    }

    private func waitForCameraSubnet(
        preJoinAddresses: Set<String>,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            let addresses = NativeNetworkInterfaceSnapshot.localIPv4Addresses()
            let connectedSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
            if CameraWiFiJoinPolicy.isOnCameraAccessPoint(
                localAddresses: addresses,
                connectedSSID: connectedSSID
            ) {
                return
            }
            if Self.didSwitchNetwork(from: preJoinAddresses, to: addresses) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw JoinError.timedOut
    }

    private func waitForCameraNetwork(
        expectedSSID: String,
        preJoinAddresses: Set<String>,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            let addresses = NativeNetworkInterfaceSnapshot.localIPv4Addresses()
            // One Wi‑Fi info read per poll: reuse the SSID for both the camera-AP check and the
            // exact-match check. A second `NEHotspotNetwork.fetchCurrent` here just doubles the
            // OS "Wi‑Fi information request" chatter for the same answer.
            let connectedSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
            if CameraWiFiJoinPolicy.isOnCameraAccessPoint(
                localAddresses: addresses,
                connectedSSID: connectedSSID
            ) {
                return
            }
            if connectedSSID == expectedSSID {
                return
            }
            if Self.didSwitchNetwork(from: preJoinAddresses, to: addresses) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw JoinError.timedOut
    }

    /// Entitlement-independent join signal: a new local IPv4 address appeared that wasn't present
    /// before the join, meaning the interface switched networks. This confirms the hotspot join
    /// even when `NEHotspotNetwork` can't report the SSID (missing wifi-info entitlement, or a
    /// transient `fetchCurrent` flake right after association). Downstream PTP-IP discovery is the
    /// final arbiter, so an occasional false positive just defers to discovery rather than misfiring.
    private static func didSwitchNetwork(from before: Set<String>, to after: [String]) -> Bool {
        let now = Set(after)
        guard !now.isEmpty else { return false }
        return !now.subtracting(before).isEmpty
    }

    @available(iOS 18.0, *)
    private func mapAccessorySetupError(
        _ error: AccessorySetupWiFiCoordinator.JoinError
    ) -> JoinError {
        switch error {
        case .userDenied:
            return .userDenied
        case .invalidSSID:
            return .invalidSSID
        case .timedOut:
            return .timedOut
        case .pickerFailed(let message):
            return .system(message)
        case .joinFailed(let message):
            return .system(message)
        case .unavailable:
            return .system("Accessory setup is unavailable.")
        }
    }

    private nonisolated static func isBenignHotspotError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NEHotspotConfigurationErrorDomain else { return false }
        return nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
    }

    /// Errors that a best-effort ``reapplyCameraNetwork(ssid:)`` should treat as expected.
    ///
    /// The reapply exists only to nudge the phone back after the camera restarts its AP during
    /// pairing; discovery confirms the actual return. `.alreadyAssociated` (already back on the
    /// network) and `.internal` (config can't be applied right now, including on the simulator)
    /// are therefore non-actionable and must not surface as errors.
    private nonisolated static func isBenignReapplyError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NEHotspotConfigurationErrorDomain else { return false }
        switch nsError.code {
        case NEHotspotConfigurationError.alreadyAssociated.rawValue,
            NEHotspotConfigurationError.internal.rawValue:
            return true
        default:
            return false
        }
    }

    private nonisolated static func mapHotspotError(_ error: Error) -> JoinError {
        let nsError = error as NSError
        if nsError.domain == NEHotspotConfigurationErrorDomain {
            switch nsError.code {
            case NEHotspotConfigurationError.userDenied.rawValue:
                return .userDenied
            case NEHotspotConfigurationError.invalid.rawValue,
                NEHotspotConfigurationError.invalidSSID.rawValue:
                return .invalidSSID
            default:
                break
            }
        }
        return .system(friendlyHotspotFailureMessage(error))
    }

    private nonisolated static func friendlyHotspotFailureMessage(_ error: Error) -> String {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("unable to join") || lower.contains("could not find") {
            return
                "Couldn't reach the camera Wi‑Fi network. Make sure the camera is on and nearby, then try again."
        }
        return error.localizedDescription
    }

    private nonisolated static func logHotspotError(_ error: Error, context: String) {
        let nsError = error as NSError
        hotspotLogger.error(
            "NEHotspotConfiguration failed (\(context, privacy: .private(mask: .hash))) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
    }
}
