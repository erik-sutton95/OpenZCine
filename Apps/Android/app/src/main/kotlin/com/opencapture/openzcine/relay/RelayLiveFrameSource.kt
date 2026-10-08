package com.opencapture.openzcine.relay

import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.opencine.runtime.MonitorHevcJpegDecodePolicy
import com.opencapture.opencine.runtime.MonitorRelayHevcJpegDecoder

import com.opencapture.opencine.nikon.liveFeedRotationFromWire
import com.opencapture.opencine.nikon.LiveCameraLevel
import com.opencapture.opencine.nikon.LiveFocusBox
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.LiveFocusResult
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.LiveFrameTimecode
import kotlinx.coroutines.flow.Flow

import com.opencapture.opencine.relayruntime.RelayDecodedPictureOwner
import com.opencapture.opencine.relayruntime.RelayPictureDecode
import com.opencapture.opencine.relayruntime.RelayPictureDecoder
import com.opencapture.opencine.relayruntime.RelayPicturePolicy
import java.util.UUID

/** Exact Nikon wire-to-native observations over shared native and picture/source owners. */
class RelayLiveFrameSource : LiveFrameSource {
    private val hevc = HevcFrameDecoder(
        policy = MonitorHevcJpegDecodePolicy(
            width = 1920, height = 1080, inputTimeoutMicros = 20_000L,
            firstDrainTimeoutMicros = 12_000L, frameStepMicros = 40_000L,
            softwareFallbackFedFrames = 75, maximumConsecutiveSoftwareRebuilds = 3,
            softwareDecoderName = "c2.android.hevc.decoder", jpegQuality = 88,
        ),
    )
    var onHevcExhausted: (() -> Unit)? = null
    internal val pictureOwner = RelayDecodedPictureOwner<MonitorRelayWire.FrameMetadata, LiveFrame>(
        decoder = object : RelayPictureDecoder<MonitorRelayWire.FrameMetadata> {
            override fun beginSource(source: UUID) { hevc.beginSource(source) }
            override fun decode(source: UUID, metadata: MonitorRelayWire.FrameMetadata, bytes: ByteArray): RelayPictureDecode =
                when (metadata.codec) {
                    MonitorRelayWire.FrameCodec.JPEG -> RelayPictureDecode(bytes)
                    MonitorRelayWire.FrameCodec.HEVC -> RelayPictureDecode(
                        hevc.decodeToJpeg(bytes, metadata.isKeyframe, metadata.parameterSets, source),
                        exhausted = hevc.isPausedForStream,
                    )
                    else -> RelayPictureDecode(null)
                }
            override fun retireSource(source: UUID) { hevc.retireSource(source) }
            override fun close() { hevc.close() }
        },
        policy = RelayPicturePolicy(extraFrameCapacity = 2, previousCadenceWeight = 0.8,
            latestCadenceWeight = 0.2, minimumCadenceDeltaSeconds = 0.0001),
        project = { metadata, jpeg, reading ->
            val roll = metadata.levelRoll
            val pitch = metadata.levelPitch
            LiveFrame(
                timestampNanos = reading.timestampNanos,
                jpegData = jpeg,
                isRecording = metadata.isRecording,
                // Wire sound levels are the body's raw meter segments; [RelayAudioMeter] is the
                // core's own segment→dBFS mapping, so the watcher's meters move with the
                // broadcaster's instead of mounting dead. Absent still means "no indicator in
                // this header", which is the iOS watcher's behavior too.
                audioLevels = metadata.sound?.let(RelayAudioMeter::levels),
                focus =
                    metadata.focus?.let { focus ->
                        LiveFocusInfo(
                            coordinateWidth = focus.coordinateWidth,
                            coordinateHeight = focus.coordinateHeight,
                            result =
                                when (focus.focusResult) {
                                    1 -> LiveFocusResult.NOT_FOCUSED
                                    2 -> LiveFocusResult.FOCUSED
                                    else -> LiveFocusResult.UNKNOWN
                                },
                            subjectDetectionActive = focus.subjectDetectionActive,
                            trackingAFActive = focus.trackingAFActive,
                            selectedBoxIndex = focus.selectedBoxIndex,
                            boxes =
                                focus.boxes.map {
                                    LiveFocusBox(it.centerX, it.centerY, it.width, it.height)
                                },
                        )
                    },
                level =
                    if (roll != null && pitch != null) {
                        LiveCameraLevel(
                            rollDegrees = roll,
                            pitchDegrees = pitch,
                            yawDegrees = 0.0,
                        )
                    } else {
                        null
                    },
                timecode =
                    metadata.timecode?.let {
                        LiveFrameTimecode(it.on, it.hour, it.minute, it.second, it.frame)
                    },
                measuredFramesPerSecond = reading.framesPerSecond,
                // The broadcaster's body orientation rides every frame: a watcher of a vertical
                // broadcast rotates the picture upright exactly like the broadcaster does
                // (iOS `applyRelayFrameReadings`). Absent on an older host means landscape.
                rotation = liveFeedRotationFromWire(metadata.rotation ?: 0),
            )
        },
    )
    override val frames: Flow<LiveFrame> = pictureOwner.frames
    init {
        pictureOwner.onExhausted = { onHevcExhausted?.invoke() }
        pictureOwner.beginSource(UUID.randomUUID())
    }
    fun submit(metadata: MonitorRelayWire.FrameMetadata, image: ByteArray) {
        val source = pictureOwner.currentSource ?: return
        pictureOwner.submit(source, metadata, image)
    }
    fun release() { pictureOwner.close() }
}

/** Compatibility name; the actual native codec/reference/fallback owner is shared. */
internal typealias HevcFrameDecoder = MonitorRelayHevcJpegDecoder
