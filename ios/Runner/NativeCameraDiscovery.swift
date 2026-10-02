import Darwin
import Foundation
import NetworkExtension
import os
import OpenZCineCore

/// The app's side of OpenCineNikon's `NikonDiscovery` (SHELL-02): the listening sources
/// (Bonjour, USB-C), the phone's interfaces, the connection log, and the presence line of the
/// app's relay protocol. Every network dial goes through `PosixNikonDialer`; the cameras list
/// runs `.passive` (never the PTP/IP control port, never a PTP byte), pairing and an armed setup
/// watch run `.active`.
enum NativeNikonDiscovery {
    static let dialer = PosixNikonDialer(presencePort: MonitorRelayProtocol.presenceTCPPort) { line in
        RelayPresence.decode(line).map { NikonPresence(deviceName: $0.n, servedCamera: $0.ch, line: line) }
    }

    static let shared = NikonDiscovery(dialer: dialer, sources: Sources())

    /// The app's relay presences from a sweep's answers (the protocol fields only it reads).
    static func relayPresences(_ hits: [String: NikonPresence]) -> [String: RelayPresence] {
        hits.compactMapValues { $0.line.flatMap(RelayPresence.decode) }
    }

    struct Sources: NikonDiscoverySources {
        func interfaces() -> [NikonLocalInterface] {
            nativeLocalIPv4Interfaces().map {
                NikonLocalInterface(name: $0.name, address: $0.address, netmask: $0.netmask)
            }
        }

        func bonjour(timeout: Duration) async -> [DiscoveredCamera] {
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            return await BonjourPTPBrowser().discover(timeout: seconds)
        }

        /// Gated by the caller (`browsesUSB`): exercising ICC camera control makes the OS show its
        /// camera-control disclosure, so only a cable in play starts the browser.
        func usbCameras(start: Bool) async -> [DiscoveredCamera] {
            let browser = USBCameraDeviceBrowser.shared
            if start { browser.start() }
            return browser.attachedCameras()
        }

        func log(_ line: String) {
            Task { @MainActor in logConnection(line) }
        }
    }
}

enum NativePersonalHotspotDetector {
    static func isBridgeActive() -> Bool {
        nativeLocalIPv4Interfaces().contains { $0.name.hasPrefix("bridge") }
    }
}

/// Shared snapshot of local IPv4 interfaces for Wi‑Fi join policy checks.
enum NativeNetworkInterfaceSnapshot {
    static func localIPv4Addresses() -> [String] {
        nativeLocalIPv4Interfaces().map(\.address)
    }

    /// /24 bases of this device's Personal Hotspot (bridge*) interfaces, when up.
    /// Used to classify discoveries as hotspot without a fixed IP range.
    static func hotspotSubnetBases() -> [String] {
        var bases: [String] = []
        var seen: Set<String> = []
        for iface in nativeLocalIPv4Interfaces() where iface.name.hasPrefix("bridge") {
            guard let base = CameraDiscovery.subnetBase(for: iface.address),
                !seen.contains(base)
            else { continue }
            seen.insert(base)
            bases.append(base)
        }
        return bases
    }

    /// The Wi-Fi network this device is scanning, as an operator-readable subnet ("192.168.1.x").
    ///
    /// The name would be better, and iOS often refuses to give it — the field logs are full of
    /// "nehelper sent invalid result code [1] for Wi-Fi information request". The subnet always
    /// answers, needs no permission, and settles the only question that matters when a search
    /// finds nothing: are the camera and this device even on the same network. Nil when there is
    /// no scannable Wi-Fi interface at all.
    static func currentScanSubnetLabel() -> String? {
        let scannable = nativeLocalIPv4Interfaces().filter {
            CameraDiscovery.isSupportedScanInterface(name: $0.name, address: $0.address)
        }
        guard let address = scannable.first?.address else { return nil }
        let octets = address.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return octets.prefix(3).joined(separator: ".") + ".x"
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
        // The probe reads a DEVICE's radio. A simulator has none of its own — it borrows whatever
        // the host has, so an absent `awdl` says something about the Mac's networking rather than
        // about any radio an operator could switch. Answering "off" there blocks camera-AP staging
        // on a machine that is merely wired: exactly what happened on CI, where the runner has no
        // Wi-Fi at all and two staging tests failed while passing on every developer's laptop.
        // `ZC_DEMO_WIFI_OFF` remains the way to reach the prompt here, which is why it exists.
        #if targetEnvironment(simulator)
            return true
        #else
            var interfaces: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&interfaces) == 0, let first = interfaces else { return true }
            defer { freeifaddrs(interfaces) }

            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let interface = cursor {
                defer { cursor = interface.pointee.ifa_next }
                guard String(cString: interface.pointee.ifa_name).hasPrefix("awdl") else {
                    continue
                }
                let flags = Int32(interface.pointee.ifa_flags)
                if (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0 { return true }
            }
            return false
        #endif
    }
}

struct NativeLocalIPv4Interface: Sendable {
    let name: String
    let address: String
    /// The prefix the OS actually assigned. Read and then discarded for years, which is why a
    /// device on a wide subnet only ever searched 1/256th of its own link.
    let netmask: String?
}

/// Live IPv4 interfaces for discovery and infrastructure search (shared by
/// `NativeNikonDiscovery` and `InfrastructureCameraFinder`).
func nativeLocalIPv4Interfaces() -> [NativeLocalIPv4Interface] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }

    var addresses: [NativeLocalIPv4Interface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor {
        defer { cursor = interface.pointee.ifa_next }
        let flags = Int32(interface.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let socketAddress = interface.pointee.ifa_addr else { continue }
        guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        if let address = ipv4Address(
            from: socketAddress, length: socklen_t(socketAddress.pointee.sa_len))
        {
            let name = String(cString: interface.pointee.ifa_name)
            // `getifaddrs` has always handed us the netmask beside the address; nothing read it.
            let netmask = interface.pointee.ifa_netmask.flatMap {
                ipv4Address(from: $0, length: socklen_t($0.pointee.sa_len))
            }
            addresses.append(
                NativeLocalIPv4Interface(name: name, address: address, netmask: netmask))
        }
    }
    return addresses
}

// SAFETY: `@unchecked Sendable` — `services`, `cameras`, and `continuation` are guarded by
// `lock` (`NSLock`); NetService delegate callbacks and the async caller never touch them off it.
private final class BonjourPTPBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var cameras: [DiscoveredCamera] = []
    private var continuation: CheckedContinuation<[DiscoveredCamera], Never>?

    func discover(timeout: TimeInterval) async -> [DiscoveredCamera] {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            browser.delegate = self
            browser.searchForServices(ofType: "_ptp._tcp.", inDomain: "local.")

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish()
            }
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        lock.lock()
        services.append(service)
        lock.unlock()

        service.delegate = self
        service.resolve(withTimeout: 1.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let resolved = (sender.addresses ?? []).compactMap(ipv4Address).map {
            DiscoveredCamera(ip: $0, name: sender.name, source: .bonjour)
        }
        guard !resolved.isEmpty else { return }

        lock.lock()
        cameras.append(contentsOf: resolved)
        let isFirstResolution = cameras.count == resolved.count
        lock.unlock()

        // Early return: once one camera has resolved, wait only a short settle for siblings
        // resolving in the same burst instead of the full browse window — the common
        // single-camera case finishes in a few hundred ms rather than the fixed timeout.
        if isFirstResolution {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.finish()
            }
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        finish()
    }

    private func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        browser.stop()
        browser.delegate = nil
        for service in services {
            service.delegate = nil
        }
        let output = cameras
        lock.unlock()

        continuation?.resume(returning: output)
    }
}

private func ipv4Address(from data: Data) -> String? {
    data.withUnsafeBytes { rawBuffer -> String? in
        guard let base = rawBuffer.baseAddress else { return nil }
        let socketAddress = base.assumingMemoryBound(to: sockaddr.self)
        guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return ipv4Address(from: socketAddress, length: socklen_t(data.count))
    }
}

private func ipv4Address(from socketAddress: UnsafePointer<sockaddr>, length: socklen_t) -> String?
{
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = getnameinfo(
        socketAddress,
        length,
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
    )
    guard result == 0 else { return nil }
    let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let address = String(decoding: bytes, as: UTF8.self)
    return CameraDiscovery.isPrivateIPv4(address) ? address : nil
}
