import Foundation
import NetworkExtension
import OpenZCineCore

/// The app's side of OpenCineNikon's `NikonDiscovery` (SHELL-02): the listening sources
/// (Bonjour, USB-C), the phone's interfaces, the connection log, and the presence line of the
/// app's relay protocol. Every network dial goes through `PosixNikonDialer`; the cameras list
/// runs `.passive` (never the PTP/IP control port, never a PTP byte), pairing and an armed setup
/// watch run `.active`.
enum NativeNikonDiscovery {
    static let dialer = PosixNikonDialer(presencePort: MonitorRelayProtocol.presenceTCPPort) {
        line in
        RelayPresence.decode(line).map {
            NikonPresence(deviceName: $0.n, servedCamera: $0.ch, line: line)
        }
    }

    static let sources = NikonAppleDiscoverySources(usbBrowser: USBCameraDeviceBrowser.shared) { line in
        Task { @MainActor in logConnection(line) }
    }
    static let shared = NikonDiscovery(dialer: dialer, sources: sources)

    /// The app's relay presences from a sweep's answers (the protocol fields only it reads).
    static func relayPresences(_ hits: [String: NikonPresence]) -> [String: RelayPresence] {
        hits.compactMapValues { $0.line.flatMap(RelayPresence.decode) }
    }
}

enum NativePersonalHotspotDetector {
    static func isBridgeActive() -> Bool {
        NikonAppleNetworkInterfaces.isPersonalHotspotActive()
    }
}

/// Shared snapshot of local IPv4 interfaces for Wi‑Fi join policy checks.
enum NativeNetworkInterfaceSnapshot {
    static func localIPv4Addresses() -> [String] {
        NikonAppleNetworkInterfaces.snapshot().map(\.address)
    }

    /// /24 bases of this device's Personal Hotspot (bridge*) interfaces, when up.
    /// Used to classify discoveries as hotspot without a fixed IP range.
    static func hotspotSubnetBases() -> [String] {
        NikonAppleNetworkInterfaces.hotspotSubnetBases()
    }

    /// The Wi-Fi network this device is scanning, as an operator-readable subnet ("192.168.1.x").
    ///
    /// The name would be better, and iOS often refuses to give it — the field logs are full of
    /// "nehelper sent invalid result code [1] for Wi-Fi information request". The subnet always
    /// answers, needs no permission, and settles the only question that matters when a search
    /// finds nothing: are the camera and this device even on the same network. Nil when there is
    /// no scannable Wi-Fi interface at all.
    static func currentScanSubnetLabel() -> String? {
        NikonAppleNetworkInterfaces.currentScanSubnetLabel()
    }

    /// Reads the SSID of the Wi‑Fi network the phone is currently using, if available.
    static func currentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    /// Whether the Wi‑Fi radio is up. iOS has no direct query, but the AWDL peer link (`awdl0`)
    /// runs exactly while Wi‑Fi is enabled — including when no network is joined and in the
    /// Control Center soft-off state, where an `NEHotspotConfiguration` join still works. Only
    /// a real Settings-level Wi‑Fi off takes it down. AWDL carries no IPv4, so this scans all
    /// address families, unlike ``localIPv4Addresses()``. Defaults to `true` on probe failure:
    /// never block a join on a broken snapshot.
    static func isWiFiRadioOn() -> Bool {
        NikonAppleNetworkInterfaces.isWiFiRadioOn()
    }
}

/// Live IPv4 interfaces for discovery and infrastructure search (shared by
/// `NativeNikonDiscovery` and `InfrastructureCameraFinder`).
func nativeLocalIPv4Interfaces() -> [NikonLocalInterface] {
    NikonAppleNetworkInterfaces.snapshot()
}
