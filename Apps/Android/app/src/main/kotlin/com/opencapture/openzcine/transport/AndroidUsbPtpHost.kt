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

/** Platform byte adapter for one claimed USB PTP interface. */
private class AndroidUsbPtpTransport(
    private val connection: UsbDeviceConnection,
    private val usbInterface: UsbInterface,
    private val bulkIn: UsbEndpoint,
    private val bulkOut: UsbEndpoint,
    private val eventRequest: UsbRequest,
) : UsbPtpTransport {
    private val closeLock = Any()
    private val commandLock = Any()
    private val eventLock = Any()
    @Volatile private var closed: Boolean = false
    private var deadWriteRecoveryDone: Boolean = false
    private var onClosed: (() -> Unit)? = null
    /** A timed-out `requestWait` leaves the request queued; retain its buffer until completion. */
    private var pendingEventBuffer: ByteBuffer? = null

    init {
        // Keep one interrupt-IN read pending from claim time: the body only
        // delivers events when the host has a transfer queued. Entering
        // application mode makes the ZR emit StoreRemoved here, and it stalls
        // that switch until the event is drained (see the Swift establish's
        // concurrent event pump). This just ensures a buffer is already
        // waiting before the pump's first read.
        val fresh = ByteBuffer.allocate(INITIAL_EVENT_BYTES)
        if (eventRequest.queue(fresh)) pendingEventBuffer = fresh
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

    override fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray? =
        synchronized(eventLock) {
            if (closed || maxBytes !in 1..MAX_READ_BYTES) return@synchronized null
            val buffer = pendingEventBuffer ?: run {
                val fresh = ByteBuffer.allocate(maxBytes)
                if (!eventRequest.queue(fresh)) return@synchronized null
                pendingEventBuffer = fresh
                fresh
            }
            try {
                val completed = connection.requestWait(timeoutMillis.toLong())
                if (completed !== eventRequest) {
                    // There should be no other request on this connection.
                    // Cancel our queued event read before discarding its
                    // buffer so a later retry never stacks a second request.
                    runCatching { eventRequest.cancel() }
                    pendingEventBuffer = null
                    return@synchronized null
                }
                pendingEventBuffer = null
                buffer.array().copyOf(buffer.position())
            } catch (_: TimeoutException) {
                // A sparse PTP event channel is healthy. JNI maps this empty
                // read to a typed Swift timeout, and the session keeps draining.
                ByteArray(0)
            } catch (_: Throwable) {
                pendingEventBuffer = null
                null
            }
        }

    override fun isClosed(): Boolean = closed

    override fun close() {
        val callback: (() -> Unit)?
        synchronized(closeLock) {
            if (closed) return
            closed = true
            // `requestWait` may currently be blocked on the sparse interrupt
            // pipe. Cancel before releasing the interface so it wakes, then
            // close the request only after the underlying connection is gone.
            runCatching { eventRequest.cancel() }
            runCatching { connection.releaseInterface(usbInterface) }
            connection.close()
            runCatching { eventRequest.close() }
            callback = onClosed
            onClosed = null
        }
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
