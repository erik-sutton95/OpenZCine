import Darwin
import Foundation
import NetworkExtension

// SAFETY: `@unchecked Sendable` — holds no mutable stored state; all work runs in local async scopes.
final class NativeCameraDiscoveryService: @unchecked Sendable {
    /// `excludedHosts` are addresses that must not be PTP-probed — cameras some visible
    /// broadcast is already serving. The body accepts a single initiator; probing a served
    /// camera drops the broadcaster's session (the "main device loses connection whenever a
    /// watcher joins or leaves" report — the watcher's own camera list was the aggressor).
    /// Passive discovery (Bonjour, USB attach) is unaffected: listing is harmless, Init is not.
    /// A provider rather than a set: the probe pass starts ~1.5 s into a scan, and a relay
    /// browser started alongside it has usually sighted the broadcasts by then — the freshest
    /// answer is the one that protects the camera.
    func discover(
        guid: Data,
        priorityHosts: [String] = [],
        excludedHosts: @MainActor @escaping () -> Set<String> = { [] },
        status: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> [DiscoveredCamera] {
        // USB-attached cameras are browser-driven and effectively instant; surface them without
        // waiting for the network passes. Starting the browser here is safe — discovery only runs
        // after first render, past the known too-early ICC authorization hang.
        let usbBrowser = USBCameraDeviceBrowser.shared
        usbBrowser.start()
        let usbCameras = usbBrowser.attachedCameras()

        await status("Searching for cameras on Wi‑Fi and USB‑C…")
        // Bonjour FIRST, and the trusted-host probe only covers what Bonjour did not report.
        // A PTP probe is an Init the body must answer — probing a body that is already
        // advertising is not just wasted, it is the drop mechanism: a body another device
        // holds a session with closes that session's event channel when a second initiator
        // knocks. Running the probe concurrently with Bonjour (tried for speed) had this
        // device's every-few-seconds quick pass knocking a live body it was about to list
        // anyway. The reconnect case a probe exists for — a body that just rebooted and is
        // not advertising yet — still gets its probe round, after the 1.4 s window.
        let bonjour = await BonjourPTPBrowser().discover(timeout: 1.4)
        let bonjourHosts = Set(bonjour.compactMap { PTPIPPairedHosts.normalizedHost($0.ip) })
        let priority = await probeTrustedHosts(
            guid: guid,
            priorityHosts: priorityHosts,
            excludedHosts: { excludedHosts().union(bonjourHosts) })
        let quickResults = CameraDiscovery.dedupeAndSort(usbCameras + bonjour + priority)
        if !quickResults.isEmpty {
            return quickResults
        }

        await status("Still searching your network for cameras…")
        let probeResults = try await subnetProbe(
            guid: guid, priorityHosts: priorityHosts, excludedHosts: excludedHosts,
            status: status)
        return CameraDiscovery.dedupeAndSort(usbBrowser.attachedCameras() + probeResults)
    }

    /// Whether iOS has denied USB camera-control access (drives permission-recovery copy).
    var isUSBControlAuthorizationDenied: Bool {
        USBCameraDeviceBrowser.shared.isControlAuthorizationDenied
    }

    private func subnetProbe(
        guid: Data,
        priorityHosts: [String],
        excludedHosts: @MainActor @escaping () -> Set<String>,
        status: @MainActor @escaping (String) -> Void
    ) async throws -> [DiscoveredCamera] {
        let excluded = await excludedHosts()
        let allLocalInterfaces = nativeLocalIPv4Interfaces()
        let scanInterfaces = allLocalInterfaces.filter {
            CameraDiscovery.isSupportedScanInterface(name: $0.name, address: $0.address)
        }
        let localAddresses = scanInterfaces.map(\.address)
        // Saved cameras' last-known hosts (+ the ZR AP address) go first as their own tiny
        // chunk: the common reconnect case answers in one probe round (~0.65s) instead of
        // waiting on the /24 sweep. The sweep itself stays chunked with an early break so a
        // found camera stops the scan — deliberately NOT all-parallel, to keep the number of
        // hosts blind-probed as small as today (probing can knock a ZR out of pairing mode).
        let split = CameraDiscovery.prioritizedScanHosts(
            priorityHosts: priorityHosts, localAddresses: localAddresses)
        // Filter the OUTPUT, not the inputs: the core adds candidates of its own (the AP
        // address) beyond what was passed in, and every last probe candidate must respect the
        // served-camera exclusion.
        let priorityChunk = split.priority.filter { !excluded.contains($0) }
        let candidateChunks =
            [priorityChunk].filter { !$0.isEmpty }
            + split.remaining.filter { !excluded.contains($0) }.chunked(into: 128)

        if scanInterfaces.isEmpty {
            let bridgeAddresses = allLocalInterfaces.filter { $0.name.hasPrefix("bridge") }
                .map(\.address)
                .sorted()
            if !bridgeAddresses.isEmpty {
                await status(
                    "iPhone hotspot is active. Waiting for your camera to appear…"
                )
            } else {
                await status(
                    "Waiting for Wi‑Fi. Turn on Connect to PC on the camera, then join its network."
                )
            }
        } else {
            await status("Searching nearby networks for your camera…")
        }

        var discovered: [DiscoveredCamera] = []
        for chunk in candidateChunks {
            let chunkResults = await withTaskGroup(of: DiscoveredCamera?.self) { group in
                for host in chunk {
                    group.addTask {
                        try? await self.probe(host: host, guid: guid)
                    }
                }

                var results: [DiscoveredCamera] = []
                for await result in group {
                    if let result {
                        results.append(result)
                    }
                }
                return results
            }

            discovered.append(contentsOf: chunkResults)
            if !discovered.isEmpty {
                break
            }
        }

        return discovered
    }

    /// Probes only the KNOWN candidates — saved cameras' last hosts plus the camera-AP
    /// convention address — in one parallel round. These are trusted addresses, so this
    /// carries none of the blind-probe restraint the full sweep is built around.
    private func probeTrustedHosts(
        guid: Data,
        priorityHosts: [String],
        excludedHosts: @MainActor @escaping () -> Set<String>
    ) async -> [DiscoveredCamera] {
        let excluded = await excludedHosts()
        let localAddresses = nativeLocalIPv4Interfaces()
            .filter {
                CameraDiscovery.isSupportedScanInterface(name: $0.name, address: $0.address)
            }
            .map(\.address)
        let split = CameraDiscovery.prioritizedScanHosts(
            priorityHosts: priorityHosts, localAddresses: localAddresses)
        let hosts = split.priority.filter { !excluded.contains($0) }
        guard !hosts.isEmpty else { return [] }
        return await withTaskGroup(of: DiscoveredCamera?.self) { group in
            for host in hosts {
                group.addTask { try? await self.probe(host: host, guid: guid) }
            }
            var results: [DiscoveredCamera] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private func probe(host: String, guid: Data) async throws -> DiscoveredCamera? {
        guard
            let name = try await PTPIPTransport.probeCameraName(
                host: host,
                guid: guid,
                timeoutMilliseconds: 650
            )
        else {
            return nil
        }
        return DiscoveredCamera(ip: host, name: name, source: .subnetProbe)
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
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return true }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard String(cString: interface.pointee.ifa_name).hasPrefix("awdl") else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0 { return true }
        }
        return false
    }
}

private struct NativeLocalIPv4Interface: Sendable {
    let name: String
    let address: String
}

private func nativeLocalIPv4Interfaces() -> [NativeLocalIPv4Interface] {
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
            addresses.append(NativeLocalIPv4Interface(name: name, address: address))
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

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
