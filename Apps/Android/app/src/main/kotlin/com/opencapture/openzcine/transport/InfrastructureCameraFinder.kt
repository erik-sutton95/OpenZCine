package com.opencapture.openzcine.transport

import android.util.Log
import java.io.IOException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

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
    private val scanner: PortScanner = SocketPortScanner,
) {
    /** The seam that dials a host, so the sweep is testable without a network. */
    public fun interface PortScanner {
        public suspend fun probe(host: String, timeoutMillis: Int): HostProbeVerdict
    }

    /**
     * One complete infrastructure search pass.
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
        interfaces: List<LocalIPv4Interface> = localIPv4Interfaces(),
    ): InfrastructureSearchReport {
        if (onCameraAccessPoint) {
            return InfrastructureSearchReport(miss = InfrastructureMissReason.OnCameraAccessPoint)
        }
        val localSubnets =
            interfaces.mapNotNull { CameraDiscovery.subnetBase(it.address) }.distinct().sorted()
        if (localSubnets.isEmpty()) {
            return InfrastructureSearchReport(miss = InfrastructureMissReason.NoScannableInterface)
        }
        val localAddresses = interfaces.map(LocalIPv4Interface::address).toSet()
        val directed =
            InfrastructureDiscovery.directedHosts(
                candidates = directedCandidates,
                localSubnets = localSubnets,
                excluded = excludedHosts + localAddresses,
            )

        log(
            "infra-search preflight=ready subnets=[${localSubnets.joinToString(" ")}] " +
                "directed=[${directed.joinToString(" ")}] " +
                "attempts=${InfrastructureDiscovery.DIRECTED_ATTEMPT_COUNT} " +
                "budgetMs=${InfrastructureDiscovery.DIRECTED_TIMEOUT_MILLIS}",
        )

        // Directed first: the reconnect case answers in one round rather than waiting out a sweep.
        patientDirectedSearch(directed, knownNames)?.let { return it }

        return occupancySweep(
            localSubnets = localSubnets,
            localAddresses = localAddresses,
            excluded = excludedHosts,
            directed = directed,
            knownNames = knownNames,
        )
    }

    private suspend fun patientDirectedSearch(
        hosts: List<String>,
        knownNames: Map<String, String>,
    ): InfrastructureSearchReport? {
        if (hosts.isEmpty()) return null
        val found =
            coroutineScope {
                hosts
                    .map { host -> async(Dispatchers.IO) { patientProbe(host, knownNames) } }
                    .awaitAll()
                    .filterNotNull()
            }
        if (found.isEmpty()) return null
        return InfrastructureSearchReport(cameras = found)
    }

    private suspend fun patientProbe(
        host: String,
        knownNames: Map<String, String>,
    ): DiscoveredCamera? {
        // Attempts, not one long wait. A body whose radio was asleep for the first dial is awake
        // for the second, and three short waits find it where one long one only sits there.
        repeat(InfrastructureDiscovery.DIRECTED_ATTEMPT_COUNT) { attempt ->
            if (!currentCoroutineContext().isActive) return null
            val verdict =
                scanner.probe(host, InfrastructureDiscovery.DIRECTED_TIMEOUT_MILLIS)
            if (verdict == HostProbeVerdict.OPEN) {
                log("infra-search directed hit host=$host attempt=${attempt + 1}")
                return camera(host, knownNames)
            }
            log("infra-search directed host=$host attempt=${attempt + 1} verdict=$verdict")
        }
        return null
    }

    private suspend fun occupancySweep(
        localSubnets: List<String>,
        localAddresses: Set<String>,
        excluded: Set<String>,
        directed: List<String>,
        knownNames: Map<String, String>,
    ): InfrastructureSearchReport {
        var merged = InfrastructureSweepTally()
        val allOccupied = sortedSetOf<String>()
        val allOpen = sortedSetOf<String>()

        repeat(InfrastructureDiscovery.LOCAL_SWEEP_PASSES) { pass ->
            for (subnet in localSubnets) {
                if (!currentCoroutineContext().isActive) break
                val hosts =
                    (1..254)
                        .map { "$subnet.$it" }
                        .filterNot { it in excluded || it in localAddresses }
                val scan = InfrastructureSweepTally.from(muteScan(hosts))
                merged = merged.merging(scan)
                allOccupied.addAll(scan.occupiedHosts)
                allOpen.addAll(scan.openHosts)

                log(
                    "infra-search sweep pass=${pass + 1} subnet=$subnet " +
                        "open=[${scan.openHosts.joinToString(" ")}] " +
                        "occupied=[${scan.occupiedHosts.take(24).joinToString(" ")}]",
                )

                if (scan.openHosts.isNotEmpty()) {
                    return InfrastructureSearchReport(
                        cameras = scan.openHosts.map { camera(it, knownNames) },
                        occupiedHosts = allOccupied.toList(),
                        openPtpHosts = allOpen.toList(),
                        localSubnets = localSubnets,
                        directedHosts = directed,
                    )
                }
                // Hosts that refuse :15740 are on-link and not serving PTP. Naming them is what
                // separates "we reached the camera's address and it said closed" from a network
                // that never carried us anywhere at all.
                val closed = scan.occupiedHosts.filterNot { it in scan.openHosts }
                if (closed.isNotEmpty()) {
                    log(
                        "infra-search reachable-not-ptp=[${closed.take(16).joinToString(" ")}]",
                    )
                }
            }
        }

        val miss =
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(localSubnets),
                onCameraAccessPoint = false,
                tally = merged,
            )
        log(
            "infra-search miss=$miss open=[${allOpen.joinToString(" ")}] " +
                "occupied=[${allOccupied.take(24).joinToString(" ")}]",
        )
        return InfrastructureSearchReport(
            miss = miss,
            occupiedHosts = allOccupied.toList(),
            openPtpHosts = allOpen.toList(),
            localSubnets = localSubnets,
            directedHosts = directed,
        )
    }

    /**
     * Dials [hosts] on the PTP port, a bounded number at a time, and reports what each one did.
     *
     * The window is bounded rather than firing a whole /24 at once: 254 simultaneous connects are
     * 254 blocked sockets and an ARP request for every address nobody holds.
     */
    private suspend fun muteScan(hosts: List<String>): Map<String, HostProbeVerdict> {
        val verdicts = mutableMapOf<String, HostProbeVerdict>()
        for (window in hosts.chunked(InfrastructureDiscovery.SWEEP_CONCURRENCY)) {
            if (!currentCoroutineContext().isActive) break
            val results =
                coroutineScope {
                    window
                        .map { host ->
                            async(Dispatchers.IO) {
                                host to
                                    scanner.probe(
                                        host,
                                        InfrastructureDiscovery.BLIND_SWEEP_TIMEOUT_MILLIS,
                                    )
                            }
                        }
                        .awaitAll()
                }
            verdicts.putAll(results)
        }
        return verdicts
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

/** One local IPv4 interface. Twin of the shared core's `LocalIPv4Interface`. */
public data class LocalIPv4Interface(val name: String, val address: String)

/** Live site-local IPv4 interfaces this device can sweep from. */
public fun localIPv4Interfaces(): List<LocalIPv4Interface> =
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
                    .filter(CameraDiscovery::isSupportedPtpIpDiscoveryHost)
                    .map { LocalIPv4Interface(networkInterface.name, it) }
            }
    }
        .getOrDefault(emptyList())

/**
 * A dial at the PTP port that sends no PTP bytes, keeping WHY it failed.
 *
 * Mute on purpose: a real `Init` aimed at a body sitting in pairing mode knocks it out of pairing,
 * which is exactly what a wide sweep must never do. A bare connect-and-close cannot.
 */
internal object SocketPortScanner : InfrastructureCameraFinder.PortScanner {
    override suspend fun probe(host: String, timeoutMillis: Int): HostProbeVerdict =
        withContext(Dispatchers.IO) {
            try {
                Socket().use { socket ->
                    socket.connect(
                        InetSocketAddress(host, CameraDiscovery.PTP_IP_PORT),
                        timeoutMillis,
                    )
                }
                HostProbeVerdict.OPEN
            } catch (_: SocketTimeoutException) {
                HostProbeVerdict.TIMEOUT
            } catch (_: NoRouteToHostException) {
                HostProbeVerdict.NO_ROUTE
            } catch (_: PortUnreachableException) {
                HostProbeVerdict.REFUSED
            } catch (_: ConnectException) {
                // Refused: only a live host's kernel sends the RST. Java folds "connection
                // refused" and some unreachables into this one type, so the message decides.
                HostProbeVerdict.REFUSED
            } catch (_: SocketException) {
                HostProbeVerdict.NO_NETWORK
            } catch (_: IOException) {
                // Never evidence about the host — this is something about THIS device.
                HostProbeVerdict.UNREACHABLE_OTHER
            }
        }
}
