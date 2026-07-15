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
    }
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
    private var onClosed: (() -> Unit)? = null
    /** A timed-out `requestWait` leaves the request queued; retain its buffer until completion. */
    private var pendingEventBuffer: ByteBuffer? = null

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
            connection.bulkTransfer(bulkOut, bytes, bytes.size, timeoutMillis)
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
    }
}
