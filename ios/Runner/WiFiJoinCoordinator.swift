import Foundation
import NetworkExtension
import OpenCineApple
import OpenCineCore
import OpenZCineCore
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

    /// How a join attempt should reach the system Wi‑Fi sheet.
    enum JoinStrategy: Equatable, Sendable {
        /// iOS 18+: AccessorySetupKit picker with `NEHotspotConfiguration` fallback.
        case automatic
        /// `NEHotspotConfiguration.apply` only — used for proactive launch joins where ASK
        /// often fails to discover Nikon camera soft-APs.
        case hotspotConfigurationOnly
    }

    /// This coordinator's one camera hotspot owner, retained across joins: a retry, re-apply or
    /// removal never reaches the OS while an earlier apply is still pending there, and work
    /// queued for a retired join never runs.
    private let cameraHotspot = CameraHotspotSystem(cancellation: .retireCaller)
    /// Operator joins in flight. A best-effort re-apply stands aside for them.
    private var activeJoins = 0

    private init() {}

    /// Applies the best available join path and waits until the phone is on the camera subnet.
    /// `isCurrent` is the caller's connection validity, checked before queued hotspot work runs.
    func joinCameraNetwork(
        ssid rawSSID: String,
        password: String?,
        strategy: JoinStrategy = .automatic,
        isCurrent: @escaping CameraNetworkIsCurrent = { true }
    ) async throws {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { throw JoinError.invalidSSID }
        activeJoins += 1
        defer { activeJoins -= 1 }
        try await cameraHotspot.host.withAttempt(isCurrent) { [self] operations in
            try await joinCameraNetwork(
                ssid: ssid, password: password, strategy: strategy, operations: operations)
        }
    }

    private func joinCameraNetwork(
        ssid: String,
        password: String?,
        strategy: JoinStrategy,
        operations: CameraHotspotOperations
    ) async throws {
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
        try await apply(
            .init(selection: .ssid(ssid), security: Self.security(password), joinOnce: false),
            context: "ssid=\(ssid)", with: operations)
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
        strategy: JoinStrategy = .automatic,
        isCurrent: @escaping CameraNetworkIsCurrent = { true }
    ) async throws {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { throw JoinError.invalidSSID }
        activeJoins += 1
        defer { activeJoins -= 1 }
        try await cameraHotspot.host.withAttempt(isCurrent) { [self] operations in
            try await joinCameraNetwork(
                ssidPrefix: prefix, password: password, strategy: strategy, operations: operations)
        }
    }

    private func joinCameraNetwork(
        ssidPrefix prefix: String,
        password: String?,
        strategy: JoinStrategy,
        operations: CameraHotspotOperations
    ) async throws {
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
        try await apply(
            .init(selection: .prefix(prefix), security: Self.security(password), joinOnce: false),
            context: "ssidPrefix=\(prefix)", with: operations)
        try await waitForCameraSubnet(preJoinAddresses: preJoinAddresses, timeout: 45)
    }

    /// Removes the camera network's hotspot configuration so iOS drops the AP and falls back to a
    /// preferred network or cellular — the RED LUT "internet hop". The keychain password survives,
    /// so a later ``reapplyCameraNetwork(ssid:)`` restores the link (iOS may re-ask to join once,
    /// since removing the configuration forgets the operator's prior approval).
    /// Queued behind a still pending apply, the removal runs only while `isCurrent` holds.
    func leaveCameraNetwork(
        ssid rawSSID: String, isCurrent: @escaping CameraNetworkIsCurrent = { true }
    ) {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { return }
        cameraHotspot.host.remove(ssid, isCurrent)
        Self.hotspotLogger.info(
            "NEHotspotConfiguration removed ssid=\(ssid, privacy: .private(mask: .hash)) for internet hop"
        )
    }

    /// Fire-and-forget re-apply of a known camera network's hotspot config. Pulls the phone back
    /// onto the camera AP after a pairing-triggered AP restart (the camera drops and re-raises its
    /// Wi‑Fi), when the credentials are already saved. No wait — discovery confirms the return.
    /// Every apply is operator-visible, so callers pay for cadence: see ``reapplyInFlightSince``.
    /// SSIDs whose re-apply the operator has declined. iOS shows a system "Wants to Join" alert
    /// for every apply, so a re-apply loop that ignores a Cancel becomes the cancel-storm
    /// ("cancel, cancel, cancel…"). One decline ends the chase for that network until an
    /// explicit operator-initiated join clears it.
    private var declinedReapplySSIDs: Set<String> = []

    /// When the outstanding re-apply started, or nil when none is. iOS serialises applies anyway;
    /// what this prevents is the queue of alerts a caller builds by ticking faster than one
    /// association attempt takes to fail.
    private var reapplyInFlightSince: Date?

    func reapplyCameraNetwork(ssid rawSSID: String) {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, !declinedReapplySSIDs.contains(ssid) else { return }
        Task { [weak self] in await self?.performReapply(ssid: ssid) }
    }

    private func performReapply(ssid: String) async {
        // Already back on the camera AP → re-applying its own configuration only races the live
        // association and draws an `.alreadyAssociated`/`.internal` error from iOS with no benefit.
        // Discovery is the final arbiter of the return, so there is nothing to do here.
        if await isConnected(toSSID: ssid) { return }

        // An apply aimed at an access point that is not broadcasting yet — a camera still
        // rebooting after its Confirm — spends around fifteen seconds trying before iOS gives up
        // with "Unable to connect". Applies from a caller's next tick do not shorten that; they
        // queue behind it and each buys the operator another alert and another failure, which is
        // how one rebooting camera produced a run of them. One attempt at a time. The elapsed
        // check is a self-heal: a lost callback must not disarm the chase for good.
        if let started = reapplyInFlightSince, Date().timeIntervalSince(started) < 30 { return }
        reapplyInFlightSince = Date()

        let password = CameraWiFiCredentialStore.password(forSSID: ssid)

        // Remove the installed configuration FIRST, or this whole function is a no-op.
        //
        // Applying a configuration for an SSID that already has one is not a rejoin request as
        // far as iOS is concerned: it is already configured, so the apply resolves without
        // re-associating, and iOS certainly will not walk away from a working home network with
        // internet on its own account. The operator sees no prompt and stays exactly where they
        // are. Field report: confirm on the camera, camera restarts its access point, phone falls
        // back to home Wi-Fi, and every ten seconds this reapplied into silence.
        //
        // Removing first makes the next apply a genuine join, which is what draws the system
        // alert and actually moves the phone. Safe here because the caller only reaches this
        // branch having established, by SSID *or* by dialling the access point, that we are not
        // on the camera's network, so there is no live association to tear down.
        Self.hotspotLogger.info(
            "reapply join ssid=\(ssid, privacy: .private(mask: .hash)) hasPassword=\(password?.isEmpty == false)"
        )
        do {
            // An operator join that started meanwhile owns the native work; this stands aside.
            guard activeJoins == 0 else {
                reapplyInFlightSince = nil
                return
            }
            let configuration = CameraHotspotConfiguration(
                selection: .ssid(ssid), security: Self.security(password), joinOnce: false)
            try await cameraHotspot.host.withAttempt(
                { true },
                { operations in
                    operations.remove(ssid)
                    try await operations.apply(configuration)
                })
            reapplyInFlightSince = nil
        } catch is CancellationError {
            // A newer join retired this one; its native apply may still be pending, so the
            // in-flight mark stays (the 30 s self-heal still applies).
        } catch {
            reapplyInFlightSince = nil
            // An operator Cancel on the system alert is a decision, not a transient failure:
            // latch it so the chase stops instead of re-prompting on the next tick.
            if (error as NSError).code == NEHotspotConfigurationError.userDenied.rawValue {
                declinedReapplySSIDs.insert(ssid)
                Self.hotspotLogger.info(
                    "reapply declined by operator ssid=\(ssid, privacy: .private(mask: .hash)), chase disarmed"
                )
                return
            }
            // A best-effort reapply races the camera's pairing-triggered AP restart. iOS answers
            // `.alreadyAssociated` when the phone is already back on the network and `.internal`
            // (code 8) when the config can't be applied right now, also on the simulator, which
            // has no Wi-Fi radio. Neither is actionable, so keep them out of the error stream.
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

    /// One persistent (`joinOnce = false`) apply through the scoped owner; "already associated"
    /// is success.
    private func apply(
        _ configuration: CameraHotspotConfiguration, context: String,
        with operations: CameraHotspotOperations
    ) async throws {
        do {
            try await operations.apply(configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isBenignHotspotError(error) { return }
            Self.logHotspotError(error, context: context)
            throw Self.mapHotspotError(error)
        }
    }

    private nonisolated static func security(_ password: String?)
        -> CameraHotspotConfiguration.Security
    {
        if let password, !password.isEmpty { return .personal(passphrase: password) }
        return .open
    }

    private func isConnected(toSSID ssid: String) async -> Bool {
        await cameraHotspot.host.currentSSID() == ssid
    }

    private func waitForCameraSubnet(
        preJoinAddresses: Set<String>,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A cancelled join is cancelled, never "on the network".
            try Task.checkCancellation()
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
            // A cancelled join is cancelled, never "on the network".
            try Task.checkCancellation()
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
