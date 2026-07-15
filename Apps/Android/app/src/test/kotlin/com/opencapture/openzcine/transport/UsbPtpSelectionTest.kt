package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** JVM coverage for USB PTP compatibility and privacy-safe saved identities. */
class UsbPtpSelectionTest {
    @Test
    fun `selects only a still-image interface with bulk and interrupt endpoints`() {
        val selection =
            UsbPtpInterfaceSelector.select(
                listOf(
                    UsbPtpInterfaceDescriptor(
                        index = 0,
                        interfaceClass = 3,
                        interfaceSubclass = 1,
                        interfaceProtocol = 1,
                        endpoints = emptyList(),
                    ),
                    UsbPtpInterfaceDescriptor(
                        index = 1,
                        interfaceClass = UsbPtpInterfaceSelector.STILL_IMAGE_INTERFACE_CLASS,
                        interfaceSubclass = 1,
                        interfaceProtocol = 1,
                        endpoints =
                            listOf(
                                UsbPtpEndpointDescriptor(
                                    address = 0x81,
                                    direction = UsbPtpEndpointDirection.IN,
                                    transferType = UsbPtpTransferType.BULK,
                                ),
                                UsbPtpEndpointDescriptor(
                                    address = 0x02,
                                    direction = UsbPtpEndpointDirection.OUT,
                                    transferType = UsbPtpTransferType.BULK,
                                ),
                                UsbPtpEndpointDescriptor(
                                    address = 0x83,
                                    direction = UsbPtpEndpointDirection.IN,
                                    transferType = UsbPtpTransferType.INTERRUPT,
                                ),
                            ),
                    ),
                ),
            )

        assertEquals(
            UsbPtpInterfaceSelection(
                interfaceIndex = 1,
                bulkInAddress = 0x81,
                bulkOutAddress = 0x02,
                eventInAddress = 0x83,
            ),
            selection,
        )
    }

    @Test
    fun `rejects a camera interface without an interrupt event endpoint`() {
        val selection =
            UsbPtpInterfaceSelector.select(
                listOf(
                    UsbPtpInterfaceDescriptor(
                        index = 0,
                        interfaceClass = UsbPtpInterfaceSelector.STILL_IMAGE_INTERFACE_CLASS,
                        interfaceSubclass = 1,
                        interfaceProtocol = 1,
                        endpoints =
                            listOf(
                                UsbPtpEndpointDescriptor(
                                    address = 0x81,
                                    direction = UsbPtpEndpointDirection.IN,
                                    transferType = UsbPtpTransferType.BULK,
                                ),
                                UsbPtpEndpointDescriptor(
                                    address = 0x02,
                                    direction = UsbPtpEndpointDirection.OUT,
                                    transferType = UsbPtpTransferType.BULK,
                                ),
                            ),
                    ),
                ),
            )

        assertNull(selection)
    }

    @Test
    fun `stable USB keys are deterministic scoped and never expose serial`() {
        val first = requireNotNull(UsbCameraHostKey.derive(0x04B0, 0x1234, "ZR-serial-123"))
        val same = UsbCameraHostKey.derive(0x04B0, 0x1234, "ZR-serial-123")
        val otherProduct = UsbCameraHostKey.derive(0x04B0, 0x4321, "ZR-serial-123")

        assertEquals(first, same)
        assertNotEquals(first, otherProduct)
        assertEquals("usb:", first.take(4))
        assertEquals(36, first.length)
        assertTrue(first.matches(Regex("usb:[0-9a-f]{32}")))
        assertFalse(first.contains("ZR-serial-123"))
        assertNull(UsbCameraHostKey.derive(0x04B0, 0x1234, "  "))
    }

    @Test
    fun `permission denial retry and detach reset only in-memory attachment state`() {
        val state = UsbPtpAttachmentState()
        val token = "/dev/bus/usb/001/004"

        state.observeAttached(token)
        assertEquals(
            UsbPtpCameraAccess.NEEDS_PERMISSION,
            state.access(token, hasUsbPermission = false, hasStableIdentity = false),
        )

        state.recordPermissionResult(token, granted = false)
        assertEquals(
            UsbPtpCameraAccess.DENIED,
            state.access(token, hasUsbPermission = false, hasStableIdentity = false),
        )

        state.requestPermissionAgain(token)
        assertEquals(
            UsbPtpCameraAccess.NEEDS_PERMISSION,
            state.access(token, hasUsbPermission = false, hasStableIdentity = false),
        )

        state.recordPermissionResult(token, granted = true)
        assertEquals(
            UsbPtpCameraAccess.IDENTITY_UNAVAILABLE,
            state.access(token, hasUsbPermission = true, hasStableIdentity = false),
        )
        assertEquals(
            UsbPtpCameraAccess.READY,
            state.access(token, hasUsbPermission = true, hasStableIdentity = true),
        )

        state.markTransportOpened(token)
        assertTrue(state.detach(token))
        assertNull(state.access(token, hasUsbPermission = true, hasStableIdentity = true))
    }

    @Test
    fun `a cancelled transport clears active state before a later detach`() {
        val state = UsbPtpAttachmentState()
        val token = "/dev/bus/usb/001/005"

        state.observeAttached(token)
        state.markTransportOpened(token)
        state.markTransportClosed(token)

        assertFalse(state.detach(token))
        assertNull(state.access(token, hasUsbPermission = true, hasStableIdentity = true))
    }

    @Test
    fun `a detach invalidates an in-flight open lease before it can publish a transport`() {
        val state = UsbPtpAttachmentState()
        val token = "/dev/bus/usb/001/006"

        state.observeAttached(token)
        val originalLease = requireNotNull(state.captureOpenLease(token))

        state.detach(token)
        state.observeAttached(token)

        assertFalse(state.isCurrent(originalLease))
        assertTrue(requireNotNull(state.captureOpenLease(token)).generation > originalLease.generation)
    }
}
