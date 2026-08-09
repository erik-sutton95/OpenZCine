import Foundation

// MARK: - Preflight

/// Whether an infrastructure (same-LAN Wi‑Fi) search is allowed to run sockets.
public enum InfrastructurePreflight: Equatable, Sendable {
    /// At least one scannable IPv4 interface; search may proceed.
    case ready(interfaces: [LocalIPv4Interface])
    /// No private IPv4 interface is up — Wi‑Fi off, cellular only, or no link.
    case noScannableInterface
    /// iOS Local Network permission is denied; LAN sockets will time out or fail.
    case localNetworkDenied
}

// MARK: - Miss reasons

/// Why a completed infrastructure search found no usable camera.
///
/// Ordered for classification priority (most actionable / earliest exit first). These are the
/// operator-facing diagnoses industry LAN tools surface instead of an endless "Searching…".
public enum InfrastructureMissReason: Equatable, Sendable {
    case localNetworkDenied
    case noScannableInterface
    /// Phone is still on the body's own access point — infrastructure shape can never fulfill.
    case onCameraAccessPoint
    /// Almost no on-link activity (gateway and hosts time out) — wrong network, isolation, or
    /// permission that presents as total silence.
    case networkUnreachable
    /// Hosts answer ARP/TCP on the subnet, but nothing accepts PTP-IP (:15740).
    /// Camera not in Connect to PC, or client isolation between phone and body.
    case hostsVisibleNoPTP
    /// Search budget exhausted without a camera (and without a stronger diagnosis).
    case cameraNotFound
    /// Another OpenZCine device holds the only known body.
    case heldByOtherDevice(holder: String)
}

// MARK: - Host probe verdict

/// What a single dial at one host actually did.
///
/// This was a `String` passed between the transport, two sweeps and the tally, and it had already
/// drifted: the tally handled a `"reset"` nobody produced, while `"no-fds"` and `"errno-…"` fell
/// into `other` and quietly counted as evidence the network was fine. A miscounted verdict is not
/// a cosmetic problem — it is what the operator is told to go and do next.
public enum HostProbeVerdict: String, Codable, Sendable, CaseIterable {
    /// TCP accepted. Something is serving this port.
    case open
    /// RST. A host is there and is not serving this port — a router, a laptop, a TV.
    case refused
    /// No answer inside the budget. Nobody holds the address, or nothing can reach it.
    case timeout
    /// EHOSTUNREACH — on-link and unanswered at the link layer.
    case noRoute
    /// ENETUNREACH — no route to that network at all.
    case noNetwork
    /// EACCES / EPERM. The OS refused us the dial; says nothing about the host.
    case denied
    /// Anything else, including running out of descriptors. Never evidence about the host.
    case unreachableOther

    /// Whether SOMETHING holds this address.
    ///
    /// Only an answer proves occupancy. A refusal is an answer; silence and a denied dial are not.
    public var isOccupied: Bool {
        switch self {
        case .open, .refused: return true
        case .timeout, .noRoute, .noNetwork, .denied, .unreachableOther: return false
        }
    }

    /// Whether this verdict is the network declining to carry us, rather than a quiet host.
    public var isSilence: Bool {
        switch self {
        case .timeout, .noRoute, .noNetwork: return true
        case .open, .refused, .denied, .unreachableOther: return false
        }
    }
}

// MARK: - Sweep tally (pure input to classification)

/// Counts from one occupancy (mute :15740) pass — the inputs classification needs, not a log.
public struct InfrastructureSweepTally: Equatable, Sendable {
    public var openCount: Int
    public var occupiedCount: Int
    public var timeoutCount: Int
    public var refusedCount: Int
    public var noRouteCount: Int
    public var deniedCount: Int
    public var otherCount: Int
    public var hostsProbed: Int
    public var occupiedHosts: [String]
    public var openHosts: [String]

    public init(
        openCount: Int = 0,
        occupiedCount: Int = 0,
        timeoutCount: Int = 0,
        refusedCount: Int = 0,
        noRouteCount: Int = 0,
        deniedCount: Int = 0,
        otherCount: Int = 0,
        hostsProbed: Int = 0,
        occupiedHosts: [String] = [],
        openHosts: [String] = []
    ) {
        self.openCount = openCount
        self.occupiedCount = occupiedCount
        self.timeoutCount = timeoutCount
        self.refusedCount = refusedCount
        self.noRouteCount = noRouteCount
        self.deniedCount = deniedCount
        self.otherCount = otherCount
        self.hostsProbed = hostsProbed
        self.occupiedHosts = occupiedHosts
        self.openHosts = openHosts
    }

    /// Build a tally from per-host verdicts. Exhaustive by construction: a verdict added to
    /// ``HostProbeVerdict`` cannot be forgotten here without the compiler saying so.
    public static func from(verdicts: [String: HostProbeVerdict]) -> InfrastructureSweepTally {
        var tally = InfrastructureSweepTally(hostsProbed: verdicts.count)
        var occupied: [String] = []
        var open: [String] = []
        for (host, verdict) in verdicts {
            switch verdict {
            case .open: tally.openCount += 1
            case .refused: tally.refusedCount += 1
            case .timeout: tally.timeoutCount += 1
            case .noRoute, .noNetwork: tally.noRouteCount += 1
            case .denied: tally.deniedCount += 1
            case .unreachableOther: tally.otherCount += 1
            }
            if verdict == .open { open.append(host) }
            if verdict.isOccupied { occupied.append(host) }
        }
        tally.occupiedCount = occupied.count
        tally.occupiedHosts = occupied.sorted()
        tally.openHosts = open.sorted()
        return tally
    }

    /// Merge another pass's counts in, keeping the union of what each pass saw.
    ///
    /// A body waking mid-search answers on pass two and not pass one; classification must see
    /// both. This replaced hand-patching individual fields at the call site, which is where
    /// `hostsProbed` came to be set from the OCCUPIED count — so a sweep where nothing answered
    /// reported one host probed, and "nothing on this network answered" could never be reached.
    public func merging(_ other: InfrastructureSweepTally) -> InfrastructureSweepTally {
        InfrastructureSweepTally(
            openCount: max(openCount, other.openCount),
            occupiedCount: max(occupiedCount, other.occupiedCount),
            timeoutCount: max(timeoutCount, other.timeoutCount),
            refusedCount: max(refusedCount, other.refusedCount),
            noRouteCount: max(noRouteCount, other.noRouteCount),
            deniedCount: max(deniedCount, other.deniedCount),
            otherCount: max(otherCount, other.otherCount),
            hostsProbed: max(hostsProbed, other.hostsProbed),
            occupiedHosts: Array(Set(occupiedHosts).union(other.occupiedHosts)).sorted(),
            openHosts: Array(Set(openHosts).union(other.openHosts)).sorted()
        )
    }
}

// MARK: - Report

/// One infrastructure search pass — cameras if any, else a typed miss and the evidence.
public struct InfrastructureSearchReport: Equatable, Sendable {
    public var cameras: [DiscoveredCamera]
    public var miss: InfrastructureMissReason?
    public var occupiedHosts: [String]
    public var openPTPHosts: [String]
    public var localSubnets: [String]
    public var directedHosts: [String]

    public init(
        cameras: [DiscoveredCamera] = [],
        miss: InfrastructureMissReason? = nil,
        occupiedHosts: [String] = [],
        openPTPHosts: [String] = [],
        localSubnets: [String] = [],
        directedHosts: [String] = []
    ) {
        self.cameras = cameras
        self.miss = miss
        self.occupiedHosts = occupiedHosts
        self.openPTPHosts = openPTPHosts
        self.localSubnets = localSubnets
        self.directedHosts = directedHosts
    }

    public var foundCamera: Bool { !cameras.isEmpty }
}

// MARK: - Policy

/// Pure infrastructure discovery policy — budgets, classification, operator copy.
///
/// No sockets. Platform finders execute probes; this module decides what the outcomes mean and
/// how patient a directed dial should be (ZR Wi‑Fi power-save is ~1.0–1.2 s per HW 2026-08-04).
public enum InfrastructureDiscovery: Sendable {
    /// How many times a directed (known) host is dialled before giving up that address.
    public static let directedAttemptCount = 3
    /// Per-attempt connect budget for a directed host (ms). Longer than the blind sweep so a
    /// body that woke on the first SYN still has room if the mesh is slow.
    public static let directedTimeoutMilliseconds: UInt64 = 2_000
    /// Blind mute-scan budget per host (ms) — matches measured power-save answer time + margin.
    public static let blindSweepTimeoutMilliseconds: UInt64 = 1_500
    /// Concurrent mute dials in the occupancy sweep.
    public static let sweepConcurrency = 48
    /// Init / name probe after a port opens (ms).
    public static let identifyTimeoutMilliseconds: UInt64 = 2_000
    /// How many full local-/24 occupancy passes before declaring a miss (body may wake mid-search).
    public static let localSweepPasses = 2

    /// Directed patient-probe schedule: `attempts` × `timeoutMilliseconds`.
    public static func patientProbeSchedule(
        attempts: Int = directedAttemptCount,
        timeoutMilliseconds: UInt64 = directedTimeoutMilliseconds
    ) -> (attempts: Int, timeoutMilliseconds: UInt64) {
        (max(1, attempts), timeoutMilliseconds)
    }

    /// Hosts worth a patient directed probe: priority list filtered to current local subnets.
    ///
    /// A sibling setup on another network (e.g. portable travel router) must not be dialled when
    /// adding a new infrastructure setup — that was a field false-fail (`191f3fd6`).
    public static func directedHosts(
        candidates: [String],
        localSubnets: [String],
        excluded: Set<String> = []
    ) -> [String] {
        let subnetSet = Set(localSubnets)
        var seen: Set<String> = []
        var output: [String] = []
        for raw in candidates {
            guard let host = PTPIPPairedHosts.normalizedHost(raw),
                !DiscoveredCamera.isUSBHostKey(host),
                !excluded.contains(host),
                !seen.contains(host),
                let base = CameraDiscovery.subnetBase(for: host),
                subnetSet.contains(base)
            else { continue }
            seen.insert(host)
            output.append(host)
        }
        return output
    }

    /// Classify an empty (or preflight-failed) infrastructure search.
    public static func classifyMiss(
        preflight: InfrastructurePreflight,
        onCameraAccessPoint: Bool,
        tally: InfrastructureSweepTally?,
        heldHolderName: String? = nil
    ) -> InfrastructureMissReason {
        if case .localNetworkDenied = preflight { return .localNetworkDenied }
        if case .noScannableInterface = preflight { return .noScannableInterface }
        if onCameraAccessPoint { return .onCameraAccessPoint }
        if let holder = heldHolderName, !holder.isEmpty {
            return .heldByOtherDevice(holder: holder)
        }
        guard let tally, tally.hostsProbed > 0 else {
            return .cameraNotFound
        }
        // Permission / total blackhole: nothing reachable, many timeouts, or explicit denied.
        if tally.deniedCount > 0, tally.occupiedCount == 0, tally.openCount == 0 {
            return .localNetworkDenied
        }
        if tally.occupiedCount == 0, tally.openCount == 0 {
            // All timeout / no-route — cannot prove the LAN is live.
            let silent = tally.timeoutCount + tally.noRouteCount
            if silent >= max(1, tally.hostsProbed / 2) {
                return .networkUnreachable
            }
            return .cameraNotFound
        }
        // LAN is live (hosts refuse or answer) but nothing speaks PTP-IP.
        if tally.openCount == 0, tally.occupiedCount > 0 {
            return .hostsVisibleNoPTP
        }
        // Ports opened but Init did not yield a camera (unlikely; still a miss).
        return .cameraNotFound
    }

    /// Operator-facing sentence for a miss.
    ///
    /// Short, and in the operator's words. The first cut named the subnet in dotted notation,
    /// spelled the camera's menus out as arrow chains and explained port 15740 — all true, and
    /// none of it what somebody standing in front of a camera needs. One thing to go and do,
    /// and the address stays in the log where it is actually useful.
    public static func operatorCopy(
        for reason: InfrastructureMissReason,
        cameraName: String? = nil
    ) -> String {
        let body = cameraName ?? "the camera"
        switch reason {
        case .localNetworkDenied:
            return "OpenZCine needs Local Network access to find cameras. Turn it on in Settings."
        case .noScannableInterface:
            return "This phone isn't on Wi‑Fi. Join the same network as \(body)."
        case .onCameraAccessPoint:
            return
                "You're on \(body)'s own Wi‑Fi. Join the network you want this setup to use, and we'll keep looking."
        case .networkUnreachable:
            // Names the cause that actually bit, rather than a generic "check your Wi-Fi". A
            // Wi-Fi 7 router running 6 GHz with MLO put this phone and the camera on links it
            // would not bridge: same network, same subnet, addresses from the same DHCP server,
            // and no packet between them. Days went into that one, and the app said "Searching…"
            // throughout. Naming a band an operator can switch off is worth the extra clause.
            return
                "Nothing on this network answered. Check both are on the same Wi‑Fi — a guest network or a 6 GHz band can keep them apart."
        case .hostsVisibleNoPTP:
            return
                "Other devices answer here, but \(body) doesn't. On the camera, start Connect to computer."
        case .cameraNotFound:
            return "Looking for \(body) on this Wi‑Fi. On the camera, start Connect to computer."
        case .heldByOtherDevice(let holder):
            return "\(body) is in use by \(holder)."
        }
    }
}
