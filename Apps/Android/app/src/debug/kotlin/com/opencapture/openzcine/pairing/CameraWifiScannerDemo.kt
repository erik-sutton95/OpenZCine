package com.opencapture.openzcine.pairing

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper

/**
 * Debug-only scanner fixture for visual QA, isolated from release builds.
 *
 * Launch with `--es zc.demo.cameraWifi fixture` to inspect the confirmation
 * layout. Its values are deliberately non-credentials and the surface marks
 * them as a fixture, so this hook cannot be mistaken for hardware OCR.
 */
internal object CameraWifiScannerDemo {
    private const val EXTRA_CAMERA_WIFI_SCANNER = "zc.demo.cameraWifi"

    fun initialCandidate(context: Context): CameraWifiScanCandidate? =
        if (context.findActivityForCameraWifiDemo()?.intent?.getStringExtra(EXTRA_CAMERA_WIFI_SCANNER) ==
            "fixture"
        ) {
            CameraWifiScanCandidate(
                ssid = "NIKON_ZR_FIXTURE",
                key = "DEMO-KEY-NOT-REAL",
                isDebugFixture = true,
            )
        } else {
            null
        }
}

private tailrec fun Context.findActivityForCameraWifiDemo(): Activity? =
    when (this) {
        is Activity -> this
        is ContextWrapper -> baseContext.findActivityForCameraWifiDemo()
        else -> null
    }
