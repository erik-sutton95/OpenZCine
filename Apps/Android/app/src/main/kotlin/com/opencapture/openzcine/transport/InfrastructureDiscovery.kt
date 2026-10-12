package com.opencapture.openzcine.transport

import com.opencapture.opencine.nikon.InfrastructureMissReason

/*
 * The Android side of an infrastructure (same-LAN Wi-Fi) search. The policy (preflight, sweep
 * tally, miss classification) is OpenCine's `InfrastructureDiscovery` in the nikon module, pinned
 * to Swift by shared vectors; this file keeps the report this app's finder returns and its copy.
 */

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
 * Operator-facing sentence for a miss.
 *
 * Short, and in the operator's words. The first iOS cut named the subnet in dotted notation,
 * spelled the camera's menus out as arrow chains and explained port 15740: all true, and none
 * of it what somebody standing in front of a camera needs. One thing to go and do, and the
 * address stays in the log where it is actually useful.
 *
 * Only [InfrastructureMissReason.LocalNetworkDenied] reads differently from iOS, because the
 * permission it names is a different one: iOS has a Local Network switch, Android gates nearby
 * Wi‑Fi devices instead.
 */
public fun InfrastructureMissReason.operatorCopy(cameraName: String? = null): String {
    val body = cameraName?.takeIf(String::isNotBlank) ?: "the camera"
    return when (this) {
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
            "Nothing on this network answered. Check both are on the same Wi‑Fi: a guest network or a 6 GHz band can keep them apart."
        is InfrastructureMissReason.HostsVisibleNoPtp ->
            "Other devices answer here, but $body doesn't. On the camera, start Connect to computer."
        is InfrastructureMissReason.CameraNotFound ->
            "Looking for $body on this Wi‑Fi. On the camera, start Connect to computer."
        is InfrastructureMissReason.HeldByOtherDevice ->
            "$body is in use by $holder."
    }
}
