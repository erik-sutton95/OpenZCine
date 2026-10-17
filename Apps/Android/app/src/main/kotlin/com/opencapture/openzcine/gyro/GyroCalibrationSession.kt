package com.opencapture.openzcine.gyro

import com.opencapture.openzcine.bridge.SwiftCore
import org.json.JSONObject

/** Opaque calibration boundary; Swift owns pose acceptance, fitting and verification. */
internal interface GyroCalibrationNative {
    fun create(): String
    fun add(owner: String, observationJSON: String): String?
    fun capture(owner: String, timestamp: Double): String?
    fun close(owner: String)
    fun validate(calibrationJSON: String): Boolean
}

internal object SwiftGyroCalibrationNative : GyroCalibrationNative {
    override fun create(): String = SwiftCore.gyroCalibrationCreate()
    override fun add(owner: String, observationJSON: String): String? = SwiftCore.gyroCalibrationAdd(owner, observationJSON)
    override fun capture(owner: String, timestamp: Double): String? = SwiftCore.gyroCalibrationCapture(owner, timestamp)
    override fun close(owner: String) = SwiftCore.gyroCalibrationClose(owner)
    override fun validate(calibrationJSON: String): Boolean = SwiftCore.gyroCalibrationValidate(calibrationJSON)
}

/** UI progress returned by the core; a result appears only after independent verification. */
internal data class GyroCalibrationState(val active: Boolean = false, val poseCount: Int = 0,
    val error: String? = null, val calibration: String? = null)

/** Converts the camera's CLOCK_MONOTONIC stamp without erasing the original frame age. */
internal fun cameraCalibrationTimestamp(frameNanos: Long, bootNanos: Long, monotonicNanos: Long): Double =
    (frameNanos + (bootNanos - monotonicNanos)) / 1_000_000_000.0

/** Retires native owners exactly once and never publishes an unverified calibration. */
internal class GyroCalibrationSession(private val native: GyroCalibrationNative) {
    private var owner: String? = null
    var state: GyroCalibrationState = GyroCalibrationState()
        private set

    fun start() {
        cancel()
        owner = native.create()
        state = GyroCalibrationState(active = true)
    }

    fun add(observationJSON: String) {
        val active = owner ?: return
        accept(native.add(active, observationJSON), preserveError = true)
    }

    fun capture(timestamp: Double) {
        val active = owner ?: return
        accept(native.capture(active, timestamp), preserveError = false)
    }

    fun cancel(error: String? = null) {
        owner?.let(native::close)
        owner = null
        state = GyroCalibrationState(error = error)
    }

    private fun accept(payload: String?, preserveError: Boolean) {
        val reply = JSONObject(requireNotNull(payload) { "Calibration did not accept the operation." })
        val count = reply.getInt("poseCount")
        val calibration = reply.optJSONObject("calibration")?.toString()
        if (calibration != null) {
            check(count == 3 && native.validate(calibration)) { "Calibration verification failed." }
            owner?.let(native::close)
            owner = null
        }
        state = GyroCalibrationState(active = owner != null, poseCount = count,
            error = if (!reply.isNull("error")) reply.getString("error")
                else if (preserveError) state.error else null, calibration = calibration)
    }
}
