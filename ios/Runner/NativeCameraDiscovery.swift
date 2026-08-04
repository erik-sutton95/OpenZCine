import Darwin
import Foundation
import NetworkExtension
import os

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
    /// `passiveOnly` restricts the pass to Bonjour + USB — no PTP probing at all. Currently
    /// unused: hardware evidence (2026-08-03) settled that an infrastructure pairing-wait ZR
    /// advertises nothing (only a probe finds it) AND survives being probed — so setup watches
    /// scan actively. The mechanism stays for any future body state that genuinely cannot be
    /// probed; the camera-AP pairing wizard context is where probe-sensitivity was once seen.
    func discover(
        guid: Data,
        priorityHosts: [String] = [],
        excludedHosts: @MainActor @escaping () -> Set<String> = { [] },
        passiveOnly: Bool = false,
        status: @MainActor @escaping (String) -> Void = { _ in },
        onRelayPresences: @MainActor @escaping ([String: RelayPresence]) -> Void = { _ in }
    ) async throws -> [DiscoveredCamera] {
        // USB-attached cameras are browser-driven and effectively instant; surface them without
        // waiting for the network passes. Starting the browser here is safe — discovery only runs
        // after first render, past the known too-early ICC authorization hang.
        let usbBrowser = USBCameraDeviceBrowser.shared
        usbBrowser.start()
        let usbCameras = usbBrowser.attachedCameras()

        // Unicast presence runs FIRST and is AWAITED before anything probes: on a network where
        // Bonjour never delivers (filtered multicast, odd interface topology), the presence
        // answers are the ONLY thing that names the served camera — and a fresh device with no
        // shield running its probe passes against that camera is exactly the drop mechanism
        // (field report: new device on the network knocks the broadcaster's feed over, empty
        // excluded=[] in its probe logs). Concurrent-and-non-blocking was tried for snappiness;
        // it raced the shield against the probes it exists to stop. Rate-limited to one
        // full-subnet sweep per 30 s; between sweeps the model's ledger (90 s linger) keeps
        // the exclusion warm.
        var presenceShieldedHosts: Set<String> = []
        if Self.claimPresenceSweepSlot() {
            let localAddresses = nativeLocalIPv4Interfaces()
                .filter {
                    CameraDiscovery.isSupportedScanInterface(
                        name: $0.name, address: $0.address)
                }
                .map(\.address)
            let split = CameraDiscovery.prioritizedScanHosts(
                priorityHosts: priorityHosts, localAddresses: localAddresses)
            let sweptHosts = split.priority + split.remaining
            let hits = await Self.relayPresenceSweep(hosts: sweptHosts)
            let listing =
                hits
                .map { host, presence in
                    "\(host)(\(presence.n) w=\(presence.w) ch=\(presence.ch ?? "nil")"
                        + " p=\(presence.p.map(String.init) ?? "nil"))"
                }
                .joined(separator: " ")
            await MainActor.run {
                logConnection("presence sweep hits=\(hits.count) [\(listing)]")
                // Zero hits is still a verdict: the sweep dialed the whole subnet, so the
                // model must hear about it to prune ledger rows (and refute stale Bonjour
                // rows) for broadcasts that stopped. Only an empty CANDIDATE list says
                // nothing — no interface meant nothing was actually asked.
                if !sweptHosts.isEmpty { onRelayPresences(hits) }
            }
            // An answering host is an OpenZCine device, never a camera — skip probing it — and
            // every camera it names is shielded even before the model's ledger round-trips.
            for (host, presence) in hits {
                presenceShieldedHosts.insert(host)
                if let normalized = PTPIPPairedHosts.normalizedHost(host) {
                    presenceShieldedHosts.insert(normalized)
                }
                if let served = presence.ch, !served.isEmpty {
                    presenceShieldedHosts.insert(served)
                    if let normalized = PTPIPPairedHosts.normalizedHost(served) {
                        presenceShieldedHosts.insert(normalized)
                    }
                }
            }
            Self.storePresenceShield(presenceShieldedHosts)
        } else {
            // Throttled pass: reuse the last completed sweep's shield rather than probing
            // naked. The 30 s slot exists to bound radio load, not to strip protection from
            // the passes in between (pull-to-refresh runs a full pass every pull).
            presenceShieldedHosts = Self.cachedPresenceShield()
        }
        let shielded = presenceShieldedHosts

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
        let priority =
            passiveOnly
            ? []
            : await probeTrustedHosts(
                guid: guid,
                priorityHosts: priorityHosts,
                excludedHosts: { excludedHosts().union(bonjourHosts).union(shielded) })
        let quickResults = CameraDiscovery.dedupeAndSort(usbCameras + bonjour + priority)
        if !quickResults.isEmpty {
            return quickResults
        }
        // A pairing-mode body announces itself over Bonjour; the blind sweep below is all probes,
        // so passive passes stop here rather than knocking it out of its pairing wait.
        if passiveOnly { return CameraDiscovery.dedupeAndSort(usbCameras + bonjour) }

        await status("Still searching your network for cameras…")
        let probeResults = try await subnetProbe(
            guid: guid, priorityHosts: priorityHosts,
            excludedHosts: { excludedHosts().union(shielded) },
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
        // Sweep-pass witness (counts only — a /24 listing would drown the Console): correlates
        // a blind-probe round with a broadcaster's drop timestamps.
        logConnection(
            "discovery sweep pass hosts=\(candidateChunks.reduce(0) { $0 + $1.count }) "
                + "excluded=\(excluded.count)")

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
        // The one-line witness for "who knocked the camera": every host this pass will Init,
        // and every host the served-camera shield kept it away from. (An Init against a body
        // another device holds a session with drops that session.)
        if !hosts.isEmpty || !excluded.isEmpty {
            logConnection(
                "discovery probe pass trusted=[\(hosts.joined(separator: " "))] "
                    + "excluded=[\(excluded.sorted().joined(separator: " "))]")
        }
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

    /// Grants at most one full-subnet presence sweep per 30 s across every discovery entry
    /// point, and remembers the last completed sweep's shield for the passes in between.
    /// Thread-safe: discovery runs from more than one task.
    private static let presenceSweepSlot = OSAllocatedUnfairLock(
        initialState: (last: Date.distantPast, shield: Set<String>()))
    private static func claimPresenceSweepSlot() -> Bool {
        presenceSweepSlot.withLock { state -> Bool in
            let now = Date()
            guard now.timeIntervalSince(state.last) >= 30 else { return false }
            state.last = now
            return true
        }
    }

    private static func storePresenceShield(_ shield: Set<String>) {
        presenceSweepSlot.withLock { $0.shield = shield }
    }

    private static func cachedPresenceShield() -> Set<String> {
        presenceSweepSlot.withLock { $0.shield }
    }

    /// One unicast presence read (`MonitorRelayProtocol.presenceTCPPort`), bounded. Nil for
    /// refused, timed out, or garbage — only a genuine OpenZCine presence line answers.
    /// The deadline CANCELS the connection, not just the wait: an uncancelled NWConnection to
    /// a dead host keeps its half-open flow alive until the OS gives up (~75 s), and a /24 of
    /// those is a radio storm that stalls the very broadcaster feed presence exists to protect
    /// (field log: hundreds of overlapping :15741 flows all dying at SO_ERROR 60).
    static func checkRelayPresence(
        host: String, timeoutMilliseconds: Int = 500
    ) async -> RelayPresence? {
        guard let port = NWEndpoint.Port(rawValue: MonitorRelayProtocol.presenceTCPPort) else {
            return nil
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "com.opencapture.openzcine.presence-check")
        return await withCheckedContinuation { continuation in
            // One resume total: the deadline, state failures, and the receive race for it.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (RelayPresence?) -> Void = { presence in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: presence)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(
                        minimumIncompleteLength: 1, maximumLength: 1024
                    ) { data, _, _, _ in
                        finish(data.flatMap(RelayPresence.decode))
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) {
                finish(nil)
            }
            connection.start(queue: queue)
        }
    }

    /// Sweeps `hosts` for presence answers concurrently (bounded chunks, own timeouts).
    static func relayPresenceSweep(hosts: [String]) async -> [String: RelayPresence] {
        var found: [String: RelayPresence] = [:]
        for chunk in hosts.chunked(into: 64) {
            let chunkHits = await withTaskGroup(
                of: (String, RelayPresence?).self
            ) { group in
                for host in chunk {
                    group.addTask { (host, await checkRelayPresence(host: host)) }
                }
                var hits: [String: RelayPresence] = [:]
                for await (host, presence) in group {
                    if let presence { hits[host] = presence }
                }
                return hits
            }
            found.merge(chunkHits) { _, new in new }
        }
        return found
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
