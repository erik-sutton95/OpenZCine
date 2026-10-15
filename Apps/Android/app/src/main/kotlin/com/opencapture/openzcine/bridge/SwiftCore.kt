package com.opencapture.openzcine.bridge

import android.system.Os
import com.opencapture.opencine.nikon.NikonNative
import java.util.TimeZone

/**
 * JNI binding to `libOpenZCineAndroid.so` — the shared Swift core
 * (`Sources/OpenZCineCore`) plus its facade (`Sources/OpenZCineAndroidFacade`). The Nikon
 * session natives in the same library belong to OpenCine's `NikonNative` (Android `:nikon`).
 *
 * The native library is a build artifact staged into `jniLibs/` by
 * `just android-core`; it is never committed. Every `external fun` here must
 * have a matching `@_cdecl` shim in
 * `Sources/OpenZCineAndroidFacade/SwiftCoreJNI.swift`.
 */
object SwiftCore {
    /**
     * True when the Swift core library is bundled and loaded. False (with no
     * crash) when the APK was built without running `just android-core` first.
     */
    val isAvailable: Boolean by lazy {
        // The same library implements the Nikon session natives (OpenCine's NikonNative), so
        // it is loaded through NikonNative, which then reports them available too. MainActivity
        // touches this first thing in onCreate, before any camera session exists.
        if (!NikonNative.load("OpenZCineAndroid")) return@lazy false
        // Swift Foundation on Android resolves `TimeZone.current` from the libc zone
        // ABBREVIATION ("KST", "CEST"), which ICU rarely recognises, and falls back to
        // GMT, so every Calendar.current wall clock in the core was UTC. The camera
        // clock sync then wrote UTC into a body that keeps local time (#369). The TZ
        // env var is the one input Foundation resolves reliably. Foundation reads it
        // lazily on first use, so after load (before any entry point) is early enough
        // and keeps the no-core JVM path free of the android.jar stub.
        // ponytail: read once per process; a zone change while the app runs needs a
        // restart, re-set it on ACTION_TIMEZONE_CHANGED if that ever matters.
        Os.setenv("TZ", TimeZone.getDefault().id, true)
        true
    }

    /** Receives connection-phase updates pushed from Swift (non-main thread). */
    fun interface ConnectionPhaseListener {
        /** Called once per phase with operator-facing copy resolved by the core. */
        fun onPhase(title: String, detail: String)
    }

    /** Core build identity string, resolved inside the Swift library. */
    external fun coreVersion(): String

    /**
     * Advances decoded-playback stereo peaks through Swift's shared dBFS and meter-ballistics
     * policy. [previousPayload] is empty for a new meter or the complete six-value payload from
     * the prior call; the returned state includes both peak ages so hold survives Android polls.
     */
    external fun playbackAudioMeterStep(
        previousPayload: FloatArray,
        leftPeakLinear: Float,
        rightPeakLinear: Float,
        deltaTimeSeconds: Float,
    ): FloatArray?

    /**
     * Registers [listener] and has Swift push a canned connection-phase
     * sequence from a background thread — the callback shape session events
     * and live-view frames will use.
     */
    external fun startConnectionDemo(listener: ConnectionPhaseListener)

    // ── Scopes (camera axis and Traffic Lights in the Swift core; sampling and plots shared) ──

    /**
     * The shared scopes' level axis for this camera: `[256 code-to-IRE levels,
     * middle-grey IRE]` (Swift `ScopeFrameWire.levelAxis`). Black lands on the
     * crush line, mid grey at its fixed per-curve level and [clipNative] (the
     * camera-resolved warning endpoint) on the clip line. Call once per mapping.
     */
    external fun scopeLevelAxis(curve: Int, clipNative: Float): FloatArray

    /**
     * The core Traffic Lights meter on the shared sampler's four 256-bin
     * histograms (luma, red, green, blue, concatenated): `(level, clip, crush)
     * × RGB` (Swift `ScopeFrameWire.trafficLights`). [crushClipCompensationRaw]
     * is the persisted raw `AssistConfiguration.CrushClipCompensation`; Swift
     * alone applies it.
     */
    external fun scopeTrafficLights(
        histograms: FloatArray,
        curve: Int,
        clipNative: Float,
        crushClipCompensationRaw: Int,
    ): FloatArray

    // ── Feed effects (colour math baked in the core, uploaded by Kotlin) ──

    /**
     * A built-in monitor look baked by the core into a packed-2D RGBA8 grid
     * (`size³ × 4` bytes) for a `width = size²`, `height = size` texture:
     * pixel `(x = b·size + r, y = g)` — slice tiles along x, so a shader
     * trilinearly samples with two bilinear taps. Null for an unknown
     * [lookOrdinal] (`FeedLut.wireOrdinal`) or size outside 2–64. Bake once
     * per selection (the cube generation is ~10⁵ transcendental calls), never
     * per frame.
     */
    external fun bakeLut(lookOrdinal: Int, size: Int): ByteArray?

    /**
     * Resolves the active camera signal mapping in Swift: `[curveOrdinal,
     * blackNative, middleGrayNative, clipNative]`. Kotlin forwards raw
     * camera metadata only; it never selects a curve or derives a clip code.
     * A non-null [stillsToneMode] marks the photo selector active — Swift
     * then anchors on the display-referred stills preview (sRGB/HLG) instead
     * of the movie codec's log curve.
     */
    external fun exposureAssistMapping(
        codec: String?,
        iso: Long,
        baseIso: String?,
        stillsToneMode: String?,
    ): FloatArray

    /**
     * Converts a canonical monitor-percent zebra threshold into an editor
     * value. Unsupported [unitOrdinal] returns `NaN` and callers must leave
     * the saved canonical setting untouched.
     */
    external fun zebraEditorValue(
        codec: String?,
        iso: Long,
        baseIso: String?,
        stillsToneMode: String?,
        unitOrdinal: Int,
        monitorPercent: Float,
    ): Float

    /**
     * Converts a native-code or monitor-IRE zebra editor value into the
     * canonical 0…100 monitor axis. Unsupported input returns `NaN`.
     */
    external fun zebraMonitorPercent(
        codec: String?,
        iso: Long,
        baseIso: String?,
        stillsToneMode: String?,
        unitOrdinal: Int,
        editorValue: Float,
    ): Float

    /**
     * Swift-resolved shader record for source-measured peaking and dual
     * zebras. It contains the camera curve, de-log anchors, sensitivity
     * threshold/ramp, and all overlay RGB; Kotlin only validates and uploads
     * it (see `FeedEffectsRenderConfiguration`).
     */
    external fun feedEffectsConfiguration(
        codec: String?,
        iso: Long,
        baseIso: String?,
        stillsToneMode: String?,
        peakingSensitivity: Int,
        peakingColor: Int,
        highlightEnabled: Boolean,
        highlightIre: Float,
        highlightColor: Int,
        midtoneEnabled: Boolean,
        midtoneIre: Float,
        midtoneColor: Int,
    ): FloatArray?

    /**
     * The core's false-colour cube (64³) in the same packed-2D RGBA8 grid.
     * [scaleOrdinal] is `FeedFalseColorScale.wireOrdinal`; [curveOrdinal]
     * and [clipNative] are already resolved by [exposureAssistMapping]. Null
     * for unsupported scales or curve records.
     */
    external fun bakeFalseColorCube(
        scaleOrdinal: Int,
        curveOrdinal: Int,
        clipNative: Float,
    ): ByteArray?

    /** Swift-owned Limits paint cube for composition over the selected LUT. */
    external fun bakeFalseColorLimitsPaint(curveOrdinal: Int, clipNative: Float): ByteArray?

    /** Swift-owned Limits zone-weight cube paired with the paint cube. */
    external fun bakeFalseColorLimitsWeight(curveOrdinal: Int, clipNative: Float): ByteArray?

    /**
     * Versioned reference-panel segments and stop-marker geometry, taken from
     * the exact false-colour scale/mapping that produced the GPU cube.
     */
    external fun falseColorReference(
        scaleOrdinal: Int,
        curveOrdinal: Int,
        clipNative: Float,
    ): FloatArray?

    /**
     * Assist thresholds on the normalized 0–1 code axis:
     * `[deLogBlack, deLogClip, zebraHighlight, zebraMidtoneCentre]` — the
     * peaking de-log anchors and zebra comparison codes, computed by the
     * core's `ExposureSignalMapping` for [curveOrdinal] and the given
     * monitor-percent thresholds. Null for an unknown curve ordinal.
     */
    external fun feedEffectsScalars(
        curveOrdinal: Int,
        zebraHighlightIre: Float,
        zebraMidtoneIre: Float,
    ): FloatArray?

    // Distinct shared-monitor entries beside the retained legacy declarations.
    external fun bakeMonitorFalseColorCube(
        scaleOrdinal: Int,
        curveOrdinal: Int,
        clipNative: Float,
    ): ByteArray?

    external fun bakeMonitorFalseColorLimitsPaint(curveOrdinal: Int, clipNative: Float): ByteArray?

    external fun bakeMonitorFalseColorLimitsWeight(curveOrdinal: Int, clipNative: Float): ByteArray?

    external fun monitorFalseColorReference(
        scaleOrdinal: Int,
        curveOrdinal: Int,
        clipNative: Float,
    ): FloatArray?

    // ── Stored LUT library (strict Swift parser + existing packed cube path) ──

    /**
     * Runs the shared `CubeLUT.validatedImport` gate over an app-private cube and packs it into the
     * existing RGBA8 2D texture layout used by [com.opencapture.openzcine.FeedEffectsRenderer].
     * Null is a refused or corrupt cube; Kotlin must not parse or sample the cube as a fallback.
     */
    external fun packImportedLut(utf8: ByteArray): ByteArray?

    /**
     * Resolves the shared `RedLUTDownloadPolicy` decision as a versioned `US`-separated record
     * `[version, state]`: 0 = available, 1 = camera AP, 2 = no internet. Kotlin only decodes that
     * record into UI copy; it does not duplicate the camera-AP precedence rule.
     */
    external fun redLutDownloadAvailability(
        hasInternetPath: Boolean,
        isOnCameraAccessPoint: Boolean,
    ): String?

    // ── Link health and preview policy (Swift owns the policy) ──

    /**
     * Resolves Android's persisted stream choices through the shared Swift
     * preview policy. The result is `imageSize<TAB>compression<TAB>intervalNanos`;
     * Kotlin stores/presents the choices but never maps them to Nikon bytes or
     * applies thermal caps itself. Null rejects an unknown wire value.
     *
     * This affects only the live-view JPEG preview. It never changes camera
     * recording format, codec, frame rate, or an active card write.
     */
    /**
     * @param recordingFrameRate Camera-advertised movie fps (e.g. 25 for 6K·25p).
     *   Pass 0 when unknown so Swift applies its default cadence.
     */
    external fun resolveLiveViewRequest(
        streamPreset: Int,
        qualityBias: Int,
        thermalTier: Int,
        isRecording: Boolean,
        cameraOverheating: Boolean,
        recordingFrameRate: Int,
    ): String?



}
