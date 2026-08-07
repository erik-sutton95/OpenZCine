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
        probesCameras: Bool = true,
        browsesUSB: Bool = true,
        status: @MainActor @escaping (String) -> Void = { _ in },
        onRelayPresences: @MainActor @escaping ([String: RelayPresence]) -> Void = { _ in }
    ) async throws -> [DiscoveredCamera] {
        // USB-attached cameras are browser-driven and effectively instant; surface them without
        // waiting for the network passes. Starting the browser here is safe — discovery only runs
        // after first render, past the known too-early ICC authorization hang. Gated: exercising
        // ICC camera control makes the OS show its "Using Camera Access to Control Connected
        // Cameras" disclosure on every launch, so a device with no cable in play (no saved
        // USB-C setup, not on the pairing surface) must never start the browser.
        let usbBrowser = USBCameraDeviceBrowser.shared
        if browsesUSB { usbBrowser.start() }
        let usbCameras = browsesUSB ? usbBrowser.attachedCameras() : []

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
            Self.storeHeldCameras(
                Dictionary(
                    hits.compactMap { _, presence -> (String, String)? in
                        guard let served = presence.ch, !served.isEmpty else { return nil }
                        return (served, presence.n)
                    },
                    uniquingKeysWith: { first, _ in first }))
        } else {
            // Throttled pass: reuse the last completed sweep's shield rather than probing
            // naked. The 30 s slot exists to bound radio load, not to strip protection from
            // the passes in between (pull-to-refresh runs a full pass every pull).
            presenceShieldedHosts = Self.cachedPresenceShield()
        }
        let shielded = presenceShieldedHosts
        // A camera another device is holding is SHIELDED, not absent — this pass will never probe
        // it, and it used to be dropped on the floor with it. That is what left the pairing list
        // empty and searching forever on a network where the app could name the camera, the
        // address, and the device holding it. Listing it says all three and leaves the decision
        // to take it over where it belongs: with the operator, on the row.
        let heldRows: [DiscoveredCamera] = heldCameraRows()

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
        // The camera LIST never speaks PTP (probesCameras == false): with multiple devices on
        // one network, any idle device's Init drops the body's live session — the single-
        // initiator drop mechanism this file's shields only ever mitigated. A saved host's
        // readiness comes from a kernel-level liveness dial instead (`checkHostAlive`): RST on
        // the presence port proves the address is occupied, and the PTP layer never hears it.
        // Probing remains the PAIRING surface's tool — a pairing-wait body advertises nothing
        // (HW-established), so an operator deliberately standing one up still needs it.
        if !probesCameras {
            let livenessHosts = Set(
                priorityHosts
                    .filter { !$0.hasPrefix(DiscoveredCamera.usbHostKeyPrefix) }
                    .compactMap(PTPIPPairedHosts.normalizedHost)
            ).subtracting(bonjourHosts)
            var aliveRows: [DiscoveredCamera] = []
            if !livenessHosts.isEmpty {
                aliveRows = await withTaskGroup(of: (String, Bool).self) { group in
                    for host in livenessHosts {
                        group.addTask { (host, await Self.checkHostAlive(host: host)) }
                    }
                    var rows: [DiscoveredCamera] = []
                    for await (host, alive) in group where alive {
                        rows.append(DiscoveredCamera(ip: host, name: nil, source: .liveness))
                    }
                    return rows
                }
            }
            return CameraDiscovery.dedupeAndSort(
                (browsesUSB ? usbBrowser.attachedCameras() : []) + bonjour + aliveRows)
        }
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
        return CameraDiscovery.dedupeAndSort(
            usbBrowser.attachedCameras() + probeResults + heldRows)
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
        // Where to look, nearest-first, from the real prefix rather than a guess at it. Our own
        // subnet stays first and resolves in one round; the neighbours behind it are what reach a
        // camera the old plan could not see at all.
        let plannedSubnets = SubnetScanPlan.orderedSubnets(
            interfaces: scanInterfaces.map {
                LocalIPv4Interface(name: $0.name, address: $0.address, netmask: $0.netmask)
            },
            savedHosts: priorityHosts
        )
        let localAddressSet = Set(localAddresses.compactMap(PTPIPPairedHosts.normalizedHost))
        // The subnets this device is actually standing in are always swept; the rest of the ladder
        // is earned, one rung per empty pass, so the common case costs exactly what it did before
        // the ladder existed.
        let localSubnets = Set(
            scanInterfaces.compactMap { CameraDiscovery.subnetBase(for: $0.address) })
        let networkSignature = scanInterfaces.map(\.address).sorted().joined(separator: ",")
        let budget = Self.subnetBudget(
            signature: networkSignature, localCount: max(1, localSubnets.count))
        let sweptSubnets = Array(plannedSubnets.prefix(budget))
        let sweepHosts =
            sweptSubnets
            .flatMap(CameraDiscovery.fastHosts(inSubnet:))
            .filter { !excluded.contains($0) && !localAddressSet.contains($0) }
        let candidateChunks =
            [priorityChunk].filter { !$0.isEmpty } + sweepHosts.chunked(into: 254)
        // Sweep-pass witness. Counts only for the hosts — a /24 listing would drown the Console —
        // but the INTERFACES are named, and that is the fact the counts cannot carry: a sweep
        // that finds nothing looks identical whether the camera is absent or this device is
        // simply on a different network from it. "hosts=256, found nothing" answers neither
        // question; "en0 192.168.1.42" answers both the moment you know where the camera is.
        let interfaceWitness =
            scanInterfaces.map {
                let prefix = SubnetScanPlan.prefixLength(netmask: $0.netmask).map { "/\($0)" }
                return "\($0.name) \($0.address)\(prefix ?? "")"
            }.joined(separator: ", ")
        logConnection(
            "discovery sweep pass hosts=\(candidateChunks.reduce(0) { $0 + $1.count }) "
                + "excluded=\(excluded.count) on=[\(interfaceWitness)] "
                + "subnets=[\(sweptSubnets.joined(separator: " "))] of \(plannedSubnets.count)")

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
        for (index, chunk) in candidateChunks.enumerated() {
            // The priority chunk is a handful of addresses a camera has really answered on, so it
            // goes straight to the Init that names them — one round trip for the common case.
            // Everything after it is a blind subnet, and blind subnets take the two-pass route.
            let hostsToIdentify: [String]
            if index == 0, !priorityChunk.isEmpty {
                hostsToIdentify = chunk
            } else {
                // PASS ONE, wide and mute: connect to the PTP port and hang up, sending no PTP
                // bytes. This is what makes a wide search affordable and safe at once — the old
                // sweep aimed a real Init at all 254 hosts of one subnet, which is both slower and
                // more disturbance than this is across a dozen.
                hostsToIdentify = await withTaskGroup(of: String?.self) { group in
                    for host in chunk {
                        group.addTask {
                            await PTPIPTransport.probePortOpen(host: host) ? host : nil
                        }
                    }
                    var open: [String] = []
                    for await host in group {
                        if let host { open.append(host) }
                    }
                    return open.sorted()
                }
                if !hostsToIdentify.isEmpty {
                    logConnection(
                        "discovery sweep port-open [\(hostsToIdentify.joined(separator: " "))]")
                }
            }
            guard !hostsToIdentify.isEmpty else { continue }
            // PASS TWO, narrow: the Init that separates a camera from anything else listening on
            // 15740, against the few hosts that answered rather than every address in the plan.
            let chunkResults = await withTaskGroup(of: DiscoveredCamera?.self) { group in
                for host in hostsToIdentify {
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

        Self.recordSweepOutcome(
            signature: networkSignature, foundCamera: !discovered.isEmpty)
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
        return await withTaskGroup(of: (String, Result<DiscoveredCamera?, Error>).self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        return (host, .success(try await self.probe(host: host, guid: guid)))
                    } catch {
                        return (host, .failure(error))
                    }
                }
            }
            var results: [DiscoveredCamera] = []
            var verdicts: [String] = []
            for await (host, outcome) in group {
                switch outcome {
                case .success(let camera?):
                    results.append(camera)
                case .success(nil):
                    // Answered, but not as a camera this app can use.
                    verdicts.append("\(host)=no-camera")
                case .failure(let error):
                    verdicts.append("\(host)=\(Self.probeVerdict(for: error))")
                }
            }
            // Only when the pass found NOTHING, and this is the whole point: the outcome used to
            // be swallowed by `try?`, so a denied local-network permission, a host with no route,
            // a refused port and a camera that simply is not there all printed as the same
            // silence. "Can't find the camera" is unanswerable without this line.
            if results.isEmpty, !verdicts.isEmpty {
                logConnection(
                    "discovery probe verdicts \(verdicts.sorted().joined(separator: " "))")
            }
            return results
        }
    }

    /// A short, greppable name for why one probe failed.
    ///
    /// `NSPOSIXErrorDomain` codes are the ones that separate the diagnoses that matter:
    /// unreachable means the network is wrong, refused means the host is there but nothing is
    /// listening, and timeout means it answered nothing at all — which on iOS is also what a
    /// denied Local Network permission looks like from here.
    private static func probeVerdict(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ECONNREFUSED: return "refused"
            case EHOSTUNREACH: return "no-route"
            case ENETUNREACH: return "no-network"
            case ETIMEDOUT: return "timeout"
            case ECONNRESET: return "reset"
            default: return "posix-\(nsError.code)"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "\(nsError.domain)-\(nsError.code)"
    }

    /// How many consecutive sweeps have found nothing, per network.
    ///
    /// The widening ladder is a FALLBACK, not a default. A camera is nearly always on the subnet
    /// this device is standing in, and paying twelve subnets on every pass to cover the case where
    /// it is not made the common case twelve times slower — the field verdict on the first cut was
    /// "took forever", with the camera one address away on our own /24 the whole time.
    ///
    /// Keyed by the interface signature so walking onto a different network starts the ladder over
    /// rather than inheriting the last one's despair.
    private static let sweepWideningSlot = OSAllocatedUnfairLock(
        initialState: (signature: "", emptyPasses: 0))

    /// How many subnets this pass may sweep: the local ones always, plus one more for each empty
    /// pass past the grace period.
    private static func subnetBudget(signature: String, localCount: Int) -> Int {
        sweepWideningSlot.withLock { state in
            if state.signature != signature {
                state.signature = signature
                state.emptyPasses = 0
            }
            let grace = 2
            let widened = max(0, state.emptyPasses - grace)
            return min(SubnetScanPlan.maximumSubnets, max(localCount, localCount + widened))
        }
    }

    private static func recordSweepOutcome(signature: String, foundCamera: Bool) {
        sweepWideningSlot.withLock { state in
            if state.signature != signature {
                state.signature = signature
                state.emptyPasses = 0
            }
            state.emptyPasses = foundCamera ? 0 : state.emptyPasses + 1
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

    /// Camera host → the device that says it is holding it, from the last completed sweep.
    ///
    /// Cached beside the shield and for the same reason: the throttled passes between sweeps must
    /// show the operator the same picture the sweep found, not an empty list every other second.
    private static let heldCameraSlot = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func storeHeldCameras(_ held: [String: String]) {
        heldCameraSlot.withLock { $0 = held }
    }

    /// The in-use rows for this pass: every camera a nearby device claims, named by its holder.
    private func heldCameraRows() -> [DiscoveredCamera] {
        Self.heldCameraSlot.withLock { $0 }
            .map { host, holder in
                DiscoveredCamera(
                    ip: host, name: nil, source: .heldByAnotherDevice, heldByDeviceName: holder)
            }
            .sorted { $0.ip < $1.ip }
    }

    /// One unicast presence read (`MonitorRelayProtocol.presenceTCPPort`), bounded. Nil for
    /// refused, timed out, or garbage — only a genuine OpenZCine presence line answers.
    /// Raw POSIX socket on purpose: an NWConnection version, even one whose deadline called
    /// `cancel()`, still left flows retransmitting SYNs on device until the kernel's ~75 s
    /// connect timeout (field log: :15741 flows dying at SO_ERROR 60 long after their 500 ms
    /// deadline) — and a /24 of those every 30 s stalls the very broadcaster feed presence
    /// exists to protect. `close(fd)` ends retransmission unconditionally; the PTP subnet
    /// probe has swept on this pattern for weeks without one lingering-flow console line.
    static func checkRelayPresence(
        host: String, timeoutMilliseconds: Int = 500
    ) async -> RelayPresence? {
        await withCheckedContinuation { continuation in
            presenceProbeQueue.async {
                let probe = rawPresenceProbe(
                    host: host,
                    port: MonitorRelayProtocol.presenceTCPPort,
                    timeoutMilliseconds: Int32(clamping: timeoutMilliseconds))
                continuation.resume(returning: probe.line.flatMap(RelayPresence.decode))
            }
        }
    }

    /// Whether SOMETHING lives at `host`, without one byte reaching any application service:
    /// a dial to the presence port that a non-OpenZCine host answers with a kernel RST
    /// ("refused") proves the address is occupied. This is the camera list's ONLY wireless
    /// readiness signal — a PTP Init from an idle device drops another device's live session,
    /// so the list never sends one. HW-measured 2026-08-04: the body RSTs in ~1.0–1.2 s
    /// (Wi-Fi power-save cadence), hence the longer default deadline than the /24 sweep's.
    static func checkHostAlive(
        host: String, timeoutMilliseconds: Int = 1500
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            presenceProbeQueue.async {
                let probe = rawPresenceProbe(
                    host: host,
                    port: MonitorRelayProtocol.presenceTCPPort,
                    timeoutMilliseconds: Int32(clamping: timeoutMilliseconds))
                continuation.resume(returning: probe.reachedHost)
            }
        }
    }

    /// Probes block a worker in `poll` for ≤2× the timeout, so they run on their own concurrent
    /// GCD queue — never the cooperative pool, which a 64-wide sweep chunk would starve.
    private static let presenceProbeQueue = DispatchQueue(
        label: "com.opencapture.openzcine.presence-probe", attributes: .concurrent)

    /// Bounded connect + single read. Blocking by design (see callers).
    /// `reachedHost` is true when the address is provably occupied — the connect succeeded OR
    /// something refused it (a kernel RST needs a live host). `line` carries the presence
    /// answer when the port was actually served. Timeout / no route / no ARP answer → neither.
    private static func rawPresenceProbe(
        host: String, port: UInt16, timeoutMilliseconds: Int32
    ) -> (reachedHost: Bool, line: Data?) {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return (false, nil) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, nil) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var noSigpipe: Int32 = 1
        setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                return (errno == ECONNREFUSED, nil)
            }
            var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&writable, 1, timeoutMilliseconds) == 1 else { return (false, nil) }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                return (socketError == ECONNREFUSED, nil)
            }
        }
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&readable, 1, timeoutMilliseconds) == 1 else { return (true, nil) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return (true, nil) }
        return (true, Data(buffer.prefix(received)))
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

private struct NativeLocalIPv4Interface: Sendable {
    let name: String
    let address: String
    /// The prefix the OS actually assigned. Read and then discarded for years, which is why a
    /// device on a wide subnet only ever searched 1/256th of its own link.
    let netmask: String?
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

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
