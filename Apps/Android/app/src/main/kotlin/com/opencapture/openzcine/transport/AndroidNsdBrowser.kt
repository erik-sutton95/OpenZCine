package com.opencapture.openzcine.transport

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import java.io.IOException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * [NsdBrowser] backed by the platform [NsdManager], insulated against its
 * known callback quirks:
 *
 * - **One discovery per listener** — every collection creates a fresh
 *   listener, and browsing stops when the collector cancels.
 * - **Resolves must be serialized** — concurrent [NsdManager.resolveService]
 *   calls fail with `FAILURE_ALREADY_ACTIVE`, so found services queue through
 *   a single worker that resolves strictly one at a time.
 * - **Stop-before-start is illegal** — [NsdManager.stopServiceDiscovery] on a
 *   listener whose start failed throws `IllegalArgumentException`; teardown
 *   swallows that case.
 *
 * Not JVM-testable (framework types throughout); the mapping logic it feeds
 * lives in [CameraDiscovery], which is. Instrumented coverage is future work.
 */
class AndroidNsdBrowser(private val nsdManager: NsdManager) : NsdBrowser {
    override fun events(serviceType: String): Flow<NsdEvent> = callbackFlow {
        val resolveRequests = Channel<NsdServiceInfo>(Channel.UNLIMITED)
        val resolver = launch {
            for (service in resolveRequests) {
                resolveOne(service)?.let(::trySend)
            }
        }

        val listener =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {}

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    close(IOException("NSD discovery failed to start (error $errorCode)."))
                }

                override fun onDiscoveryStopped(serviceType: String) {}

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    trySend(NsdEvent.ServiceFound(serviceInfo.serviceName))
                    resolveRequests.trySend(serviceInfo)
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                    trySend(NsdEvent.ServiceLost(serviceInfo.serviceName))
                }
            }

        nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)

        awaitClose {
            resolver.cancel()
            resolveRequests.close()
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (_: IllegalArgumentException) {
                // Start failed, so the listener was never registered.
            }
        }
    }

    /** Resolves one service; returns null when resolution fails or lacks an address. */
    private suspend fun resolveOne(service: NsdServiceInfo): NsdEvent.ServiceResolved? =
        suspendCancellableCoroutine { continuation ->
            nsdManager.resolveService(
                service,
                object : NsdManager.ResolveListener {
                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val host = serviceInfo.host?.hostAddress
                        continuation.resume(
                            host?.let {
                                NsdEvent.ServiceResolved(serviceInfo.serviceName, it, serviceInfo.port)
                            },
                            onCancellation = null,
                        )
                    }

                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        continuation.resume(null, onCancellation = null)
                    }
                },
            )
        }
}
