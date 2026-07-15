package com.opencapture.openzcine.pairing

import android.content.Context

/** Release builds never inject scanner candidates. */
internal object CameraWifiScannerDemo {
    @Suppress("UNUSED_PARAMETER")
    fun initialCandidate(context: Context): CameraWifiScanCandidate? = null
}
