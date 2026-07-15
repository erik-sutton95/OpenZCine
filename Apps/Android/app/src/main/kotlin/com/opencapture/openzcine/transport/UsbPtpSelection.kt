package com.opencapture.openzcine.transport

import java.security.MessageDigest

/** Direction of one USB endpoint, kept Android-free for JVM coverage. */
public enum class UsbPtpEndpointDirection {
    IN,
    OUT,
}

/** USB transfer kind relevant to a PTP host interface. */
public enum class UsbPtpTransferType {
    BULK,
    INTERRUPT,
    OTHER,
}

/** Android-independent endpoint description used by [UsbPtpInterfaceSelector]. */
public data class UsbPtpEndpointDescriptor(
    public val address: Int,
    public val direction: UsbPtpEndpointDirection,
    public val transferType: UsbPtpTransferType,
)

/** Android-independent USB interface description used by [UsbPtpInterfaceSelector]. */
public data class UsbPtpInterfaceDescriptor(
    public val index: Int,
    public val interfaceClass: Int,
    public val interfaceSubclass: Int,
    public val interfaceProtocol: Int,
    public val endpoints: List<UsbPtpEndpointDescriptor>,
)

/** The three endpoints OpenZCine requires for a complete PTP host session. */
public data class UsbPtpInterfaceSelection(
    public val interfaceIndex: Int,
    public val bulkInAddress: Int,
    public val bulkOutAddress: Int,
    public val eventInAddress: Int,
)

/**
 * Chooses a standard USB Still Image / PTP interface without making protocol
 * decisions in Kotlin. A production session requires a bulk IN/OUT pair for
 * transactions and an interrupt IN endpoint for camera-pushed events.
 */
public object UsbPtpInterfaceSelector {
    /** USB class code for Still Image / PTP devices. */
    public const val STILL_IMAGE_INTERFACE_CLASS: Int = 6

    /** Returns the first complete PTP interface in device descriptor order. */
    public fun select(
        interfaces: List<UsbPtpInterfaceDescriptor>,
    ): UsbPtpInterfaceSelection? =
        interfaces.firstNotNullOfOrNull { candidate ->
            if (candidate.interfaceClass != STILL_IMAGE_INTERFACE_CLASS) return@firstNotNullOfOrNull null
            val bulkIn =
                candidate.endpoints.firstOrNull {
                    it.transferType == UsbPtpTransferType.BULK &&
                        it.direction == UsbPtpEndpointDirection.IN
                }
            val bulkOut =
                candidate.endpoints.firstOrNull {
                    it.transferType == UsbPtpTransferType.BULK &&
                        it.direction == UsbPtpEndpointDirection.OUT
                }
            val eventIn =
                candidate.endpoints.firstOrNull {
                    it.transferType == UsbPtpTransferType.INTERRUPT &&
                        it.direction == UsbPtpEndpointDirection.IN
                }
            if (bulkIn == null || bulkOut == null || eventIn == null) {
                null
            } else {
                UsbPtpInterfaceSelection(
                    interfaceIndex = candidate.index,
                    bulkInAddress = bulkIn.address,
                    bulkOutAddress = bulkOut.address,
                    eventInAddress = eventIn.address,
                )
            }
        }
}

/**
 * Privacy-safe persistent identity for a USB camera.
 *
 * The USB serial never leaves the platform layer: the saved-camera host key
 * contains only a SHA-256 digest scoped by USB vendor/product IDs. The digest
 * is a local persistence/reconnect key, never an operator-facing label, log
 * value, or network address. A missing serial intentionally yields null rather
 * than persisting an unstable kernel device path as if it were a camera identity.
 */
public object UsbCameraHostKey {
    /** Creates a stable `usb:<digest>` key, or null when no serial is available. */
    public fun derive(vendorId: Int, productId: Int, serialNumber: String?): String? {
        val serial = serialNumber?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val material = "$vendorId:$productId:$serial".encodeToByteArray()
        val digest = MessageDigest.getInstance("SHA-256").digest(material)
        return "usb:" + digest.take(HOST_KEY_DIGEST_BYTES).joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xFF)
        }
    }

    private const val HOST_KEY_DIGEST_BYTES: Int = 16
}

/** In-memory lease for one physical attachment generation of a USB device token. */
internal data class UsbPtpAttachmentLease(
    val token: String,
    val generation: Long,
)

/**
 * Android-free attach, permission, and active-transport state for a USB PTP
 * device token.
 *
 * `UsbManager` remains the source of truth for physical authorization; this
 * class owns only the app-local recovery state that must survive receiver
 * callbacks long enough to render an actionable card. It deliberately keeps
 * Android device names in memory only and never turns them into saved keys.
 */
public class UsbPtpAttachmentState {
    private val attachedTokens = mutableSetOf<String>()
    private val deniedTokens = mutableSetOf<String>()
    private val activeTransportTokens = mutableSetOf<String>()
    private val attachmentGenerations = mutableMapOf<String, Long>()
    private var nextAttachmentGeneration: Long = 0

    /** Records a currently attached compatible device. Idempotent. */
    @Synchronized
    public fun observeAttached(token: String) {
        if (attachedTokens.add(token)) {
            nextAttachmentGeneration += 1
            attachmentGenerations[token] = nextAttachmentGeneration
        }
    }

    /**
     * Captures the current physical attachment generation before Android opens
     * a claimed interface. A later detach/re-attach with the same kernel token
     * intentionally invalidates this lease.
     */
    @Synchronized
    internal fun captureOpenLease(token: String): UsbPtpAttachmentLease? {
        val generation = attachmentGenerations[token] ?: return null
        if (token !in attachedTokens) return null
        return UsbPtpAttachmentLease(token, generation)
    }

    /** Whether [lease] still refers to the same currently attached device. */
    @Synchronized
    internal fun isCurrent(lease: UsbPtpAttachmentLease): Boolean =
        lease.token in attachedTokens && attachmentGenerations[lease.token] == lease.generation

    /** Records Android's per-device permission result. */
    @Synchronized
    public fun recordPermissionResult(token: String, granted: Boolean) {
        if (granted) {
            deniedTokens -= token
        } else if (token in attachedTokens) {
            deniedTokens += token
        }
    }

    /** Clears a prior denial when the operator explicitly asks Android again. */
    @Synchronized
    public fun requestPermissionAgain(token: String) {
        deniedTokens -= token
    }

    /** Marks a raw transport as active for [token] after endpoint claim succeeds. */
    @Synchronized
    public fun markTransportOpened(token: String) {
        if (token in attachedTokens) activeTransportTokens += token
    }

    /** Marks a transport as closed without changing attachment or permission state. */
    @Synchronized
    public fun markTransportClosed(token: String) {
        activeTransportTokens -= token
    }

    /**
     * Clears all ephemeral state on physical detach and returns whether a raw
     * transport must be closed before publishing the new discovery snapshot.
     */
    @Synchronized
    public fun detach(token: String): Boolean {
        attachedTokens -= token
        deniedTokens -= token
        attachmentGenerations -= token
        return activeTransportTokens.remove(token)
    }

    /** Current UI access state, or null when this token is no longer attached. */
    @Synchronized
    public fun access(
        token: String,
        hasUsbPermission: Boolean,
        hasStableIdentity: Boolean,
    ): UsbPtpCameraAccess? {
        if (token !in attachedTokens) return null
        return when {
            hasUsbPermission && hasStableIdentity -> UsbPtpCameraAccess.READY
            hasUsbPermission -> UsbPtpCameraAccess.IDENTITY_UNAVAILABLE
            token in deniedTokens -> UsbPtpCameraAccess.DENIED
            else -> UsbPtpCameraAccess.NEEDS_PERMISSION
        }
    }
}
