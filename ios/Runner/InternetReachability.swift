import Foundation
import Network
import NetworkExtension
import Observation

/// Observable wrapper over `NWPathMonitor` that publishes whether the OS reports a usable network
/// path and whether the phone is joined to the camera's local-only Wi‑Fi AP.
///
/// Used to gate internet-only features such as the RED LUT download. The camera's soft-AP reports a
/// *satisfied* path but carries no internet route, so callers combine ``hasNetworkPath`` with
/// ``isOnCameraAccessPoint`` (SSID-based, via ``CameraWiFiJoinPolicy``) rather than trusting path
/// status alone.
@MainActor
@Observable
final class InternetReachability {
    /// Whether the OS currently reports a satisfied (usable) network path.
    ///
    /// Starts `true` so the UI doesn't briefly gate a legitimately-online launch before the first
    /// path update arrives; the monitor corrects it within moments of the first callback.
    private(set) var hasNetworkPath: Bool = true

    /// SSID of the Wi‑Fi network the phone is currently using, when iOS exposes it.
    private(set) var connectedSSID: String?

    /// Whether the phone is joined to a Nikon ZR camera access point (no WAN route).
    var isOnCameraAccessPoint: Bool {
        CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: [],
            connectedSSID: connectedSSID
        )
    }

    /// Resolves RED LUT download availability from the live reachability signals.
    var redLUTDownloadAvailability: RedLUTDownloadAvailability {
        RedLUTDownloadPolicy.availability(
            hasInternetPath: hasNetworkPath,
            isOnCameraAccessPoint: isOnCameraAccessPoint
        )
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "OpenZCine.reachability", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.hasNetworkPath = satisfied
                await self.refreshSSID()
            }
        }
        monitor.start(queue: queue)
        Task { await refreshSSID() }
    }

    deinit {
        monitor.cancel()
    }

    @ObservationIgnored private var lastSSIDFetch: Date?

    /// Re-reads the connected SSID so camera-AP detection stays current after Wi‑Fi changes.
    /// Debounced: `NEHotspotNetwork.fetchCurrent` logs a nehelper error line on every call when
    /// the wifi-info capability isn't live, and path updates arrive in bursts — one read per
    /// couple of seconds is plenty for AP detection.
    func refreshSSID() async {
        if let last = lastSSIDFetch, Date().timeIntervalSince(last) < 2 { return }
        lastSSIDFetch = Date()
        connectedSSID = await Self.fetchCurrentSSID()
    }

    private static func fetchCurrentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}
