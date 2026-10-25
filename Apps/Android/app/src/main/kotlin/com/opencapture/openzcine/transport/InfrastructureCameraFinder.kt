package com.opencapture.openzcine.transport

import android.util.Log
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.nikon.HostProbeVerdict
import com.opencapture.opencine.nikon.InfrastructureDiscovery
import com.opencapture.opencine.nikon.InfrastructureMissReason
import com.opencapture.opencine.nikon.InfrastructurePreflight
import com.opencapture.opencine.nikon.InfrastructureSweepTally
import com.opencapture.opencine.nikon.NikonDialer
import com.opencapture.opencine.nikon.NikonDiscovery
import com.opencapture.opencine.nikon.NikonHosts
import com.opencapture.opencine.nikon.NikonLocalInterface
import com.opencapture.opencine.nikon.NikonPresence
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Isolated infrastructure (same-LAN Wi‑Fi) camera search — the Android twin of iOS
 * `InfrastructureCameraFinder`.
 *
 * Owns discovery for the Wi‑Fi path only: patient directed probes at addresses a camera has
 * answered on before, then an occupancy-first sweep of the subnets this device is standing in.
 * Contains **no** Wi‑Fi join surface — that bug class stays unrepresentable (see
 * `docs/transport-architecture.md`).
 *
 * Why this exists at all: before it, Android could find a camera two ways — mDNS, and a liveness
 * dial of hosts *already saved*. A camera on a Wi‑Fi network this phone had never paired with, or
 * whose DHCP lease had moved, could not be found at all, while the same camera and the same
 * network worked on iPhone.
 *
 * One deliberate difference from iOS, worth knowing before reading the code: iOS names a swept
 * host with a PTP `Init` before offering it, and Android has no standalone name probe — its
 * handshake lives inside the Swift core session. So a host that ACCEPTS :15740 is offered with
 * whatever name mDNS knew, and the connect itself is the identification. Nothing else answers on
 * that port in practice, and a non-camera fails its Init immediately with a clear message.
 */
public class InfrastructureCameraFinder(
    /**
     * Where the search narrates itself. Injected because `android.util.Log` throws on the JVM,
     * and a sweep whose every decision is untestable is how the iOS one went three field logs
     * without anyone being able to say why it found nothing.
     */
    private val log: (String) -> Unit = { Log.i(TAG, it) },
    private val scanner: PortScanner = PortScanner { host, timeoutMillis ->
        SocketNikonDialer.scanControlPort(host, timeoutMillis)
    },
) {
    /** The seam that dials a host, so the sweep is testable without a network. */
    public fun interface PortScanner {
        public suspend fun probe(host: String, timeoutMillis: Int): HostProbeVerdict
    }

    /**
     * One complete infrastructure search pass: OpenCine's `NikonDiscovery` active search (patient
     * directed dials, then an occupancy sweep stopping at the first open host), with this app's
     * miss diagnosis over what the sweep dials heard. No presence sweep runs here, so no presence
     * shield applies (SHELL-02 D12: the pairing sweep shield is a separate, device-qualified change).
     *
     * @param directedCandidates saved / dialling hosts; filtered to the current local subnets.
     * @param knownNames host → camera name from mDNS, when the browse has already resolved one.
     * @param excludedHosts served / shielded hosts that must not be dialled.
     * @param onCameraAccessPoint the phone is still on the body's own AP; nothing here can fulfil.
     */
    public suspend fun search(
        directedCandidates: List<String> = emptyList(),
        knownNames: Map<String, String> = emptyMap(),
        excludedHosts: Set<String> = emptySet(),
        onCameraAccessPoint: Boolean = false,
        interfaces: List<NikonLocalInterface> = localIPv4Interfaces(),
    ): InfrastructureSearchReport {
        if (onCameraAccessPoint) {
            return InfrastructureSearchReport(miss = InfrastructureMissReason.OnCameraAccessPoint)
        }
        val localSubnets =
            interfaces.map { it.address }.filter(NikonHosts::isPrivateIPv4).mapNotNull(NikonHosts::subnetBase).distinct().sorted()
        if (localSubnets.isEmpty()) {
            return InfrastructureSearchReport(miss = InfrastructureMissReason.NoScannableInterface)
        }
        // NikonDiscovery drops excluded, own and off-subnet hosts; this keeps the app's stricter
        // subnet text match (a zero-padded octet never matches).
        val directed = directedCandidates.filter { it.trim().takeIf(NikonHosts::isPrivateIPv4)?.substringBeforeLast('.') in localSubnets }
        // What the occupancy sweep heard, per host; an answer in any pass outranks silence.
        val swept = java.util.concurrent.ConcurrentHashMap<String, HostProbeVerdict>()
        val dialer =
            object : NikonDialer {
                override suspend fun presence(host: String): NikonPresence? = null

                override suspend fun isAlive(host: String): Boolean = false

                override suspend fun scanControlPort(host: String, timeoutMillis: Int): HostProbeVerdict {
                    val verdict = scanner.probe(host, timeoutMillis)
                    if (timeoutMillis == NikonDiscovery.DIRECTED_TIMEOUT_MILLIS) {
                        log("infra-search directed host=$host verdict=$verdict")
                    } else {
                        swept.merge(host, verdict) { old, new -> if (old.isOccupied) old else new }
                    }
                    return verdict
                }
            }
        val result =
            NikonDiscovery(dialer, { interfaces }, log)
                .search(DiscoveryMode.ACTIVE, directed, excludedHosts)
        val tally = InfrastructureSweepTally.from(swept)
        if (result.openHosts.isNotEmpty()) {
            return InfrastructureSearchReport(
                cameras = result.openHosts.map { camera(it, knownNames) },
                occupiedHosts = tally.occupiedHosts,
            )
        }
        val miss =
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(localSubnets),
                onCameraAccessPoint = false,
                tally = tally,
            )
        log(
            "infra-search miss=$miss open=[${tally.openHosts.joinToString(" ")}] " +
                "occupied=[${tally.occupiedHosts.take(24).joinToString(" ")}]",
        )
        return InfrastructureSearchReport(
            miss = miss,
            occupiedHosts = tally.occupiedHosts,
        )
    }

    private fun camera(host: String, knownNames: Map<String, String>): DiscoveredCamera =
        DiscoveredCamera(
            name = knownNames[host] ?: DEFAULT_CAMERA_NAME,
            host = host,
            port = CameraDiscovery.PTP_IP_PORT,
        )

    public companion object {
        private const val TAG: String = "InfraSearch"

        /** Shown until the connect's own handshake supplies the body's real name. */
        internal const val DEFAULT_CAMERA_NAME: String = "Camera"
    }
}

/**
 * Live site-local IPv4 interfaces this device can sweep from: never cellular or a tunnel, whose
 * carrier 10/8 addresses look private too ([NikonHosts.isScanInterface]).
 */
public fun localIPv4Interfaces(): List<NikonLocalInterface> =
    runCatching {
        NetworkInterface.getNetworkInterfaces()
            ?.toList()
            .orEmpty()
            .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
            .flatMap { networkInterface ->
                networkInterface.inetAddresses
                    .toList()
                    .filterIsInstance<Inet4Address>()
                    .mapNotNull { it.hostAddress }
                    .filter { NikonHosts.isScanInterface(networkInterface.name, it) }
                    .map { NikonLocalInterface(networkInterface.name, it) }
            }
    }
        .getOrDefault(emptyList())
