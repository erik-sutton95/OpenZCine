package com.opencapture.openzcine.transport

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.hardware.usb.UsbRequest
import android.os.Build
import androidx.core.content.ContextCompat
import java.io.Closeable
import java.nio.BufferOverflowException
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeoutException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Current access state for a compatible USB PTP camera. */
public enum class UsbPtpCameraAccess {
    /** Android has not granted this app access to the attached camera yet. */
    NEEDS_PERMISSION,

    /** The camera is attached, permissioned, and has a stable saved-record key. */
    READY,

    /** The operator denied Android's per-device USB permission prompt. */
    DENIED,

    /** Android did not expose a serial, so a durable reconnect key is unavailable. */
    IDENTITY_UNAVAILABLE,
}

/**
 * A compatible, locally attached USB PTP camera.
 *
 * [token] is an in-memory Android device handle, never a saved identity.
 * [hostKey] is available only when [access] is [UsbPtpCameraAccess.READY],
 * and contains a local digest rather than the raw USB serial. UI must not
 * render or log it. [isDebugFixture] is true only for source-set-isolated
 * screenshot fixtures and must never describe physical Android USB hardware.
 */
public data class UsbPtpCamera(
    public val token: String,
    public val displayName: String,
    public val access: UsbPtpCameraAccess,
    public val hostKey: String?,
    public val isDebugFixture: Boolean = false,
)

/** Raw USB byte transport consumed by the Swift PTP USB adapter over JNI. */
public interface UsbPtpTransport : Closeable {
    /** Writes one already-framed PTP USB container; returns the byte count or a negative failure. */
    public fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int

    /** Reads raw bulk bytes; empty means timeout and null means a closed or failed link. */
    public fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray?

    /** Reads raw interrupt-event bytes; empty means timeout and null means a closed or failed link. */
    public fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray?

    /** Whether this transport was closed locally or by an attach/detach lifecycle event. */
    public fun isClosed(): Boolean
}

/** Result of opening a platform-owned USB transport for the Swift facade. */
public sealed interface UsbPtpOpenResult {
    /** A permissioned connection with a stable saved-record host key. */
    public data class Opened(
        public val transport: UsbPtpTransport,
        /** Internal local reconnect key; never an operator-facing value. */
        public val hostKey: String,
        public val displayName: String,
    ) : UsbPtpOpenResult

    /** The requested camera was no longer available for a safe connection. */
    public data class Rejected(public val message: String) : UsbPtpOpenResult
}

/**
 * Android USB-host seam used by pairing and saved-camera reconnect.
 *
 * It owns `UsbManager`, permission broadcasts, endpoint selection, and raw
 * bytes only. Swift owns PTP container framing, session strategy, camera
 * operations, and Nikon-specific policy through the JNI facade.
 */
public interface UsbPtpCameraSource : Closeable {
    /** Current compatible USB cameras, updated for attach/detach/permission events. */
    public val cameras: StateFlow<List<UsbPtpCamera>>

    /**
     * Re-enumerates the currently attached USB devices on demand. Samsung (and
     * some other OEMs) do NOT deliver `ACTION_USB_DEVICE_ATTACHED` to a
     * runtime-registered receiver, so a camera plugged in after the source was
     * constructed never reaches [cameras] via the broadcast path. The discover
     * UI polls this while it waits so an attached camera is still found.
     */
    public fun refresh()

    /** Requests Android's per-device permission for a [UsbPtpCameraAccess.NEEDS_PERMISSION] camera. */
    public fun requestPermission(camera: UsbPtpCamera)

    /** Opens an authorized compatible camera, or returns actionable recovery copy. */
    public fun open(camera: UsbPtpCamera): UsbPtpOpenResult
}

/**
 * Production [UsbPtpCameraSource] over Android USB Host APIs.
 *
 * The dynamic receiver covers foreground attach/detach while the app's saved
 * camera home is visible. A detached camera closes its live transport before
 * state is published, so Swift's event/session layer observes a hard link
 * loss rather than continuing against a recycled device handle.
 */
public class AndroidUsbPtpCameraSource(
    context: Context,
    private val usbManager: UsbManager = context.getSystemService(UsbManager::class.java),
) : UsbPtpCameraSource {
    private val appContext: Context = context.applicationContext
    private val mutableCameras = MutableStateFlow(emptyList<UsbPtpCamera>())
    override val cameras: StateFlow<List<UsbPtpCamera>> = mutableCameras.asStateFlow()
    private val activeConnections = ConcurrentHashMap<String, AndroidUsbPtpTransport>()
    private val attachmentState = UsbPtpAttachmentState()
    /** Serializes attachment generations with post-claim transport registration. */
    private val lifecycleLock = Any()
    @Volatile private var closed: Boolean = false

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val device = intent.usbDevice() ?: return
                when (intent.action) {
                    UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        val transport =
                            synchronized(lifecycleLock) {
                                attachmentState.detach(device.deviceName)
                                activeConnections.remove(device.deviceName)
                            }
                        transport?.close()
                        refresh(excludingToken = device.deviceName)
                        return
                    }
                    usbPermissionAction -> {
                        synchronized(lifecycleLock) {
                            attachmentState.recordPermissionResult(
                                token = device.deviceName,
                                granted =
                                    intent.getBooleanExtra(
                                        UsbManager.EXTRA_PERMISSION_GRANTED,
                                        false,
                                    ),
                            )
                        }
                    }
                }
                refresh()
            }
        }

    init {
        val filter =
            IntentFilter().apply {
                addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
                addAction(usbPermissionAction)
            }
        ContextCompat.registerReceiver(appContext, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        refresh()
    }

    override fun requestPermission(camera: UsbPtpCamera) {
        if (
            closed ||
                (camera.access != UsbPtpCameraAccess.NEEDS_PERMISSION &&
                    camera.access != UsbPtpCameraAccess.DENIED)
        ) {
            return
        }
        val device = usbManager.deviceList[camera.token] ?: return
        if (descriptorSelection(device) == null) return
        synchronized(lifecycleLock) {
            if (closed) return
            attachmentState.requestPermissionAgain(camera.token)
        }
        refresh()
        usbManager.requestPermission(device, permissionIntent())
    }

    override fun open(camera: UsbPtpCamera): UsbPtpOpenResult {
        val device = usbManager.deviceList[camera.token]
            ?: return UsbPtpOpenResult.Rejected(
                "The USB-C camera is no longer attached. Reconnect the cable and try again.",
            )
        val attachmentLease =
            synchronized(lifecycleLock) {
                if (closed) return UsbPtpOpenResult.Rejected("USB camera discovery is no longer active.")
                attachmentState.captureOpenLease(device.deviceName)
            }
                ?: return UsbPtpOpenResult.Rejected(
                    "The USB-C camera is no longer attached. Reconnect the cable and try again.",
                )
        if (!usbManager.hasPermission(device)) {
            return UsbPtpOpenResult.Rejected(
                "Allow USB access for this camera, then try connecting again.",
            )
        }
        val selection = descriptorSelection(device)
            ?: return UsbPtpOpenResult.Rejected(
                "This USB device does not expose the complete PTP camera interface OpenZCine needs.",
            )
        val hostKey = stableHostKey(device)
            ?: return UsbPtpOpenResult.Rejected(
                "This camera did not provide a stable USB identity. Reconnect it or use Wi‑Fi pairing.",
            )
        val connection = usbManager.openDevice(device)
            ?: return UsbPtpOpenResult.Rejected(
                "Android could not open this USB camera. Disconnect it, approve access again, and retry.",
            )
        val usbInterface = device.getInterface(selection.interfaceIndex)
        if (!connection.claimInterface(usbInterface, true)) {
            connection.close()
            return UsbPtpOpenResult.Rejected(
                "Android could not claim the camera's PTP USB interface. Close other camera apps and retry.",
            )
        }
        val bulkIn = endpoint(usbInterface, selection.bulkInAddress)
        val bulkOut = endpoint(usbInterface, selection.bulkOutAddress)
        // The system MTP handler (com.android.mtp) grabs a PTP camera on attach
        // and often leaves a stuck session: its aborted OpenSession stalls the
        // bulk pipes, so our first write fails with -1 even after a force-claim.
        // The PTP class recovery is a Device Reset (class request 0x66) followed
        // by clearing any HALT on the bulk endpoints — the standard sequence
        // libptp/gPhoto use to take a camera another host left mid-transaction.
        recoverStalledPtpInterface(connection, usbInterface.id, bulkIn.address, bulkOut.address)
        val eventIn = endpoint(usbInterface, selection.eventInAddress)
        val eventRequest = UsbRequest()
        if (!eventRequest.initialize(connection, eventIn)) {
            connection.releaseInterface(usbInterface)
            connection.close()
            eventRequest.close()
            return UsbPtpOpenResult.Rejected(
                "Android could not open the camera's PTP event endpoint. Reconnect the cable and retry.",
            )
        }
        val transport =
            AndroidUsbPtpTransport(
                connection = connection,
                usbInterface = usbInterface,
                bulkIn = bulkIn,
                bulkOut = bulkOut,
                eventRequest = eventRequest,
            )
        transport.setOnClosed {
            synchronized(lifecycleLock) {
                if (activeConnections.remove(device.deviceName, transport)) {
                    attachmentState.markTransportClosed(device.deviceName)
                }
            }
        }
        var replacedTransport: AndroidUsbPtpTransport? = null
        val rejectOpenedTransport =
            synchronized(lifecycleLock) {
                if (
                    closed ||
                        !attachmentState.isCurrent(attachmentLease) ||
                        usbManager.deviceList[device.deviceName] == null
                ) {
                    true
                } else {
                    replacedTransport = activeConnections.put(device.deviceName, transport)
                    attachmentState.markTransportOpened(device.deviceName)
                    false
                }
            }
        if (rejectOpenedTransport) {
            transport.close()
            return UsbPtpOpenResult.Rejected(
                "The USB-C camera changed while Android opened it. Reconnect the cable and try again.",
            )
        }
        replacedTransport?.close()
        return UsbPtpOpenResult.Opened(
            transport = transport,
            hostKey = hostKey,
            displayName = displayName(device),
        )
    }

    override fun close() {
        val transports =
            synchronized(lifecycleLock) {
                if (closed) return
                closed = true
                activeConnections.values.toList().also { activeConnections.clear() }
            }
        runCatching { appContext.unregisterReceiver(receiver) }
        transports.forEach(AndroidUsbPtpTransport::close)
        mutableCameras.value = emptyList()
    }

    /**
     * Clears a PTP interface another USB host (Samsung's com.android.mtp) may
     * have left mid-transaction, so our first bulk write does not fail with -1.
     * Status-driven: a camera whose class status already reads OK is left
     * untouched — a blind Device Reset on a healthy ZR makes it silently drop
     * the next command container, which desyncs the whole session.
     *
     * 1. PTP class GET_DEVICE_STATUS (bmRequestType 0xA1, bRequest 0x67). OK
     *    (0x2001) means clean — do nothing.
     * 2. Otherwise: Device Reset Request (0x21, 0x66), CLEAR_FEATURE(HALT) on
     *    both bulk pipes, then poll GET_DEVICE_STATUS until the body reports
     *    OK again (the reset is not instant on the ZR).
     */
    private fun recoverStalledPtpInterface(
        connection: UsbDeviceConnection,
        interfaceId: Int,
        bulkInAddress: Int,
        bulkOutAddress: Int,
    ) {
        if (ptpDeviceStatus(connection, interfaceId, timeoutMillis = 500) == PTP_STATUS_OK) return
        ptpResetAndSettle(connection, interfaceId, bulkInAddress, bulkOutAddress, USB_DIAG_TAG)
    }


    override fun refresh() {
        refresh(excludingToken = null)
    }

    private fun refresh(excludingToken: String? = null) {
        synchronized(lifecycleLock) {
            if (closed) return
            mutableCameras.value =
                usbManager.deviceList.values
                    .filter { it.deviceName != excludingToken }
                    .mapNotNull(::camera)
                    .sortedBy(UsbPtpCamera::displayName)
        }
    }

    private fun camera(device: UsbDevice): UsbPtpCamera? {
        descriptorSelection(device) ?: return null
        val token = device.deviceName
        attachmentState.observeAttached(token)
        val hasPermission = usbManager.hasPermission(device)
        val hostKey = if (hasPermission) stableHostKey(device) else null
        val access =
            attachmentState.access(
                token = token,
                hasUsbPermission = hasPermission,
                hasStableIdentity = hostKey != null,
            ) ?: return null
        return UsbPtpCamera(
            token = token,
            displayName = displayName(device),
            access = access,
            hostKey = if (access == UsbPtpCameraAccess.READY) hostKey else null,
        )
    }

    private fun descriptorSelection(device: UsbDevice): UsbPtpInterfaceSelection? =
        UsbPtpInterfaceSelector.select(
            buildList {
                for (index in 0 until device.interfaceCount) {
                    val usbInterface = device.getInterface(index)
                    add(usbInterface.descriptor(index))
                }
            },
        )

    private fun UsbInterface.descriptor(index: Int): UsbPtpInterfaceDescriptor =
        UsbPtpInterfaceDescriptor(
            index = index,
            interfaceClass = interfaceClass,
            interfaceSubclass = interfaceSubclass,
            interfaceProtocol = interfaceProtocol,
            endpoints =
                List(endpointCount) { endpointIndex ->
                    getEndpoint(endpointIndex).descriptor()
                },
        )

    private fun UsbEndpoint.descriptor(): UsbPtpEndpointDescriptor =
        UsbPtpEndpointDescriptor(
            address = address,
            direction =
                if (direction == UsbConstants.USB_DIR_IN) {
                    UsbPtpEndpointDirection.IN
                } else {
                    UsbPtpEndpointDirection.OUT
                },
            transferType =
                when (type) {
                    UsbConstants.USB_ENDPOINT_XFER_BULK -> UsbPtpTransferType.BULK
                    UsbConstants.USB_ENDPOINT_XFER_INT -> UsbPtpTransferType.INTERRUPT
                    else -> UsbPtpTransferType.OTHER
                },
        )

    private fun endpoint(usbInterface: UsbInterface, address: Int): UsbEndpoint =
        (0 until usbInterface.endpointCount)
            .map(usbInterface::getEndpoint)
            .first { it.address == address }

    private fun stableHostKey(device: UsbDevice): String? =
        UsbCameraHostKey.derive(
            vendorId = device.vendorId,
            productId = device.productId,
            serialNumber = runCatching { device.serialNumber }.getOrNull(),
        )

    private fun displayName(device: UsbDevice): String {
        val product = runCatching { device.productName?.trim() }.getOrNull()
        if (!product.isNullOrEmpty()) return product
        return if (device.vendorId == NIKON_VENDOR_ID) "Nikon USB camera" else "USB PTP camera"
    }

    private fun permissionIntent(): PendingIntent =
        PendingIntent.getBroadcast(
            appContext,
            USB_PERMISSION_REQUEST_CODE,
            Intent(usbPermissionAction).setPackage(appContext.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentMutabilityFlag(),
        )

    private fun pendingIntentMutabilityFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0

    private fun Intent.usbDevice(): UsbDevice? {
        @Suppress("DEPRECATION")
        return getParcelableExtra(UsbManager.EXTRA_DEVICE)
    }

    private companion object {
        const val NIKON_VENDOR_ID: Int = 0x04B0
        const val USB_PERMISSION_REQUEST_CODE: Int = 54054
        const val usbPermissionAction: String = "com.opencapture.openzcine.USB_PTP_PERMISSION"
        const val USB_DIAG_TAG: String = "UsbPtpDiag"
    }
}

private const val PTP_STATUS_OK: Int = 0x2001

/** PTP class GET_DEVICE_STATUS; returns the status code or 0 on failure. */
private fun ptpDeviceStatus(
    connection: UsbDeviceConnection,
    interfaceId: Int,
    timeoutMillis: Int,
): Int {
    val buffer = ByteArray(4)
    val read = runCatching {
        connection.controlTransfer(0xA1, 0x67, 0, interfaceId, buffer, buffer.size, timeoutMillis)
    }.getOrDefault(-1)
    if (read < 4) return 0
    return (buffer[2].toInt() and 0xFF) or ((buffer[3].toInt() and 0xFF) shl 8)
}

/**
 * PTP class Device Reset + CLEAR_FEATURE(HALT) on both bulk pipes, then poll
 * GET_DEVICE_STATUS until the body reports OK again. The reset is not
 * instant on the ZR — a command sent before it completes is silently
 * dropped, which desyncs every later transaction, so the settle poll is as
 * load-bearing as the reset itself.
 */
private fun ptpResetAndSettle(
    connection: UsbDeviceConnection,
    interfaceId: Int,
    bulkInAddress: Int,
    bulkOutAddress: Int,
    tag: String,
) {
    val controlTimeoutMillis = 500
    runCatching {
        connection.controlTransfer(0x21, 0x66, 0, interfaceId, null, 0, controlTimeoutMillis)
    }
    for (endpointAddress in intArrayOf(bulkInAddress, bulkOutAddress)) {
        runCatching {
            connection.controlTransfer(0x02, 0x01, 0, endpointAddress, null, 0, controlTimeoutMillis)
        }
    }
    repeat(15) {
        runCatching { Thread.sleep(200L) }
        val status = ptpDeviceStatus(connection, interfaceId, controlTimeoutMillis)
        if (status == PTP_STATUS_OK) {
            android.util.Log.i(tag, "PTP reset settled")
            return
        }
    }
    android.util.Log.i(tag, "PTP reset did not settle to OK")
}

/**
 * The `UsbRequest` / `UsbDeviceConnection` calls the interrupt-event pump makes.
 *
 * Isolated behind an interface so JVM tests can model AOSP's queued-flag
 * semantics exactly. `UsbRequest.cancel()` only asks the kernel to abort the
 * transfer; the flag that makes a second `queue()` throw
 * `IllegalStateException("this request is currently queued")` is cleared in
 * `UsbRequest.dequeue()`, and only `UsbDeviceConnection.requestWait()` calls
 * that. A fake that cleared the flag on cancel would hide the whole bug.
 */
internal interface UsbInterruptChannel {
    /** Queues [buffer] on the one interrupt-IN request; false when the connection is gone. */
    fun queue(buffer: ByteBuffer): Boolean

    /** Asks the kernel to abort the queued transfer. Never dequeues it. */
    fun cancel()

    /**
     * Waits for one completion.
     *
     * @return true when the completion was this channel's own request, which the
     *   framework has now dequeued; false for a foreign or error completion,
     *   which leaves our transfer queued.
     * @throws TimeoutException when nothing completed within [timeoutMillis].
     */
    fun awaitCompletion(timeoutMillis: Long): Boolean

    /** Releases the request itself. The connection is closed by its owner. */
    fun close()
}

/**
 * Owns the single interrupt-IN transfer PTP events arrive on.
 *
 * One request stays queued across the sparse-event timeouts a healthy body
 * produces: a Nikon camera only emits events while the host has a transfer
 * outstanding, and the ZR stalls its switch into application mode until the
 * StoreRemoved it posts here is drained. A timeout therefore keeps the exact
 * request and buffer — that path is load bearing.
 *
 * Every other outcome must hand the transfer back to the framework before
 * anything queues again. Cancelling is not enough: AOSP clears its queued flag
 * inside `dequeue()`, which runs only when `requestWait()` returns the request,
 * so a cancelled-but-unreaped request rejects the next `queue()` with
 * `IllegalStateException` and — because that call sat outside the try — killed
 * the process. When the abort cannot be reaped the connection is gone, so the
 * pump retires rather than queue again and its owner closes the session.
 */
internal class UsbInterruptEventPump(private val channel: UsbInterruptChannel) {
    /** Serializes reads against teardown so nothing can queue behind a close. */
    private val lock = Any()
    /** Non-null exactly while the framework still owns a queued transfer. */
    private var queuedBuffer: ByteBuffer? = null
    @Volatile private var retired: Boolean = false
    @Volatile private var stopped: Boolean = false

    /** True once no further transfer can be queued and the session must close. */
    fun isRetired(): Boolean = retired

    /**
     * Queues the first read at claim time, before the event pump starts. Load
     * bearing for Nikon application mode — never fold this into the first [read].
     */
    fun prime(maxBytes: Int) {
        synchronized(lock) {
            if (!stopped && !retired && queuedBuffer == null) queueLocked(maxBytes)
        }
    }

    /**
     * @return the event bytes, an empty array for a healthy sparse-channel
     *   timeout or a dropped oversized event, or null when this read failed.
     */
    fun read(maxBytes: Int, timeoutMillis: Int): ByteArray? =
        synchronized(lock) {
            if (stopped || retired) return@synchronized null
            val buffer = queuedBuffer ?: queueLocked(maxBytes) ?: return@synchronized null
            try {
                if (!channel.awaitCompletion(timeoutMillis.toLong())) {
                    // A null (framework error) or foreign completion leaves our
                    // transfer queued, so it has to be aborted and reaped here.
                    releaseQueuedLocked()
                    return@synchronized null
                }
                queuedBuffer = null
                buffer.array().copyOf(buffer.position())
            } catch (_: TimeoutException) {
                // A sparse PTP event channel is healthy. The request stays
                // queued on purpose and its buffer is still framework-owned, so
                // neither may be dropped. JNI maps the empty read to a typed
                // Swift timeout and the session keeps draining.
                ByteArray(0)
            } catch (_: BufferOverflowException) {
                // `requestWait` throws this from inside `dequeue`, so the
                // request is already dequeued and only the payload is lost.
                // Drop the oversized event; the pump stays healthy.
                queuedBuffer = null
                ByteArray(0)
            } catch (_: Throwable) {
                releaseQueuedLocked()
                null
            }
        }

    /**
     * Aborts any queued transfer and retires the pump for good. No drain here:
     * the owner closes the connection next, and closing its file descriptor is
     * what discards anything still outstanding. The request itself is released
     * by [release] once that has happened.
     */
    fun shutdown() {
        stopped = true
        // Cancel outside the lock: a reader parked in `awaitCompletion` wakes on
        // the abort, and it has to release the lock before teardown can proceed.
        // ponytail: worst case this still waits one event timeout (~1s) for a
        // reader the abort did not wake. Move teardown off the caller's thread
        // if a detach ever shows up as a main-thread stall.
        runCatching { channel.cancel() }
        synchronized(lock) {
            retired = true
            queuedBuffer = null
        }
    }

    /** Releases the request. Call after the owning connection is closed. */
    fun release() {
        synchronized(lock) { runCatching { channel.close() } }
    }

    /** Queues a fresh buffer, or retires the pump when the framework refuses. */
    private fun queueLocked(maxBytes: Int): ByteBuffer? {
        val fresh = ByteBuffer.allocate(maxBytes)
        // Guarded, not bare: the framework throws for a closed connection or a
        // request teardown retired underneath us, and this is the exact call
        // that used to escape the event pump and kill the process.
        val queued = runCatching { channel.queue(fresh) }.getOrDefault(false)
        if (!queued) {
            retired = true
            return null
        }
        queuedBuffer = fresh
        return fresh
    }

    /**
     * Returns a queued transfer to the framework before anything queues again.
     * A discarded URB is still reaped, so the abort normally comes straight
     * back; if it never does, the connection is gone and the request can never
     * be queued again, so the pump retires instead.
     */
    private fun releaseQueuedLocked() {
        if (queuedBuffer == null) return
        runCatching { channel.cancel() }
        repeat(DRAIN_ATTEMPTS) {
            val reaped =
                runCatching { channel.awaitCompletion(DRAIN_TIMEOUT_MILLIS) }.getOrDefault(false)
            if (reaped) {
                queuedBuffer = null
                return
            }
        }
        retired = true
    }

    private companion object {
        const val DRAIN_ATTEMPTS: Int = 4
        const val DRAIN_TIMEOUT_MILLIS: Long = 50L
    }
}

/** Production [UsbInterruptChannel] over one initialized interrupt-IN request. */
private class UsbRequestInterruptChannel(
    private val connection: UsbDeviceConnection,
    private val request: UsbRequest,
) : UsbInterruptChannel {
    override fun queue(buffer: ByteBuffer): Boolean = request.queue(buffer)

    override fun cancel() {
        request.cancel()
    }

    override fun awaitCompletion(timeoutMillis: Long): Boolean =
        connection.requestWait(timeoutMillis) === request

    override fun close() {
        request.close()
    }
}

/** Platform byte adapter for one claimed USB PTP interface. */
private class AndroidUsbPtpTransport(
    private val connection: UsbDeviceConnection,
    private val usbInterface: UsbInterface,
    private val bulkIn: UsbEndpoint,
    private val bulkOut: UsbEndpoint,
    eventRequest: UsbRequest,
) : UsbPtpTransport {
    private val closeLock = Any()
    private val commandLock = Any()
    private val eventPump =
        UsbInterruptEventPump(UsbRequestInterruptChannel(connection, eventRequest))
    @Volatile private var closed: Boolean = false
    private var deadWriteRecoveryDone: Boolean = false
    private var onClosed: (() -> Unit)? = null

    init {
        // Keep one interrupt-IN read pending from claim time: the body only
        // delivers events when the host has a transfer queued. Entering
        // application mode makes the ZR emit StoreRemoved here, and it stalls
        // that switch until the event is drained (see the Swift establish's
        // concurrent event pump). This just ensures a buffer is already
        // waiting before the pump's first read.
        eventPump.prime(INITIAL_EVENT_BYTES)
    }

    fun setOnClosed(callback: () -> Unit) {
        val closeNow: Boolean
        synchronized(closeLock) {
            closeNow = closed
            if (!closeNow) onClosed = callback
        }
        if (closeNow) callback()
    }

    override fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int =
        synchronized(commandLock) {
            if (closed) return@synchronized -1
            val count = connection.bulkTransfer(bulkOut, bytes, bytes.size, timeoutMillis)
            if (count < 0 && !closed && !deadWriteRecoveryDone) {
                // GET_DEVICE_STATUS reads OK even while the body's bulk-out
                // is wedged (Samsung's com.android.mtp left an aborted session
                // on attach), so a dead write is the only reliable wedge
                // signal. Reset once so the NEXT attempt starts on a healthy
                // interface; this attempt still reports failure.
                deadWriteRecoveryDone = true
                android.util.Log.i(USB_DIAG_TAG, "USB bulk-out wedged; PTP reset")
                ptpResetAndSettle(
                    connection, usbInterface.id, bulkIn.address, bulkOut.address, USB_DIAG_TAG,
                )
            }
            count
        }

    override fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray? =
        read(endpoint = bulkIn, maxBytes = maxBytes, timeoutMillis = timeoutMillis, lock = commandLock)

    override fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray? {
        if (closed || maxBytes !in 1..MAX_READ_BYTES) return null
        val bytes = eventPump.read(maxBytes, timeoutMillis)
        // A retired pump can never queue another interrupt read, so this USB
        // session is over. Close it here instead of letting the caller retry
        // into a pipe that will never deliver; Swift then sees a typed
        // connection-closed failure and the source drops the transport.
        if (eventPump.isRetired()) close()
        return bytes
    }

    override fun isClosed(): Boolean = closed

    override fun close() {
        val callback: (() -> Unit)?
        synchronized(closeLock) {
            if (closed) return
            closed = true
            callback = onClosed
            onClosed = null
        }
        // Retire the pump first: `requestWait` may be blocked on the sparse
        // interrupt pipe, and the abort both wakes it and guarantees no reader
        // can queue another transfer behind this teardown. Release the interface
        // next, and close the request only after the connection is gone.
        eventPump.shutdown()
        runCatching { connection.releaseInterface(usbInterface) }
        connection.close()
        eventPump.release()
        callback?.invoke()
    }

    private fun read(
        endpoint: UsbEndpoint,
        maxBytes: Int,
        timeoutMillis: Int,
        lock: Any,
    ): ByteArray? =
        synchronized(lock) {
            if (closed || maxBytes !in 1..MAX_READ_BYTES) return@synchronized null
            val buffer = ByteArray(maxBytes)
            val count = connection.bulkTransfer(endpoint, buffer, buffer.size, timeoutMillis)
            when {
                count > 0 -> buffer.copyOf(count)
                count == 0 -> ByteArray(0)
                else -> null
            }
        }

    private companion object {
        const val MAX_READ_BYTES: Int = 1024 * 1024
        const val INITIAL_EVENT_BYTES: Int = 512
        const val USB_DIAG_TAG: String = "UsbPtpDiag"
    }
}
