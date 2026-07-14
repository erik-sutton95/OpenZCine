package com.opencapture.openzcine.core

/**
 * Identifies a discovered or connected camera.
 *
 * @property name User-visible camera name (for example `"Nikon ZR"`).
 * @property model Camera model designation as reported by the device.
 * @property serialNumber Unique serial reported by the camera, used to
 *   recognise previously paired bodies.
 */
public data class CameraIdentity(
    val name: String,
    val model: String,
    val serialNumber: String,
)
