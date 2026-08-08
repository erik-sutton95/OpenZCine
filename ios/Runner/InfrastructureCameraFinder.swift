import Darwin
import Foundation

/// Isolated infrastructure (same-LAN Wi‑Fi) camera search.
///
/// Owns discovery for the Wi‑Fi path only: preflight, continuous Bonjour, patient directed
/// probes, occupancy-first local subnet sweep. Contains **no** Wi‑Fi join surface — that bug
/// class stays unrepresentable (see `docs/transport-architecture.md`).
///
/// The idle camera list keeps using `NativeCameraDiscoveryService` (passive / liveness) so an
/// idle phone never Inits a body another device holds. Pairing and +Add-setup Wi‑Fi use this
/// finder because a pairing-wait body advertises nothing and must be probed.
// SAFETY: `@unchecked Sendable` — no mutable stored state; all work is local to each `search`.
final class InfrastructureCameraFinder: @unchecked Sendable {
    /// One complete infrastructure search pass.
    ///
    /// - Parameters:
    ///   - guid: Initiator GUID for PTP Init (pairing profile).
    ///   - directedCandidates: Saved / dialling hosts; filtered to current local subnets.
    ///   - excludedHosts: Served / shielded hosts that must not receive Init.
    ///   - onCameraAccessPoint: Phone still on the body's own AP.
    ///   - localNetworkDenied: Known Local Network denial (skip multi-second sweep).
    ///   - status: Operator-facing progress line.
    func search(
        guid: Data,
        directedCandidates: [String] = [],
        excludedHosts: Set<String> = [],
        onCameraAccessPoint: Bool = false,
        localNetworkDenied: Bool = false,
        status: @MainActor @escaping (String) -> Void = { _ in }
    ) async -> InfrastructureSearchReport {
        if localNetworkDenied {
            return InfrastructureSearchReport(miss: .localNetworkDenied)
        }
        if onCameraAccessPoint {
            return InfrastructureSearchReport(miss: .onCameraAccessPoint)
        }

        let scanInterfaces = nativeLocalIPv4Interfaces().filter {
            CameraDiscovery.isSupportedScanInterface(name: $0.name, address: $0.address)
        }
        guard !scanInterfaces.isEmpty else {
            return InfrastructureSearchReport(miss: .noScannableInterface)
        }

        let coreInterfaces = scanInterfaces.map {
            LocalIPv4Interface(name: $0.name, address: $0.address, netmask: $0.netmask)
        }
        let localSubnets = Array(
            Set(scanInterfaces.compactMap { CameraDiscovery.subnetBase(for: $0.address) })
        ).sorted()
        let localAddressSet = Set(
            scanInterfaces.compactMap { PTPIPPairedHosts.normalizedHost($0.address) })
        let directed = InfrastructureDiscovery.directedHosts(
            candidates: directedCandidates,
            localSubnets: localSubnets,
            excluded: excludedHosts.union(localAddressSet)
        )

        let ifaceWitness =
            scanInterfaces.map {
                let prefix = SubnetScanPlan.prefixLength(netmask: $0.netmask).map { "/\($0)" }
                return "\($0.name) \($0.address)\(prefix ?? "")"
            }.joined(separator: ", ")
        logConnection(
            "infra-search preflight=ready ifaces=[\(ifaceWitness)] "
                + "subnets=[\(localSubnets.joined(separator: " "))] "
                + "directed=[\(directed.joined(separator: " "))] "
                + "attempts=\(InfrastructureDiscovery.directedAttemptCount) "
                + "budgetMs=\(InfrastructureDiscovery.directedTimeoutMilliseconds)")

        await status(
            NativeNetworkInterfaceSnapshot.currentScanSubnetLabel().map {
                "Searching \($0) for your camera…"
            } ?? "Searching this network for your camera…")

        // Continuous Bonjour for the whole pass — pairing-wait bodies often announce briefly.
        // Raced against a sequential worker (directed → occupancy sweep). First camera wins;
        // when the worker finishes empty, Bonjour is cancelled so we never hang on mDNS alone.
        let bonjourBrowser = ContinuousBonjourPTPBrowser()
        bonjourBrowser.start()
        defer { bonjourBrowser.stop() }

        enum SearchEvent {
            case found(InfrastructureSearchReport)
            /// Sequential worker finished without a camera (has diagnosis tally).
            case workerDone(InfrastructureSearchReport)
            /// Bonjour channel stopped without a hit (cancelled or browse ended) — ignore for miss.
            case bonjourIdle
        }

        let found = await withTaskGroup(of: SearchEvent.self) {
            group -> InfrastructureSearchReport in
            group.addTask {
                if let report = await self.awaitBonjourCamera(
                    browser: bonjourBrowser, excluded: excludedHosts, localSubnets: localSubnets)
                {
                    return .found(report)
                }
                return .bonjourIdle
            }
            group.addTask {
                // Directed patient probes first (reconnect / known host on this subnet).
                if let directedHit = await self.patientDirectedSearch(
                    hosts: directed, guid: guid, excluded: excludedHosts)
                {
                    return .found(directedHit)
                }
                if Task.isCancelled {
                    return .workerDone(
                        InfrastructureSearchReport(
                            miss: .cameraNotFound, localSubnets: localSubnets,
                            directedHosts: directed))
                }
                // Occupancy-first local /24 sweep (two passes for power-save wake).
                let sweep =
                    await self.occupancySweepSearch(
                        guid: guid,
                        localSubnets: localSubnets,
                        localAddressSet: localAddressSet,
                        excluded: excludedHosts,
                        directed: directed,
                        coreInterfaces: coreInterfaces
                    )
                    ?? InfrastructureSearchReport(
                        miss: .cameraNotFound, localSubnets: localSubnets, directedHosts: directed)
                if sweep.foundCamera { return .found(sweep) }
                return .workerDone(sweep)
            }

            for await event in group {
                switch event {
                case .found(let report):
                    group.cancelAll()
                    return report
                case .workerDone(let report):
                    group.cancelAll()
                    return report
                case .bonjourIdle:
                    continue
                }
            }
            return InfrastructureSearchReport(
                miss: .cameraNotFound, localSubnets: localSubnets, directedHosts: directed)
        }

        if found.foundCamera {
            logConnection(
                "infra-search FOUND \(found.cameras.map { "\($0.ip)/\($0.displayName)" }.joined(separator: " "))"
            )
            return found
        }

        var report = found
        report.localSubnets = localSubnets
        report.directedHosts = directed
        if report.miss == nil {
            // No tally to classify from — a channel returned without sweeping. Say so, rather
            // than manufacturing one out of the occupied list: `hostsProbed` derived from the
            // OCCUPIED count meant an empty sweep reported one host probed, and the "nothing on
            // this network answered" verdict could never be reached — the exact diagnosis a
            // 6 GHz/MLO network needed.
            report.miss = InfrastructureDiscovery.classifyMiss(
                preflight: .ready(interfaces: coreInterfaces),
                onCameraAccessPoint: false,
                tally: nil
            )
        }
        logConnection(
            "infra-search miss=\(String(describing: report.miss)) "
                + "open=[\(report.openPTPHosts.joined(separator: " "))] "
                + "occupied=[\(report.occupiedHosts.prefix(24).joined(separator: " "))]")
        return report
    }

    // MARK: - Channels

    private func awaitBonjourCamera(
        browser: ContinuousBonjourPTPBrowser,
        excluded: Set<String>,
        localSubnets: [String]
    ) async -> InfrastructureSearchReport? {
        let subnetSet = Set(localSubnets)
        while !Task.isCancelled {
            let cameras = browser.snapshot()
            let usable = cameras.filter { camera in
                guard let host = PTPIPPairedHosts.normalizedHost(camera.ip),
                    !excluded.contains(host),
                    let base = CameraDiscovery.subnetBase(for: host),
                    subnetSet.contains(base),
                    !CameraStartupPolicy.usesIPhoneHotspot(
                        host: host,
                        transport: "",
                        hotspotSubnetBases: NativeNetworkInterfaceSnapshot.hotspotSubnetBases())
                else { return false }
                return true
            }
            if !usable.isEmpty {
                return InfrastructureSearchReport(
                    cameras: CameraDiscovery.dedupeAndSort(usable),
                    localSubnets: localSubnets
                )
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func patientDirectedSearch(
        hosts: [String],
        guid: Data,
        excluded: Set<String>
    ) async -> InfrastructureSearchReport? {
        let schedule = InfrastructureDiscovery.patientProbeSchedule()
        let targets = hosts.filter { !excluded.contains($0) }
        guard !targets.isEmpty else { return nil }

        return await withTaskGroup(of: DiscoveredCamera?.self) { group in
            for host in targets {
                group.addTask {
                    await self.patientProbeHost(
                        host: host,
                        guid: guid,
                        attempts: schedule.attempts,
                        timeoutMilliseconds: schedule.timeoutMilliseconds
                    )
                }
            }
            var found: [DiscoveredCamera] = []
            for await camera in group {
                if let camera { found.append(camera) }
            }
            guard !found.isEmpty else { return nil }
            return InfrastructureSearchReport(cameras: CameraDiscovery.dedupeAndSort(found))
        }
    }

    private func patientProbeHost(
        host: String,
        guid: Data,
        attempts: Int,
        timeoutMilliseconds: UInt64
    ) async -> DiscoveredCamera? {
        for attempt in 1...attempts {
            if Task.isCancelled { return nil }
            let verdict = await PTPIPTransport.probePort(
                host: host, timeoutMilliseconds: timeoutMilliseconds)
            if verdict == .open {
                if let name = try? await PTPIPTransport.probeCameraName(
                    host: host,
                    guid: guid,
                    timeoutMilliseconds: InfrastructureDiscovery.identifyTimeoutMilliseconds
                ) {
                    logConnection(
                        "infra-search directed hit host=\(host) attempt=\(attempt) name=\(name)")
                    return DiscoveredCamera(ip: host, name: name, source: .subnetProbe)
                }
            } else {
                logConnection(
                    "infra-search directed host=\(host) attempt=\(attempt) verdict=\(verdict.rawValue)"
                )
            }
        }
        return nil
    }

    private func occupancySweepSearch(
        guid: Data,
        localSubnets: [String],
        localAddressSet: Set<String>,
        excluded: Set<String>,
        directed: [String],
        coreInterfaces: [LocalIPv4Interface]
    ) async -> InfrastructureSearchReport? {
        var allOccupied: Set<String> = []
        var allOpen: Set<String> = []
        // Every pass's counts, unioned — never one pass's numbers hand-patched with another's.
        var merged = InfrastructureSweepTally()

        for pass in 1...InfrastructureDiscovery.localSweepPasses {
            if Task.isCancelled { return nil }
            for subnet in localSubnets {
                let hosts =
                    CameraDiscovery.fastHosts(inSubnet: subnet)
                    .filter {
                        !excluded.contains($0) && !localAddressSet.contains($0)
                    }
                let scan = InfrastructureSweepTally.from(
                    verdicts: await PTPIPTransport.scanPorts(hosts: hosts))
                merged = merged.merging(scan)
                allOccupied.formUnion(scan.occupiedHosts)
                allOpen.formUnion(scan.openHosts)

                logConnection(
                    "infra-search sweep pass=\(pass) subnet=\(subnet) "
                        + "open=[\(scan.openHosts.joined(separator: " "))] "
                        + "occupied=[\(scan.occupiedHosts.prefix(24).joined(separator: " "))]")

                if !scan.openHosts.isEmpty {
                    let cameras = await identifyOpenHosts(scan.openHosts, guid: guid)
                    if !cameras.isEmpty {
                        return InfrastructureSearchReport(
                            cameras: CameraDiscovery.dedupeAndSort(cameras),
                            occupiedHosts: allOccupied.sorted(),
                            openPTPHosts: allOpen.sorted(),
                            localSubnets: localSubnets,
                            directedHosts: directed
                        )
                    }
                    // Port open but Init named nothing — still worth a patient re-probe.
                    logConnection(
                        "infra-search open hosts named no camera open=[\(scan.openHosts.joined(separator: " "))]"
                    )
                }
                // Hosts that refuse :15740 are on-link but not serving PTP. Log them so field
                // logs can see "we reached .246, it said closed" vs pure isolation.
                let closed = scan.occupiedHosts.filter { !scan.openHosts.contains($0) }
                if !closed.isEmpty {
                    logConnection(
                        "infra-search reachable-not-ptp=[\(closed.prefix(16).joined(separator: " "))]"
                    )
                }
            }
        }

        let miss = InfrastructureDiscovery.classifyMiss(
            preflight: .ready(interfaces: coreInterfaces),
            onCameraAccessPoint: false,
            tally: merged
        )
        return InfrastructureSearchReport(
            cameras: [],
            miss: miss,
            occupiedHosts: allOccupied.sorted(),
            openPTPHosts: allOpen.sorted(),
            localSubnets: localSubnets,
            directedHosts: directed
        )
    }

    private func identifyOpenHosts(_ hosts: [String], guid: Data) async -> [DiscoveredCamera] {
        await withTaskGroup(of: DiscoveredCamera?.self) { group in
            for host in hosts {
                group.addTask {
                    guard
                        let name = try? await PTPIPTransport.probeCameraName(
                            host: host,
                            guid: guid,
                            timeoutMilliseconds: InfrastructureDiscovery.identifyTimeoutMilliseconds
                        )
                    else { return nil }
                    return DiscoveredCamera(ip: host, name: name, source: .subnetProbe)
                }
            }
            var cameras: [DiscoveredCamera] = []
            for await camera in group {
                if let camera { cameras.append(camera) }
            }
            return cameras
        }
    }
}

// MARK: - Continuous Bonjour

/// Bonjour/mDNS browser that stays open until stopped — not a fixed 1.4 s one-shot.
// SAFETY: `@unchecked Sendable` — `lock` guards services/cameras/continuation state.
private final class ContinuousBonjourPTPBrowser: NSObject, NetServiceBrowserDelegate,
    NetServiceDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var cameras: [DiscoveredCamera] = []
    private var started = false

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        browser.delegate = self
        browser.searchForServices(ofType: "_ptp._tcp.", inDomain: "local.")
    }

    func stop() {
        lock.lock()
        browser.stop()
        browser.delegate = nil
        for service in services {
            service.delegate = nil
        }
        services.removeAll()
        started = false
        lock.unlock()
    }

    func snapshot() -> [DiscoveredCamera] {
        lock.lock()
        let output = cameras
        lock.unlock()
        return CameraDiscovery.dedupeAndSort(output)
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
        service.resolve(withTimeout: 2.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let resolved = (sender.addresses ?? []).compactMap(ipv4AddressFromSockaddrData).map {
            DiscoveredCamera(ip: $0, name: sender.name, source: .bonjour)
        }
        guard !resolved.isEmpty else { return }
        lock.lock()
        cameras.append(contentsOf: resolved)
        lock.unlock()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        logConnection("infra-search bonjour didNotSearch \(errorDict)")
    }
}

private func ipv4AddressFromSockaddrData(_ data: Data) -> String? {
    data.withUnsafeBytes { rawBuffer -> String? in
        guard let base = rawBuffer.baseAddress else { return nil }
        let socketAddress = base.assumingMemoryBound(to: sockaddr.self)
        guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var addr = socketAddress.pointee
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0,
                    socklen_t(data.count),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard result == 0 else { return nil }
        return String(cString: host)
    }
}
