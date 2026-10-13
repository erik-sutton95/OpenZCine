package com.opencapture.openzcine.gyro

import com.opencapture.openzcine.bridge.SwiftCore
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Coarse native bridge; Kotlin owns no take segmentation or motion export math. */
internal interface GyroNative {
    fun mountPresets(naturalPortrait: Boolean): String
    fun create(): String
    fun ingest(owner: String, bytes: ByteArray): String?
    fun observe(owner: String, recording: Boolean, timestamp: Double, dateSeconds: Double,
        cameraLabel: String, mountPreset: String = "unconfigured"): String?
    fun poll(owner: String, timestamp: Double): String?
    fun finish(owner: String, reason: String, timestamp: Double): String?
    fun close(owner: String)
    fun recoveryCreate(): String
    fun recoveryAccept(owner: String, bytes: ByteArray): Long
    fun recoveryFinish(owner: String, descriptor: String): String?
}

internal object SwiftGyroNative : GyroNative {
    override fun mountPresets(naturalPortrait: Boolean): String = SwiftCore.gyroMountPresets(naturalPortrait)
    override fun create(): String = SwiftCore.gyroCreate()
    override fun ingest(owner: String, bytes: ByteArray): String? = SwiftCore.gyroIngest(owner, bytes)
    override fun observe(owner: String, recording: Boolean, timestamp: Double, dateSeconds: Double,
        cameraLabel: String, mountPreset: String): String? =
        SwiftCore.gyroObserve(owner, recording, timestamp, dateSeconds, cameraLabel, mountPreset)
    override fun poll(owner: String, timestamp: Double): String? = SwiftCore.gyroPoll(owner, timestamp)
    override fun finish(owner: String, reason: String, timestamp: Double): String? = SwiftCore.gyroFinish(owner, reason, timestamp)
    override fun close(owner: String) = SwiftCore.gyroClose(owner)
    override fun recoveryCreate(): String = SwiftCore.gyroRecoveryCreate()
    override fun recoveryAccept(owner: String, bytes: ByteArray): Long = SwiftCore.gyroRecoveryAccept(owner, bytes)
    override fun recoveryFinish(owner: String, descriptor: String): String? = SwiftCore.gyroRecoveryFinish(owner, descriptor)
}

/** One platform reading, copied immediately because SensorEvent reuses its values array. */
internal data class AndroidGyroSample(val timestamp: Double, val x: Double, val y: Double, val z: Double)

/** Preserves sensor timestamps and radian rates in the shared wire's little-endian layout. */
internal fun encodeGyroBatch(samples: List<AndroidGyroSample>): ByteArray {
    require(samples.size <= 512) { "Gyro batch exceeds the bounded capture queue." }
    val buffer = ByteBuffer.allocate(samples.size * 32).order(ByteOrder.LITTLE_ENDIAN)
    samples.forEach { sample ->
        buffer.putDouble(sample.timestamp).putDouble(sample.x).putDouble(sample.y).putDouble(sample.z)
    }
    return buffer.array()
}
