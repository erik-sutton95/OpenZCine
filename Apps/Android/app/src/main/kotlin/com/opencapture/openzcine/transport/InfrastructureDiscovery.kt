package com.opencapture.openzcine.transport

import com.opencapture.opencine.nikon.HostProbeVerdict

/** Whether an infrastructure (same-LAN Wi‑Fi) search is allowed to run sockets. */
public sealed interface InfrastructurePreflight {
    /** At least one scannable IPv4 interface; search may proceed. */
    public data class Ready(val subnets: List<String>) : InfrastructurePreflight

    /** No private IPv4 interface is up — Wi‑Fi off, mobile data only, or no link. */
    public data object NoScannableInterface : InfrastructurePreflight

    /** The OS is withholding local-network access; LAN sockets will fail or time out. */
    public data object LocalNetworkDenied : InfrastructurePreflight
}

/**
 * Why a completed infrastructure search found no usable camera.
 *
 * Twin of the shared core's `InfrastructureMissReason`. These are the diagnoses that replace an
 * endless "Searching…" — the whole point of classifying a miss rather than just reporting one.
 */
public sealed interface InfrastructureMissReason {
    public data object LocalNetworkDenied : InfrastructureMissReason

    public data object NoScannableInterface : InfrastructureMissReason

    /** Phone is still on the body's own access point — an infrastructure setup can never fulfil. */
    public data object OnCameraAccessPoint : InfrastructureMissReason

    /** Almost no on-link activity — wrong network, or clients kept apart from each other. */
    public data object NetworkUnreachable : InfrastructureMissReason

    /** Hosts answer on the subnet, but nothing accepts PTP-IP. */
    public data object HostsVisibleNoPtp : InfrastructureMissReason

    /** Search budget exhausted without a camera, and without a stronger diagnosis. */
    public data object CameraNotFound : InfrastructureMissReason

    /** Another OpenZCine device holds the only known body. */
    public data class HeldByOtherDevice(val holder: String) : InfrastructureMissReason
}

/**
 * Counts from one occupancy (mute :15740) pass — the inputs classification needs, not a log.
 *
 * Twin of the shared core's `InfrastructureSweepTally`.
 */
public data class InfrastructureSweepTally(
    val openCount: Int = 0,
    val occupiedCount: Int = 0,
    val timeoutCount: Int = 0,
    val refusedCount: Int = 0,
    val noRouteCount: Int = 0,
    val deniedCount: Int = 0,
    val otherCount: Int = 0,
    val hostsProbed: Int = 0,
    val occupiedHosts: List<String> = emptyList(),
    val openHosts: List<String> = emptyList(),
) {
    /**
     * Merge another pass's counts in, keeping the union of what each pass saw.
     *
     * A body waking mid-search answers on pass two and not pass one; classification must see both.
     * This exists instead of hand-patching individual fields at the call site, which is where iOS
     * came to set `hostsProbed` from the OCCUPIED count — so a sweep where nothing answered
     * reported one host probed, and "nothing on this network answered" could never be reached.
     */
    public fun merging(other: InfrastructureSweepTally): InfrastructureSweepTally =
        InfrastructureSweepTally(
            openCount = maxOf(openCount, other.openCount),
            occupiedCount = maxOf(occupiedCount, other.occupiedCount),
            timeoutCount = maxOf(timeoutCount, other.timeoutCount),
            refusedCount = maxOf(refusedCount, other.refusedCount),
            noRouteCount = maxOf(noRouteCount, other.noRouteCount),
            deniedCount = maxOf(deniedCount, other.deniedCount),
            otherCount = maxOf(otherCount, other.otherCount),
            hostsProbed = maxOf(hostsProbed, other.hostsProbed),
            occupiedHosts = (occupiedHosts + other.occupiedHosts).distinct().sorted(),
            openHosts = (openHosts + other.openHosts).distinct().sorted(),
        )

    public companion object {
        /**
         * Build a tally from per-host verdicts. Exhaustive by construction: a verdict added to
         * [HostProbeVerdict] cannot be forgotten here without the compiler saying so.
         */
        public fun from(verdicts: Map<String, HostProbeVerdict>): InfrastructureSweepTally {
            var open = 0
            var refused = 0
            var timeout = 0
            var noRoute = 0
            var denied = 0
            var other = 0
            val openHosts = mutableListOf<String>()
            val occupiedHosts = mutableListOf<String>()
            for ((host, verdict) in verdicts) {
                when (verdict) {
                    HostProbeVerdict.OPEN -> open += 1
                    HostProbeVerdict.REFUSED -> refused += 1
                    HostProbeVerdict.TIMEOUT -> timeout += 1
                    HostProbeVerdict.NO_ROUTE, HostProbeVerdict.NO_NETWORK -> noRoute += 1
                    HostProbeVerdict.DENIED -> denied += 1
                    HostProbeVerdict.UNREACHABLE_OTHER -> other += 1
                }
                if (verdict == HostProbeVerdict.OPEN) openHosts.add(host)
                if (verdict.isOccupied) occupiedHosts.add(host)
            }
            return InfrastructureSweepTally(
                openCount = open,
                occupiedCount = occupiedHosts.size,
                timeoutCount = timeout,
                refusedCount = refused,
                noRouteCount = noRoute,
                deniedCount = denied,
                otherCount = other,
                hostsProbed = verdicts.size,
                occupiedHosts = occupiedHosts.sorted(),
                openHosts = openHosts.sorted(),
            )
        }
    }
}

/** One infrastructure search pass — cameras if any, else a typed miss and the evidence. */
public data class InfrastructureSearchReport(
    val cameras: List<DiscoveredCamera> = emptyList(),
    val miss: InfrastructureMissReason? = null,
    val occupiedHosts: List<String> = emptyList(),
) {
    public val foundCamera: Boolean
        get() = cameras.isNotEmpty()
}

/**
 * Pure infrastructure discovery policy — budgets, classification, operator copy.
 *
 * No sockets. The platform finder executes probes; this decides what the outcomes mean and how
 * patient a directed dial should be. Twin of the shared core's `InfrastructureDiscovery`; both are
 * tested against the same table, so a network can never mean one diagnosis on iPhone and another
 * on Android. Change one, change both. The dial budgets are `NikonDiscovery`'s.
 */
public object InfrastructureDiscovery {
    /** Classify an empty (or preflight-failed) infrastructure search. */
    public fun classifyMiss(
        preflight: InfrastructurePreflight,
        onCameraAccessPoint: Boolean,
        tally: InfrastructureSweepTally?,
        heldHolderName: String? = null,
    ): InfrastructureMissReason {
        if (preflight is InfrastructurePreflight.LocalNetworkDenied) {
            return InfrastructureMissReason.LocalNetworkDenied
        }
        if (preflight is InfrastructurePreflight.NoScannableInterface) {
            return InfrastructureMissReason.NoScannableInterface
        }
        if (onCameraAccessPoint) return InfrastructureMissReason.OnCameraAccessPoint
        if (!heldHolderName.isNullOrBlank()) {
            return InfrastructureMissReason.HeldByOtherDevice(heldHolderName)
        }
        if (tally == null || tally.hostsProbed <= 0) {
            return InfrastructureMissReason.CameraNotFound
        }
        if (tally.deniedCount > 0 && tally.occupiedCount == 0 && tally.openCount == 0) {
            return InfrastructureMissReason.LocalNetworkDenied
        }
        if (tally.occupiedCount == 0 && tally.openCount == 0) {
            // All timeout / no-route — cannot prove the LAN is live.
            val silent = tally.timeoutCount + tally.noRouteCount
            return if (silent >= maxOf(1, tally.hostsProbed / 2)) {
                InfrastructureMissReason.NetworkUnreachable
            } else {
                InfrastructureMissReason.CameraNotFound
            }
        }
        // The LAN is live (hosts refuse or answer) but nothing speaks PTP-IP.
        if (tally.openCount == 0 && tally.occupiedCount > 0) {
            return InfrastructureMissReason.HostsVisibleNoPtp
        }
        return InfrastructureMissReason.CameraNotFound
    }

    /**
     * Operator-facing sentence for a miss.
     *
     * Short, and in the operator's words. The first iOS cut named the subnet in dotted notation,
     * spelled the camera's menus out as arrow chains and explained port 15740 — all true, and none
     * of it what somebody standing in front of a camera needs. One thing to go and do, and the
     * address stays in the log where it is actually useful.
     *
     * Only [InfrastructureMissReason.LocalNetworkDenied] reads differently from iOS, because the
     * permission it names is a different one: iOS has a Local Network switch, Android gates nearby
     * Wi‑Fi devices instead.
     */
    public fun operatorCopy(
        reason: InfrastructureMissReason,
        cameraName: String? = null,
    ): String {
        val body = cameraName?.takeIf(String::isNotBlank) ?: "the camera"
        return when (reason) {
            is InfrastructureMissReason.LocalNetworkDenied ->
                "OpenZCine needs permission to find devices on your Wi‑Fi. Check its permissions in Settings."
            is InfrastructureMissReason.NoScannableInterface ->
                "This phone isn't on Wi‑Fi. Join the same network as $body."
            is InfrastructureMissReason.OnCameraAccessPoint ->
                "You're on $body's own Wi‑Fi. Join the network you want this setup to use, and we'll keep looking."
            is InfrastructureMissReason.NetworkUnreachable ->
                // Names the cause that actually bit, rather than a generic "check your Wi-Fi". A
                // Wi-Fi 7 router running 6 GHz with MLO put a phone and a camera on links it would
                // not bridge: same network, same subnet, addresses from the same DHCP server, and
                // no packet between them. Days went into that one, with the app saying
                // "Searching…" throughout. Naming a band an operator can switch off is worth it.
                "Nothing on this network answered. Check both are on the same Wi‑Fi — a guest network or a 6 GHz band can keep them apart."
            is InfrastructureMissReason.HostsVisibleNoPtp ->
                "Other devices answer here, but $body doesn't. On the camera, start Connect to computer."
            is InfrastructureMissReason.CameraNotFound ->
                "Looking for $body on this Wi‑Fi. On the camera, start Connect to computer."
            is InfrastructureMissReason.HeldByOtherDevice ->
                "$body is in use by ${reason.holder}."
        }
    }
}
