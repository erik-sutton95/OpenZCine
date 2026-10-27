package com.opencapture.openzcine

import com.opencapture.opencine.gyro.GyroHostConfiguration
import com.opencapture.opencine.gyro.GyroLegacyPreferenceKeys
import com.opencapture.opencine.gyro.GyroPillKind
import com.opencapture.opencine.gyro.GyroPreferenceKeys
import java.io.File

internal fun openZCineGyroHostConfiguration(filesDir: File): GyroHostConfiguration =
    GyroHostConfiguration(
        appName = "OpenZCine",
        logRoot = File(filesDir, "gyro-logs"),
        preferencesName = "gyro-logging",
        keys = GyroPreferenceKeys.namespaced("gyro.v2."),
        legacy =
            GyroLegacyPreferenceKeys(
                enabled = "enabled",
                mountPreset = "mountPreset",
                calibration = "mountCalibration",
            ),
    )

internal suspend fun disconnectAfterGyroPreparation(
    isArmed: Boolean,
    prepare: suspend () -> Unit,
    disconnect: suspend () -> Unit,
) {
    try {
        if (isArmed) prepare()
    } finally {
        disconnect()
    }
}

internal fun gyroPillVisibleInCleanMode(kind: GyroPillKind): Boolean =
    kind == GyroPillKind.ERROR || kind == GyroPillKind.MOUNT_MOVED || kind == GyroPillKind.GAPS
