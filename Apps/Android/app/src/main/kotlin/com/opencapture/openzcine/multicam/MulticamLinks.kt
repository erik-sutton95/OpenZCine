package com.opencapture.openzcine.multicam

import com.opencapture.opencine.runtime.MonitorJpegFrameDecoder
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.openzcine.pairing.PairingEnvironment
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.opencine.nikon.UsbPtpOpenResult
import kotlinx.coroutines.flow.emptyFlow
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/**
 * A member's own link through the saved-profile session factories the camera list uses: its own
 * `SwiftCoreCameraSession` (its own connection owner in the JNI facade) and that session's frames.
 * USB-C needs the body attached and permitted; a network setup dials its saved host.
 */
internal fun multicamLink(record: SavedCameraRecord, environment: PairingEnvironment): MulticamLink {
    val session =
        if (record.transport == SavedCameraTransport.USB_C) {
            val source = environment.usbCameraSource ?: error("USB-C is unavailable")
            val camera =
                source.cameras.value.firstOrNull {
                    it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host
                } ?: error("The camera isn't plugged in")
            when (val opened = source.open(camera)) {
                is UsbPtpOpenResult.Opened -> environment.createSavedProfileUsbSession(opened)
                is UsbPtpOpenResult.Rejected -> error("USB-C open was refused")
            }
        } else {
            environment.createSavedProfileSession(record.host)
        }
    return MulticamLink(session, (session as? SwiftCoreCameraSession)?.liveFrames?.frames ?: emptyFlow())
}

/** Tile-sized JPEG decoding, one bitmap ring per member. */
internal fun multicamDecoder(): (ByteArray) -> android.graphics.Bitmap? {
    val decoder = MonitorJpegFrameDecoder(maxLongSide = TILE_LONG_SIDE)
    return { jpeg -> decoder.decode(jpeg) }
}

private const val TILE_LONG_SIDE = 960
