package com.opencapture.openzcine.multicam

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.asImageBitmap
import com.opencapture.openzcine.JpegFrameDecoder
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.openzcine.pairing.PairingEnvironment
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.opencine.nikon.UsbPtpOpenResult
import kotlinx.coroutines.flow.emptyFlow

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
internal fun multicamDecoder(): (ByteArray) -> androidx.compose.ui.graphics.ImageBitmap? {
    val decoder = JpegFrameDecoder(maxLongSide = TILE_LONG_SIDE)
    return { jpeg -> decoder.decode(jpeg)?.asImageBitmap() }
}

private const val TILE_LONG_SIDE = 960

/** Set while Live View shows a lent multicam member: the lock slot becomes Return to Multicam. */
val LocalMulticamReturn = staticCompositionLocalOf<(() -> Unit)?> { null }
