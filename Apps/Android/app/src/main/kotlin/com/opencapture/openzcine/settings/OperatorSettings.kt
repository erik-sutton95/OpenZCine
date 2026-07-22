package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateOf
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.FeedEffectsConfiguration
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedZebraStripeColor
import com.opencapture.openzcine.FeedZebraUnit
import com.opencapture.openzcine.R
import kotlin.math.roundToInt

/**
 * Top-level monitor layout selected by the operator's DISP button.
 *
 * [wireIndex] is the shared Swift zone-map mode value. Persisted order and
 * enablement use the stable enum names instead, so a reordered list never
 * changes the core protocol boundary.
 */
public enum class MonitorDisplayMode(
    /** Operator-facing settings label. */
    public val label: String,
    /** Stable shared-zone-map value (live = 0, clean = 1, command = 2). */
    public val wireIndex: Int,
) {
    /** Camera feed with operator overlays and controls. */
    LIVE("Live", 0),

    /** Camera feed with the live tool chrome removed. */
    CLEAN("Clean", 1),

    /** Camera-backed command dashboard with the live-view consumer released. */
    COMMAND("Command", 2),
    ;

    internal companion object {
        fun fromStoredName(value: String): MonitorDisplayMode? {
            val normalized = value.trim()
            return entries.firstOrNull {
                it.name.equals(normalized, ignoreCase = true) ||
                    it.label.equals(normalized, ignoreCase = true)
            }
        }
    }
}

/** Localized label used by phone monitor and settings presentation. */
@StringRes
internal fun MonitorDisplayMode.labelResource(): Int =
    when (this) {
        MonitorDisplayMode.LIVE -> R.string.display_mode_live
        MonitorDisplayMode.CLEAN -> R.string.display_mode_clean
        MonitorDisplayMode.COMMAND -> R.string.display_mode_command
    }

/**
 * Operator-selected presentation of the live feed in the portrait monitor.
 *
 * The stable names mirror the shared core's `PortraitFeedAspect` cases. This
 * preference changes only the shared zone-map input and the local image crop;
 * it never changes the camera stream or recording format.
 */
public enum class PortraitFeedAspect(
    /** Whether the shared zone map and feed renderer should use fill geometry. */
    public val fillsViewport: Boolean,
) {
    /** Keep the whole 16:9 image visible. */
    FIT_16_9(false),

    /** Fill the shared portrait feed zone and centre-crop the image. */
    FILL(true),
    ;

    internal companion object {
        fun fromStoredName(value: String?): PortraitFeedAspect? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * The two operator-facing delivery families used by iOS framing guides.
 *
 * This is a local monitor preference only. It does not map to Nikon's
 * camera-owned `GridDisplay` property.
 */
public enum class LocalFramingGuideFamily(
    /** Operator-facing family name. */
    public val label: String,
) {
    /** Cinema and broadcast delivery ratios. */
    FILM("Film"),
    /** Vertical, square, and social delivery ratios. */
    SOCIAL("Social"),
    ;

    internal companion object {
        fun fromStoredName(value: String?): LocalFramingGuideFamily? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * A local delivery-frame ratio drawn over the Android monitor feed.
 *
 * The values and display order mirror iOS's `AssistConfiguration.Guides`.
 * Several ratios may be selected together; rendering owns only the local
 * composition overlay and never changes a Nikon camera property.
 */
public enum class LocalFramingAspectRatio(
    /** Operator-facing ratio label. */
    public val label: String,
    /** Width divided by height. */
    public val aspectRatio: Float,
) {
    /** 2.76:1 cinema delivery. */
    RATIO_276("2.76:1", 2.76f),
    /** 2.39:1 cinema delivery. */
    RATIO_239("2.39:1", 2.39f),
    /** 2.35:1 cinema delivery. */
    RATIO_235("2.35:1", 2.35f),
    /** 2.00:1 cinema delivery. */
    RATIO_200("2.00:1", 2f),
    /** 1.85:1 cinema delivery. */
    RATIO_185("1.85:1", 1.85f),
    /** 16:9 delivery, shared by Film and Social. */
    RATIO_16_9("16:9", 16f / 9f),
    /** 1.66:1 cinema delivery. */
    RATIO_166("1.66:1", 1.66f),
    /** 1.43:1 cinema delivery. */
    RATIO_143("1.43:1", 1.43f),
    /** 4:3 cinema delivery. */
    RATIO_4_3("4:3", 4f / 3f),
    /** 9:16 social delivery. */
    RATIO_9_16("9:16", 9f / 16f),
    /** 4:5 social delivery. */
    RATIO_4_5("4:5", 4f / 5f),
    /** 1:1 social delivery. */
    RATIO_1_1("1:1", 1f),
    /** 2:3 social delivery. */
    RATIO_2_3("2:3", 2f / 3f),
    /** 1.91:1 social delivery. */
    RATIO_191("1.91:1", 1.91f),
    ;

    public companion object {
        /** Ratios shown for [family], in the same order as the iOS control. */
        public fun forFamily(family: LocalFramingGuideFamily): List<LocalFramingAspectRatio> =
            when (family) {
                LocalFramingGuideFamily.FILM ->
                    listOf(
                        RATIO_276,
                        RATIO_239,
                        RATIO_235,
                        RATIO_200,
                        RATIO_185,
                        RATIO_16_9,
                        RATIO_166,
                        RATIO_143,
                        RATIO_4_3,
                    )
                LocalFramingGuideFamily.SOCIAL ->
                    listOf(RATIO_9_16, RATIO_4_5, RATIO_1_1, RATIO_2_3, RATIO_16_9, RATIO_191)
            }

        internal fun fromStoredName(value: String): LocalFramingAspectRatio? =
            entries.firstOrNull { it.name == value }
    }
}

/** A local de-squeeze factor that never changes captured media or camera state. */
public enum class LocalDesqueezeRatio(
    /** Operator-facing squeeze factor label. */
    public val label: String,
    /** Numeric squeeze factor. */
    public val factor: Float,
) {
    /** Preserve 1× geometry while retaining an explicit ratio selection. */
    X100("1x", 1f),
    /** 1.33× anamorphic factor. */
    X133("1.33x", 1.33f),
    /** 1.5× anamorphic factor. */
    X150("1.5x", 1.5f),
    /** 1.6× anamorphic factor. */
    X160("1.6x", 1.6f),
    /** 1.65× anamorphic factor. */
    X165("1.65x", 1.65f),
    /** 1.8× anamorphic factor. */
    X180("1.8x", 1.8f),
    /** 2× anamorphic factor. */
    X200("2x", 2f),
    ;

    internal companion object {
        fun fromStoredName(value: String?): LocalDesqueezeRatio? =
            entries.firstOrNull { it.name == value }

        fun matching(factor: Float): LocalDesqueezeRatio? =
            entries.firstOrNull { kotlin.math.abs(it.factor - factor) < 0.001f }

        fun snap(raw: Float): Float {
            val clamped = raw.coerceIn(1f, 2f)
            return ((clamped / 0.1f).roundToInt() * 0.1f).coerceIn(1f, 2f)
        }
    }
}

/** The source axis compressed by an anamorphic capture. */
public enum class LocalDesqueezeOrientation(
    /** Operator-facing source-axis label. */
    public val label: String,
) {
    /** Shrinks the presentation width, producing pillarboxing. */
    HORIZONTAL("Horizontal"),
    /** Shrinks the presentation height, producing letterboxing. */
    VERTICAL("Vertical"),
    ;

    internal companion object {
        fun fromStoredName(value: String?): LocalDesqueezeOrientation? =
            entries.firstOrNull { it.name == value }
    }
}

/** Presentation style for the local camera-level assist, matching iOS. */
public enum class LocalLevelStyle(
    /** Operator-facing style label. */
    public val label: String,
) {
    /** A horizon line that rolls with the camera. */
    HORIZON("Horizon"),
    /** A two-axis bubble gauge for roll and pitch. */
    GAUGE("Gauge"),
    ;

    internal companion object {
        fun fromStoredName(value: String?): LocalLevelStyle? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * Shared-core crush/clip tolerance for Traffic Lights edge detection.
 *
 * The raw values deliberately mirror `AssistConfiguration.CrushClipCompensation`
 * in Swift. Kotlin persists and forwards this selector only; the Swift core
 * remains responsible for deciding whether a channel is clipped or crushed.
 */
public enum class ScopeCrushClipCompensation(
    /** Swift enum raw value carried over the JNI scope seam. */
    public val wireValue: Int,
    /** Full operator-facing stop value for accessibility and settings copy. */
    public val label: String,
    /** Compact fraction glyph for the five-segment Android control. */
    public val compactLabel: String,
) {
    /** No edge-energy tolerance. */
    ZERO(0, "0", "0"),
    /** One quarter stop of edge-energy tolerance. */
    QUARTER(2, "0.25", "¼"),
    /** One half stop of edge-energy tolerance. */
    HALF(5, "0.5", "½"),
    /** Three quarters of a stop of edge-energy tolerance. */
    THREE_QUARTER(7, "0.75", "¾"),
    /** One full stop of edge-energy tolerance. */
    ONE(10, "1.0", "1"),
    ;

    internal companion object {
        /** Matches Swift's lenient persisted-value decoding for legacy/corrupt values. */
        fun fromWireValue(value: Int): ScopeCrushClipCompensation =
            entries.firstOrNull { it.wireValue == value }
                ?: if (value > ONE.wireValue) ONE else ZERO
    }
}

/** Plot channel arrangement for the waveform panel, matching iOS. */
public enum class ScopeWaveformMode(public val label: String) {
    LUMA("Luma"),
    RGB("RGB"),
}

/** Plot channel arrangement for the parade panel, matching iOS. */
public enum class ScopeParadeMode(public val label: String) {
    RGB("RGB"),
    YRGB("YRGB"),
}

/** Core-owned vectorscope density gain; Kotlin forwards only this stable ordinal. */
public enum class ScopeVectorscopeZoom(
    public val wireOrdinal: Int,
    public val label: String,
) {
    X1(0, "1x"),
    X2(1, "2x"),
    X4(2, "4x"),
}

/** Independently toggleable waveform/parade reference lines. */
@Immutable
public data class ScopeGuideLines(
    public val clip: Boolean = true,
    public val crush: Boolean = true,
    public val middle: Boolean = true,
)

/**
 * Persistable per-panel scope presentation controls. The Android Canvas only
 * exposes fields it actually honors; sampling and display-axis math remain in
 * the Swift core.
 */
@Immutable
public data class ScopeAssistConfiguration(
    public val waveformScale: Float = DEFAULT_SCALE,
    public val waveformMode: ScopeWaveformMode = ScopeWaveformMode.LUMA,
    public val waveformGuides: ScopeGuideLines = ScopeGuideLines(),
    public val waveformBrightness: Int = DEFAULT_BRIGHTNESS,
    public val paradeScale: Float = DEFAULT_SCALE,
    public val paradeMode: ScopeParadeMode = ScopeParadeMode.RGB,
    public val paradeGuides: ScopeGuideLines = ScopeGuideLines(),
    public val paradeBrightness: Int = DEFAULT_BRIGHTNESS,
    public val vectorscopeScale: Float = DEFAULT_SCALE,
    public val vectorscopeZoom: ScopeVectorscopeZoom = ScopeVectorscopeZoom.X1,
    public val vectorscopeBrightness: Int = DEFAULT_BRIGHTNESS,
    public val histogramScale: Float = DEFAULT_SCALE,
    public val trafficLightsScale: Float = DEFAULT_SCALE,
) {
    /** Clamps stale/corrupt preferences to the same iOS-supported ranges. */
    public fun normalized(): ScopeAssistConfiguration =
        copy(
            waveformScale = clampScale(waveformScale),
            waveformBrightness = clampBrightness(waveformBrightness),
            paradeScale = clampScale(paradeScale),
            paradeBrightness = clampBrightness(paradeBrightness),
            vectorscopeScale = clampScale(vectorscopeScale),
            vectorscopeBrightness = clampBrightness(vectorscopeBrightness),
            histogramScale = clampScale(histogramScale),
            trafficLightsScale = clampScale(trafficLightsScale),
        )

    public companion object {
        public const val MIN_SCALE: Float = 0.6f
        public const val MAX_SCALE: Float = 1.6f
        public const val DEFAULT_SCALE: Float = 1f
        public const val MIN_BRIGHTNESS: Int = 0
        public const val MAX_BRIGHTNESS: Int = 200
        public const val DEFAULT_BRIGHTNESS: Int = 100

        /**
         * Calibrated waveform/parade trace gain. `100%` preserves the former
         * `25%` appearance and `200%` reaches the former `50%`; vectorscope
         * continues to use its native-core unity-based brightness contract.
         */
        public fun waveformParadeBrightnessMultiplier(percent: Int): Float =
            clampBrightness(percent) / 400f

        /**
         * Decodes the versioned waveform/parade brightness without Int overflow.
         * Missing or invalidly typed values arrive as null and recover to the
         * calibrated default; pre-calibration values are expanded fourfold.
         */
        internal fun decodedWaveformParadeBrightness(
            storedValue: Int?,
            calibrationVersion: Int?,
        ): Int {
            if (storedValue == null) return DEFAULT_BRIGHTNESS
            if ((calibrationVersion ?: 0) >= WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION) {
                return clampBrightness(storedValue)
            }
            return (storedValue.toLong() * 4L)
                .coerceIn(MIN_BRIGHTNESS.toLong(), MAX_BRIGHTNESS.toLong())
                .toInt()
        }

        public fun clampScale(value: Float): Float =
            value.takeIf(Float::isFinite)?.coerceIn(MIN_SCALE, MAX_SCALE) ?: DEFAULT_SCALE

        public fun clampBrightness(value: Int): Int = value.coerceIn(MIN_BRIGHTNESS, MAX_BRIGHTNESS)

        internal const val WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION: Int = 2
    }
}

/**
 * The local monitor-only framing configuration consumed by the Compose feed
 * overlay. Camera framing-grid state is intentionally absent.
 */
public data class LocalFramingAssistConfiguration(
    /** Whether selected guide frames are drawn. */
    public val guidesVisible: Boolean,
    /** The guide family currently open in Operator Setup. */
    public val guideFamily: LocalFramingGuideFamily,
    /** Every local delivery ratio selected by the operator. */
    public val selectedGuideRatios: Set<LocalFramingAspectRatio>,
    /** Whether the inverse union of selected guide frames is dimmed. */
    public val guideMaskEnabled: Boolean,
    /** Whether the locally configured grid is drawn. */
    public val gridVisible: Boolean,
    /** Whether the local thirds grid is selected. */
    public val ruleOfThirdsEnabled: Boolean,
    /** Whether the local phi grid is selected. */
    public val phiGridEnabled: Boolean,
    /** Whether local diagonal guides are selected. */
    public val diagonalGridEnabled: Boolean,
    /** Whether the local centre crosshair is drawn. */
    public val centerCrosshairEnabled: Boolean,
    /** Whether the local camera-level overlay is visible. */
    public val levelEnabled: Boolean = false,
    /** Operator-selected presentation for the camera-level overlay. */
    public val levelStyle: LocalLevelStyle = LocalLevelStyle.HORIZON,
    /** Whether the local de-squeeze presentation is applied. */
    public val desqueezeEnabled: Boolean,
    /** Named chip when the factor matches a preset (UI highlight). */
    public val desqueezeRatio: LocalDesqueezeRatio,
    /** Applied squeeze factor in 1.0…2.0 (source of truth for rendering). */
    public val desqueezeFactor: Float = desqueezeRatio.factor,
    /** The source axis compressed by the anamorphic capture. */
    public val desqueezeOrientation: LocalDesqueezeOrientation,
) {
    /** Whether at least one selected guide is currently visible. */
    public val drawsGuides: Boolean
        get() = guidesVisible && selectedGuideRatios.isNotEmpty()

    /** Whether at least one configured grid pattern is currently visible. */
    public val drawsGrid: Boolean
        get() = gridVisible && (ruleOfThirdsEnabled || phiGridEnabled || diagonalGridEnabled)

    /** Local horizontal monitor scale after applying the selected de-squeeze. */
    public val horizontalPresentationScale: Float
        get() =
            if (desqueezeEnabled && desqueezeOrientation == LocalDesqueezeOrientation.HORIZONTAL) {
                1f / desqueezeFactor.coerceAtLeast(1f)
            } else {
                1f
            }

    /** Local vertical monitor scale after applying the selected de-squeeze. */
    public val verticalPresentationScale: Float
        get() =
            if (desqueezeEnabled && desqueezeOrientation == LocalDesqueezeOrientation.VERTICAL) {
                1f / desqueezeFactor.coerceAtLeast(1f)
            } else {
                1f
            }
}

/**
 * Persisted operator preferences — the Android counterpart of the iOS shell's
 * `OperatorPreferences` (UserDefaults-backed). Every value is Compose-observable
 * and writes through to app-private [SharedPreferences] on change.
 *
 * Camera-owned values (exposure, codec, resolution, and recording format)
 * deliberately do not belong here. The two Link choices are only an
 * app-local request: Swift resolves them into safe preview configuration when
 * an active session restarts, never a persisted camera setting.
 *
 * ponytail: plain SharedPreferences, not DataStore — this small synchronous
 * preference surface does not need coroutine plumbing or another dependency.
 */
@Stable
public class OperatorSettings(private val preferences: SharedPreferences) {

    public constructor(
        context: Context
    ) : this(context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE))

    /** One persisted switch: Compose-observable value, write-through on set. */
    public inner class Toggle internal constructor(
        public val key: String,
        public val default: Boolean,
    ) {
        private val state = mutableStateOf(preferences.getBoolean(key, default))

        public var value: Boolean
            get() = state.value
            set(new) {
                state.value = new
                preferences.edit().putBoolean(key, new).apply()
            }

        public fun toggle() {
            value = !value
        }
    }

    // Display chrome — maps to iOS `DisplayChromeVisibility`. Android keeps a
    // settings-only recovery control in the shared settings slot whenever the
    // landscape side rails are hidden, so this preference cannot strand the
    // operator outside Operator Setup.
    public val statusBarVisible: Toggle = Toggle("display.statusBar", default = true)
    public val sideRailsVisible: Toggle = Toggle("display.sideRails", default = true)
    public val assistToolbarVisible: Toggle = Toggle("display.assistToolbar", default = true)
    public val cameraValuesVisible: Toggle = Toggle("display.cameraValues", default = true)

    // Display — live-status readout visibility (iOS `displayChrome.*Visible`).
    public val recReadoutVisible: Toggle = Toggle("display.recReadout", default = true)
    public val codecReadoutVisible: Toggle = Toggle("display.codecReadout", default = true)
    public val mediaReadoutVisible: Toggle = Toggle("display.mediaReadout", default = true)
    public val fpsReadoutVisible: Toggle = Toggle("display.fpsReadout", default = true)

    // Controls — all four are app-local behavior and therefore safe to expose
    // before Android has camera-property writes.
    public val recordConfirmationEnabled: Toggle =
        Toggle("controls.recordConfirmation", default = true)
    /** Foreground hardware shutter, including volume keys while the live monitor is armed. */
    public val mediaRemoteShutterEnabled: Toggle =
        Toggle("controls.mediaRemoteShutter.v1", default = true)
    public val hapticsEnabled: Toggle = Toggle("controls.haptics", default = true)
    public val keepScreenAwake: Toggle = Toggle("controls.keepScreenAwake", default = true)

    // View Assist — local composited framing aids. These values deliberately
    // stay separate from the camera-owned GridDisplay property so a monitor
    // operator never accidentally changes the body while composing a shot.
    public val guidesVisible: Toggle =
        Toggle(GUIDES_VISIBLE_KEY, default = legacyGuideWasVisible())
    public val guideMaskEnabled: Toggle = Toggle(GUIDE_MASK_KEY, default = false)
    public val localGridVisible: Toggle =
        Toggle(GRID_VISIBLE_KEY, default = preferences.getBoolean(RULE_OF_THIRDS_KEY, false))
    public val ruleOfThirdsEnabled: Toggle = Toggle(RULE_OF_THIRDS_KEY, default = false)
    public val phiGridEnabled: Toggle = Toggle("assist.local.phiGrid.v1", default = false)
    public val diagonalGridEnabled: Toggle = Toggle("assist.local.diagonalGrid.v1", default = false)
    public val centerCrosshairEnabled: Toggle = Toggle("assist.local.centerCrosshair", default = false)
    /** Enables the local camera-level assist; it never writes a camera property. */
    public val levelAssistEnabled: Toggle = Toggle("assist.local.level", default = false)
    public val desqueezeEnabled: Toggle =
        Toggle(DESQUEEZE_ENABLED_KEY, default = legacyDesqueezeWasEnabled())
    /** Shows the shared Swift meter's RGB edge blocks on the histogram. */
    public val histogramTrafficLightsEnabled: Toggle =
        Toggle("assist.scopes.histogramTrafficLights.v1", default = true)

    private val guideFamilyState = mutableStateOf(loadGuideFamily())
    private val selectedGuideRatiosState = mutableStateOf(loadSelectedGuideRatios())
    private val desqueezeRatioState = mutableStateOf(loadDesqueezeRatio())
    private val desqueezeFactorState = mutableStateOf(loadDesqueezeFactor())
    private val desqueezeOrientationState = mutableStateOf(loadDesqueezeOrientation())
    private val levelStyleState = mutableStateOf(loadLevelStyle())
    private val scopeCrushClipCompensationState = mutableStateOf(loadScopeCrushClipCompensation())
    private val feedEffectsConfigurationState = mutableStateOf(loadFeedEffectsConfiguration())
    private val scopeAssistConfigurationState = mutableStateOf(loadScopeAssistConfiguration())
    private val streamPresetState = mutableStateOf(loadStreamPreset())
    private val qualityBiasState = mutableStateOf(loadQualityBias())
    private val portraitFeedAspectState = mutableStateOf(loadPortraitFeedAspect())
    private val displayModeOrderState = mutableStateOf(loadDisplayModeOrder())
    private val enabledDisplayModesState = mutableStateOf(loadEnabledDisplayModes())

    /** Current persisted DISP order, including disabled modes. */
    public val displayModeOrder: List<MonitorDisplayMode>
        get() = displayModeOrderState.value

    /** Modes currently included in the DISP cycle. At least one is always enabled. */
    public val enabledDisplayModes: Set<MonitorDisplayMode>
        get() = enabledDisplayModesState.value

    /** Enabled modes in the operator's persisted order. */
    public val enabledDisplayModeOrder: List<MonitorDisplayMode>
        get() = displayModeOrder.filter(enabledDisplayModes::contains)

    /**
     * Returns the next enabled mode after [current], wrapping at the end.
     * A stale/disabled current mode recovers to the first enabled mode.
     */
    public fun nextDisplayMode(current: MonitorDisplayMode): MonitorDisplayMode {
        val order = enabledDisplayModeOrder
        val currentIndex = order.indexOf(current)
        return if (currentIndex < 0) order.first() else order[(currentIndex + 1) % order.size]
    }

    /** Recovers [current] when settings disabled it while the monitor stayed mounted. */
    public fun reconciledDisplayMode(current: MonitorDisplayMode): MonitorDisplayMode =
        current.takeIf(enabledDisplayModes::contains) ?: enabledDisplayModeOrder.first()

    /**
     * Resolves an explicit gesture/navigation request without bypassing operator enablement.
     * Callers leave their current mode unchanged when this returns null.
     */
    public fun displayModeForExplicitRequest(
        requested: MonitorDisplayMode,
    ): MonitorDisplayMode? = requested.takeIf(enabledDisplayModes::contains)

    /**
     * Toggles one mode's participation in DISP cycling.
     *
     * Returns false without changing persistence when [mode] is the last
     * enabled safe mode.
     */
    public fun toggleDisplayMode(mode: MonitorDisplayMode): Boolean {
        val current = enabledDisplayModesState.value
        if (mode in current && current.size == 1) return false
        val next = current.toMutableSet()
        if (!next.add(mode)) next.remove(mode)
        enabledDisplayModesState.value = next
        persistEnabledDisplayModes(next)
        return true
    }

    /** Moves [mode] directly to [targetIndex] and persists the reconciled order. */
    public fun moveDisplayMode(mode: MonitorDisplayMode, targetIndex: Int) {
        val current = displayModeOrderState.value
        val sourceIndex = current.indexOf(mode)
        if (sourceIndex < 0) return
        val next = current.toMutableList()
        next.removeAt(sourceIndex)
        next.add(targetIndex.coerceIn(0, next.size), mode)
        if (next == current) return
        displayModeOrderState.value = next
        persistDisplayModeOrder(next)
    }

    /** Restores the iOS DISP order and enables all supported modes. */
    public fun resetDisplayModePreferences() {
        val order = MonitorDisplayMode.entries.toList()
        val enabled = order.toSet()
        displayModeOrderState.value = order
        enabledDisplayModesState.value = enabled
        persistDisplayModeOrder(order)
        persistEnabledDisplayModes(enabled)
    }

    /** Requested preview-size profile, resolved by Swift before live view starts. */
    public var streamPreset: LiveViewStreamPreset
        get() = streamPresetState.value
        set(new) {
            streamPresetState.value = new
            preferences.edit().putString(STREAM_PRESET_KEY, new.name).apply()
        }

    /** Requested preview-compression profile, resolved by Swift rather than Kotlin. */
    public var qualityBias: LiveViewQualityBias
        get() = qualityBiasState.value
        set(new) {
            qualityBiasState.value = new
            preferences.edit().putString(QUALITY_BIAS_KEY, new.name).apply()
        }

    /**
     * Portrait feed fit/fill choice, persisted across monitor sessions.
     *
     * Compose forwards [PortraitFeedAspect.fillsViewport] to the shared Swift
     * zone map and uses the same value for image and overlay crop resolution.
     */
    public var portraitFeedAspect: PortraitFeedAspect
        get() = portraitFeedAspectState.value
        set(new) {
            portraitFeedAspectState.value = new
            preferences.edit().putString(PORTRAIT_FEED_ASPECT_KEY, new.name).apply()
        }

    /** The family currently shown in Operator Setup; guide selection spans both families. */
    public var guideFamily: LocalFramingGuideFamily
        get() = guideFamilyState.value
        set(new) {
            guideFamilyState.value = new
            preferences.edit().putString(GUIDE_FAMILY_KEY, new.name).apply()
        }

    /** Every selected delivery ratio, persisted as a set of stable enum names. */
    public val selectedGuideRatios: Set<LocalFramingAspectRatio>
        get() = selectedGuideRatiosState.value

    /** Toggles one delivery ratio and keeps the guide tool's visibility truthful. */
    public fun toggleGuideRatio(ratio: LocalFramingAspectRatio) {
        val next = toggleGuideRatioConfiguration(ratio)
        guidesVisible.value = next.isNotEmpty()
    }

    /**
     * Toggles only the shared guide configuration, leaving live/playback visibility to its caller.
     * Playback uses this seam so changing a ratio cannot silently turn on the live-view overlay.
     */
    public fun toggleGuideRatioConfiguration(
        ratio: LocalFramingAspectRatio,
    ): Set<LocalFramingAspectRatio> {
        val next = selectedGuideRatiosState.value.toMutableSet()
        if (!next.add(ratio)) next.remove(ratio)
        setSelectedGuideRatios(next)
        return selectedGuideRatiosState.value
    }

    /** Named de-squeeze chip; selecting a chip also snaps [desqueezeFactor]. */
    public var desqueezeRatio: LocalDesqueezeRatio
        get() = desqueezeRatioState.value
        set(new) {
            desqueezeRatioState.value = new
            desqueezeFactorState.value = new.factor
            preferences
                .edit()
                .putString(DESQUEEZE_RATIO_KEY, new.name)
                .putFloat(DESQUEEZE_FACTOR_KEY, new.factor)
                .apply()
        }

    /** Applied de-squeeze factor (1.0…2.0, 0.1 steps); source of truth for presentation scale. */
    public var desqueezeFactor: Float
        get() = desqueezeFactorState.value
        set(new) {
            val snapped = LocalDesqueezeRatio.snap(new)
            desqueezeFactorState.value = snapped
            LocalDesqueezeRatio.matching(snapped)?.let { desqueezeRatioState.value = it }
            preferences
                .edit()
                .putFloat(DESQUEEZE_FACTOR_KEY, snapped)
                .putString(DESQUEEZE_RATIO_KEY, desqueezeRatioState.value.name)
                .apply()
        }

    /** Selected camera-level presentation; persisted immediately on change. */
    public var levelStyle: LocalLevelStyle
        get() = levelStyleState.value
        set(new) {
            levelStyleState.value = new
            preferences.edit().putString(LEVEL_STYLE_KEY, new.name).apply()
        }

    /** The source axis compressed by the selected local anamorphic factor. */
    public var desqueezeOrientation: LocalDesqueezeOrientation
        get() = desqueezeOrientationState.value
        set(new) {
            desqueezeOrientationState.value = new
            preferences.edit().putString(DESQUEEZE_ORIENTATION_KEY, new.name).apply()
        }

    /**
     * Toggles an Android-owned framing tool from the monitor toolbar.
     *
     * No branch sends a Nikon command: these are only local compositing and
     * presentation settings. A newly enabled guide/grid seeds the same iOS
     * defaults that make the tool visibly useful on first tap.
     */
    public fun toggleLocalFramingTool(tool: AssistTool) {
        when (tool) {
            AssistTool.GUIDES -> {
                if (guidesVisible.value) {
                    guidesVisible.value = false
                } else {
                    if (selectedGuideRatiosState.value.isEmpty()) {
                        setSelectedGuideRatios(setOf(LocalFramingAspectRatio.RATIO_239))
                    }
                    guidesVisible.value = true
                }
            }
            AssistTool.GRID -> {
                if (!localGridVisible.value &&
                    !ruleOfThirdsEnabled.value &&
                    !phiGridEnabled.value &&
                    !diagonalGridEnabled.value
                ) {
                    ruleOfThirdsEnabled.value = true
                }
                localGridVisible.toggle()
            }
            AssistTool.CROSS -> centerCrosshairEnabled.toggle()
            AssistTool.LEVEL -> levelAssistEnabled.toggle()
            AssistTool.DESQ -> desqueezeEnabled.toggle()
            else -> Unit
        }
    }

    /** Whether [tool] is currently visible in the live monitor's local framing layer. */
    public fun isLocalFramingToolVisible(tool: AssistTool): Boolean =
        when (tool) {
            AssistTool.GUIDES -> guidesVisible.value
            AssistTool.GRID -> localGridVisible.value
            AssistTool.CROSS -> centerCrosshairEnabled.value
            AssistTool.LEVEL -> levelAssistEnabled.value
            AssistTool.DESQ -> desqueezeEnabled.value
            else -> false
        }

    /**
     * Sets one live-monitor framing tool without sending a camera command.
     * Newly shown guides and grids retain the same useful first-use defaults as
     * [toggleLocalFramingTool].
     */
    public fun setLocalFramingToolVisible(tool: AssistTool, visible: Boolean) {
        if (tool !in AssistTool.framingTools || isLocalFramingToolVisible(tool) == visible) return
        toggleLocalFramingTool(tool)
    }

    /**
     * Traffic Lights crush/clip tolerance, persisted as the shared Swift
     * enum's stable raw value. It changes the Swift meter on the next scope
     * tick without moving any measurement math into Kotlin.
     */
    public var scopeCrushClipCompensation: ScopeCrushClipCompensation
        get() = scopeCrushClipCompensationState.value
        set(new) {
            scopeCrushClipCompensationState.value = new
            preferences.edit().putInt(SCOPE_METER_PREFERENCE, new.wireValue).apply()
        }

    /**
     * Local image-assist choices only. Camera codec, ISO, and curve selection
     * stay on the session and are forwarded separately into the Swift facade.
     */
    public var feedEffectsConfiguration: FeedEffectsConfiguration
        get() = feedEffectsConfigurationState.value
        set(new) {
            val normalized = new.normalized()
            feedEffectsConfigurationState.value = normalized
            persistFeedEffectsConfiguration(normalized)
        }

    /** Per-scope presentation controls; clean-frame sampling remains unchanged. */
    public var scopeAssistConfiguration: ScopeAssistConfiguration
        get() = scopeAssistConfigurationState.value
        set(new) {
            val normalized = new.normalized()
            scopeAssistConfigurationState.value = normalized
            persistScopeAssistConfiguration(normalized)
        }

    /** Restores only the iOS False Color card's local configuration. */
    public fun resetFalseColorConfiguration() {
        val defaults = FeedEffectsConfiguration()
        feedEffectsConfiguration =
            feedEffectsConfiguration.copy(
                falseColorReferenceEnabled = defaults.falseColorReferenceEnabled,
            )
    }

    /** Restores only the iOS Peaking card's detector and color choices. */
    public fun resetPeakingConfiguration() {
        val defaults = FeedEffectsConfiguration()
        feedEffectsConfiguration =
            feedEffectsConfiguration.copy(
                peakingSensitivity = defaults.peakingSensitivity,
                peakingColor = defaults.peakingColor,
            )
    }

    /** Restores every field in the iOS Zebra card. */
    public fun resetZebraConfiguration() {
        val defaults = FeedEffectsConfiguration()
        feedEffectsConfiguration =
            feedEffectsConfiguration.copy(
                zebraUnit = defaults.zebraUnit,
                zebraHighlightEnabled = defaults.zebraHighlightEnabled,
                zebraHighlightIre = defaults.zebraHighlightIre,
                zebraHighlightColor = defaults.zebraHighlightColor,
                zebraMidtoneEnabled = defaults.zebraMidtoneEnabled,
                zebraMidtoneIre = defaults.zebraMidtoneIre,
                zebraMidtoneColor = defaults.zebraMidtoneColor,
            )
    }

    /** Restores Waveform mode, guides, and brightness without moving its panel. */
    public fun resetWaveformConfiguration() {
        val defaults = ScopeAssistConfiguration()
        scopeAssistConfiguration =
            scopeAssistConfiguration.copy(
                waveformMode = defaults.waveformMode,
                waveformGuides = defaults.waveformGuides,
                waveformBrightness = defaults.waveformBrightness,
            )
    }

    /** Restores Parade mode, guides, and brightness without moving its panel. */
    public fun resetParadeConfiguration() {
        val defaults = ScopeAssistConfiguration()
        scopeAssistConfiguration =
            scopeAssistConfiguration.copy(
                paradeMode = defaults.paradeMode,
                paradeGuides = defaults.paradeGuides,
                paradeBrightness = defaults.paradeBrightness,
            )
    }

    /** Restores Histogram edge blocks and crush/clip compensation, preserving panel placement. */
    public fun resetHistogramConfiguration() {
        histogramTrafficLightsEnabled.value = true
        scopeCrushClipCompensation = ScopeCrushClipCompensation.QUARTER
    }

    /** Restores Vectorscope zoom and brightness without moving its panel. */
    public fun resetVectorscopeConfiguration() {
        val defaults = ScopeAssistConfiguration()
        scopeAssistConfiguration =
            scopeAssistConfiguration.copy(
                vectorscopeZoom = defaults.vectorscopeZoom,
                vectorscopeBrightness = defaults.vectorscopeBrightness,
            )
    }

    /** Restores the Traffic Lights footprint and shared crush/clip compensation. */
    public fun resetTrafficLightsConfiguration() {
        val defaults = ScopeAssistConfiguration()
        scopeAssistConfiguration =
            scopeAssistConfiguration.copy(trafficLightsScale = defaults.trafficLightsScale)
        scopeCrushClipCompensation = ScopeCrushClipCompensation.QUARTER
    }

    /** Compose-observable framing state for the monitor overlay. */
    public val localFramingAssistConfiguration: LocalFramingAssistConfiguration
        get() =
            LocalFramingAssistConfiguration(
                guidesVisible = guidesVisible.value,
                guideFamily = guideFamily,
                selectedGuideRatios = selectedGuideRatios,
                guideMaskEnabled = guideMaskEnabled.value,
                gridVisible = localGridVisible.value,
                ruleOfThirdsEnabled = ruleOfThirdsEnabled.value,
                phiGridEnabled = phiGridEnabled.value,
                diagonalGridEnabled = diagonalGridEnabled.value,
                centerCrosshairEnabled = centerCrosshairEnabled.value,
                levelEnabled = levelAssistEnabled.value,
                levelStyle = levelStyle,
                desqueezeEnabled = desqueezeEnabled.value,
                desqueezeRatio = desqueezeRatio,
                desqueezeFactor = desqueezeFactor,
                desqueezeOrientation = desqueezeOrientation,
            )

    private val assistToolbarOrderState = mutableStateOf(loadAssistToolbarOrder())
    private val visibleAssistToolsState = mutableStateOf(loadVisibleAssistTools())

    /** Current persisted order for the Android-supported assist toolbar tools. */
    public val assistToolbarOrder: List<AssistTool>
        get() = assistToolbarOrderState.value

    /** Whether [tool] is currently exposed on the monitor's assist toolbar. */
    public fun isAssistToolbarToolVisible(tool: AssistTool): Boolean =
        tool == AssistTool.LUT || tool in visibleAssistToolsState.value

    /** Ordered set of tools the monitor should render in its assist toolbar. */
    public val visibleAssistToolbarTools: List<AssistTool>
        get() {
            // iOS keeps the tap-only audio meter in its own trailing toolbar
            // section, independent of the regular tool grouping/order.
            val regular =
                assistToolbarOrder.filter {
                    it != AssistTool.AUDIO && isAssistToolbarToolVisible(it)
                }
            return regular + listOfNotNull(AssistTool.AUDIO.takeIf(::isAssistToolbarToolVisible))
        }

    /**
     * Toggles the toolbar visibility of [tool]. LUT is deliberately always
     * present, matching the iOS shell: it gives the operator a reliable path
     * back to an image look even if every other assist is hidden.
     */
    public fun toggleAssistToolbarToolVisibility(tool: AssistTool) {
        if (tool == AssistTool.LUT) return
        val next = visibleAssistToolsState.value.toMutableSet()
        if (!next.add(tool)) next.remove(tool)
        visibleAssistToolsState.value = next
        preferences.edit()
            .putStringSet(VISIBLE_ASSIST_TOOLS_KEY, next.mapTo(linkedSetOf()) { it.name })
            .putBoolean(TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY, true)
            .putBoolean(AUDIO_METERS_VISIBILITY_MIGRATED_KEY, true)
            .putBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, true)
            .putBoolean(LEVEL_VISIBILITY_MIGRATED_KEY, true)
            .apply()
    }

    /** Moves [tool] directly to [targetIndex] and persists the normalized order. */
    public fun moveAssistToolbarTool(tool: AssistTool, targetIndex: Int) {
        val current = assistToolbarOrderState.value
        val index = current.indexOf(tool)
        if (index < 0) return

        val next = current.toMutableList()
        next.removeAt(index)
        next.add(targetIndex.coerceIn(0, next.size), tool)
        if (next == current) return
        assistToolbarOrderState.value = next
        preferences.edit()
            .putString(ASSIST_TOOLBAR_ORDER_KEY, next.joinToString(separator = ",") { it.name })
            .apply()
    }

    /** Restores the Android-supported assist toolbar's order and visibility. */
    public fun resetAssistToolbarPreferences() {
        val defaultOrder = AssistTool.entries.toList()
        assistToolbarOrderState.value = defaultOrder
        visibleAssistToolsState.value = defaultOrder.toSet()
        preferences.edit()
            .putString(ASSIST_TOOLBAR_ORDER_KEY, defaultOrder.joinToString(separator = ",") { it.name })
            .putStringSet(VISIBLE_ASSIST_TOOLS_KEY, defaultOrder.mapTo(linkedSetOf()) { it.name })
            .putBoolean(TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY, true)
            .putBoolean(AUDIO_METERS_VISIBILITY_MIGRATED_KEY, true)
            .putBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, true)
            .putBoolean(LEVEL_VISIBILITY_MIGRATED_KEY, true)
            .apply()
    }

    /** The monitor keeps the screen awake only while this operator policy permits it. */
    public fun shouldKeepScreenAwake(monitorPresented: Boolean): Boolean =
        monitorPresented && keepScreenAwake.value

    /** Every persisted switch, for reset-to-defaults and key-collision checks. */
    public val all: List<Toggle> =
        listOf(
            statusBarVisible,
            sideRailsVisible,
            assistToolbarVisible,
            cameraValuesVisible,
            recReadoutVisible,
            codecReadoutVisible,
            mediaReadoutVisible,
            fpsReadoutVisible,
            recordConfirmationEnabled,
            mediaRemoteShutterEnabled,
            hapticsEnabled,
            keepScreenAwake,
            guidesVisible,
            guideMaskEnabled,
            localGridVisible,
            ruleOfThirdsEnabled,
            phiGridEnabled,
            diagonalGridEnabled,
            centerCrosshairEnabled,
            levelAssistEnabled,
            desqueezeEnabled,
        )

    private fun loadDisplayModeOrder(): List<MonitorDisplayMode> {
        val raw = preferences.getString(DISPLAY_MODE_ORDER_KEY, null)
        val stored =
            raw?.split(',')
                ?.mapNotNull(MonitorDisplayMode::fromStoredName)
                .orEmpty()
        val deduplicated = stored.distinct()
        val reconciled = deduplicated + MonitorDisplayMode.entries.filterNot(deduplicated::contains)
        if (raw != null && raw != encodedDisplayModeOrder(reconciled)) {
            persistDisplayModeOrder(reconciled)
        }
        return reconciled
    }

    private fun loadEnabledDisplayModes(): Set<MonitorDisplayMode> {
        if (!preferences.contains(ENABLED_DISPLAY_MODES_KEY)) return MonitorDisplayMode.entries.toSet()
        val raw = preferences.getStringSet(ENABLED_DISPLAY_MODES_KEY, emptySet()).orEmpty()
        val decoded = raw.mapNotNull(MonitorDisplayMode::fromStoredName).toSet()
        val reconciled = decoded.ifEmpty { MonitorDisplayMode.entries.toSet() }
        val canonical = reconciled.mapTo(linkedSetOf()) { it.name }
        if (raw != canonical) persistEnabledDisplayModes(reconciled)
        return reconciled
    }

    private fun persistDisplayModeOrder(order: List<MonitorDisplayMode>) {
        preferences.edit().putString(DISPLAY_MODE_ORDER_KEY, encodedDisplayModeOrder(order)).apply()
    }

    private fun encodedDisplayModeOrder(order: List<MonitorDisplayMode>): String =
        order.joinToString(separator = ",") { it.name }

    private fun persistEnabledDisplayModes(modes: Set<MonitorDisplayMode>) {
        preferences.edit()
            .putStringSet(ENABLED_DISPLAY_MODES_KEY, modes.mapTo(linkedSetOf()) { it.name })
            .apply()
    }

    private fun loadAssistToolbarOrder(): List<AssistTool> {
        val raw = preferences.getString(ASSIST_TOOLBAR_ORDER_KEY, null)
        val stored =
            raw?.split(',')
                ?.mapNotNull(AssistTool::fromStoredName)
                .orEmpty()
        val deduplicated = stored.distinct()
        val reconciled = deduplicated + AssistTool.entries.filterNot(deduplicated::contains)
        val encoded = reconciled.joinToString(separator = ",") { it.name }
        if (raw != null && raw != encoded) {
            preferences.edit().putString(ASSIST_TOOLBAR_ORDER_KEY, encoded).apply()
        }
        return reconciled
    }

    private fun loadVisibleAssistTools(): Set<AssistTool> {
        if (!preferences.contains(VISIBLE_ASSIST_TOOLS_KEY)) return AssistTool.entries.toSet()
        val stored =
            preferences.getStringSet(VISIBLE_ASSIST_TOOLS_KEY, emptySet())
            ?.mapNotNull(AssistTool::fromStoredName)
            ?.toSet()
            .orEmpty()
        var migrated = stored
        val editor = preferences.edit()
        var changed = false
        if (!preferences.getBoolean(TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY, false)) {
            // This key predates `AssistTool.LIGHTS`. Add it once for existing
            // custom toolbar configurations, then mark the set so a later
            // manual hide remains a durable operator choice.
            migrated += AssistTool.LIGHTS
            editor.putBoolean(TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY, true)
            changed = true
        }
        if (!preferences.getBoolean(AUDIO_METERS_VISIBILITY_MIGRATED_KEY, false)) {
            // Audio meters land as a new tap-only tool. Existing custom
            // layouts see it once; after that a deliberate hide stays hidden.
            migrated += AssistTool.AUDIO
            editor.putBoolean(AUDIO_METERS_VISIBILITY_MIGRATED_KEY, true)
            changed = true
        }
        if (!preferences.getBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, false)) {
            // Framing tools are a complete local assist group. Add them once
            // for existing custom toolbar configurations, then preserve every
            // later operator hide/show decision.
            migrated += AssistTool.framingTools
            editor.putBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, true)
            changed = true
        }
        if (!preferences.getBoolean(LEVEL_VISIBILITY_MIGRATED_KEY, false)) {
            // LEVEL joined the existing framing group after its original
            // migration marker shipped. Add it exactly once so an existing
            // custom toolbar sees the new control, then retain manual hides.
            migrated += AssistTool.LEVEL
            editor.putBoolean(LEVEL_VISIBILITY_MIGRATED_KEY, true)
            changed = true
        }
        if (changed) {
            editor.putStringSet(VISIBLE_ASSIST_TOOLS_KEY, migrated.mapTo(linkedSetOf()) { it.name }).apply()
        }
        return migrated
    }

    private fun legacyGuideWasVisible(): Boolean = legacyGuideRatio() != null

    private fun legacyDesqueezeWasEnabled(): Boolean =
        legacyDesqueezeRatio() != LocalDesqueezeRatio.X100

    private fun loadGuideFamily(): LocalFramingGuideFamily =
        LocalFramingGuideFamily.fromStoredName(preferences.getString(GUIDE_FAMILY_KEY, null))
            ?: LocalFramingGuideFamily.FILM

    private fun loadSelectedGuideRatios(): Set<LocalFramingAspectRatio> {
        if (preferences.contains(GUIDE_RATIOS_KEY)) {
            return preferences.getStringSet(GUIDE_RATIOS_KEY, emptySet())
                ?.mapNotNull(LocalFramingAspectRatio::fromStoredName)
                ?.toSet()
                .orEmpty()
        }
        return legacyGuideRatio()?.let(::setOf).orEmpty()
    }

    private fun setSelectedGuideRatios(next: Set<LocalFramingAspectRatio>) {
        val canonical = LocalFramingAspectRatio.entries.filter(next::contains).toSet()
        selectedGuideRatiosState.value = canonical
        preferences.edit()
            .putStringSet(GUIDE_RATIOS_KEY, canonical.mapTo(linkedSetOf()) { it.name })
            .apply()
    }

    private fun legacyGuideRatio(): LocalFramingAspectRatio? =
        when (preferences.getString(LEGACY_FRAMING_GUIDE_KEY, null)) {
            "CINEMA_239" -> LocalFramingAspectRatio.RATIO_239
            "WIDESCREEN_16_9" -> LocalFramingAspectRatio.RATIO_16_9
            else -> null
        }

    private fun loadDesqueezeRatio(): LocalDesqueezeRatio =
        LocalDesqueezeRatio.fromStoredName(preferences.getString(DESQUEEZE_RATIO_KEY, null))
            ?: legacyDesqueezeRatio()

    private fun loadDesqueezeFactor(): Float {
        if (preferences.contains(DESQUEEZE_FACTOR_KEY)) {
            return LocalDesqueezeRatio.snap(preferences.getFloat(DESQUEEZE_FACTOR_KEY, 1f))
        }
        return loadDesqueezeRatio().factor
    }

    private fun legacyDesqueezeRatio(): LocalDesqueezeRatio =
        when (preferences.getString(LEGACY_DESQUEEZE_PRESENTATION_KEY, null)) {
            "X133" -> LocalDesqueezeRatio.X133
            "X150" -> LocalDesqueezeRatio.X150
            "X160" -> LocalDesqueezeRatio.X160
            "X165" -> LocalDesqueezeRatio.X165
            "X180" -> LocalDesqueezeRatio.X180
            "X200" -> LocalDesqueezeRatio.X200
            else -> LocalDesqueezeRatio.X100
        }

    private fun loadDesqueezeOrientation(): LocalDesqueezeOrientation =
        LocalDesqueezeOrientation.fromStoredName(
            preferences.getString(DESQUEEZE_ORIENTATION_KEY, null),
        ) ?: LocalDesqueezeOrientation.HORIZONTAL

    private fun loadLevelStyle(): LocalLevelStyle =
        LocalLevelStyle.fromStoredName(preferences.getString(LEVEL_STYLE_KEY, null))
            ?: LocalLevelStyle.HORIZON

    private fun loadScopeCrushClipCompensation(): ScopeCrushClipCompensation {
        val default = ScopeCrushClipCompensation.QUARTER.wireValue
        val legacyPreference = legacyScopeMeterPreference()
        val raw =
            when {
                preferences.contains(SCOPE_METER_PREFERENCE) ->
                    preferences.getInt(SCOPE_METER_PREFERENCE, default)
                preferences.contains(legacyPreference) -> {
                    val legacy = preferences.getInt(legacyPreference, default)
                    preferences.edit()
                        .putInt(SCOPE_METER_PREFERENCE, legacy)
                        .remove(legacyPreference)
                        .apply()
                    legacy
                }
                else -> default
            }
        return ScopeCrushClipCompensation.fromWireValue(raw)
    }

    /** Absent keys deliberately use iOS's first-use image-assist defaults. */
    private fun loadFeedEffectsConfiguration(): FeedEffectsConfiguration =
        FeedEffectsConfiguration(
            falseColorReferenceEnabled = preferences.getBoolean(FALSE_COLOR_REFERENCE_KEY, true),
            peakingSensitivity =
                preferences.getString(PEAKING_SENSITIVITY_KEY, null)
                    ?.let { stored -> FeedPeakingSensitivity.entries.firstOrNull { it.name == stored } }
                    ?: FeedPeakingSensitivity.MEDIUM,
            peakingColor =
                preferences.getString(PEAKING_COLOR_KEY, null)
                    ?.let { stored -> FeedPeakingColor.entries.firstOrNull { it.name == stored } }
                    ?: FeedPeakingColor.RED,
            zebraUnit =
                preferences.getString(ZEBRA_UNIT_KEY, null)
                    ?.let { stored -> FeedZebraUnit.entries.firstOrNull { it.name == stored } }
                    ?: FeedZebraUnit.IRE,
            zebraHighlightEnabled = preferences.getBoolean(ZEBRA_HIGHLIGHT_ENABLED_KEY, true),
            zebraHighlightIre = preferences.getFloat(ZEBRA_HIGHLIGHT_IRE_KEY, 100f),
            zebraHighlightColor =
                preferences.getString(ZEBRA_HIGHLIGHT_COLOR_KEY, null)
                    ?.let { stored -> FeedZebraStripeColor.entries.firstOrNull { it.name == stored } }
                    ?: FeedZebraStripeColor.WHITE,
            zebraMidtoneEnabled = preferences.getBoolean(ZEBRA_MIDTONE_ENABLED_KEY, true),
            zebraMidtoneIre = preferences.getFloat(ZEBRA_MIDTONE_IRE_KEY, 55f),
            zebraMidtoneColor =
                preferences.getString(ZEBRA_MIDTONE_COLOR_KEY, null)
                    ?.let { stored -> FeedZebraStripeColor.entries.firstOrNull { it.name == stored } }
                    ?: FeedZebraStripeColor.AMBER,
        ).normalized()

    private fun persistFeedEffectsConfiguration(configuration: FeedEffectsConfiguration) {
        preferences.edit()
            .putBoolean(FALSE_COLOR_REFERENCE_KEY, configuration.falseColorReferenceEnabled)
            .putString(PEAKING_SENSITIVITY_KEY, configuration.peakingSensitivity.name)
            .putString(PEAKING_COLOR_KEY, configuration.peakingColor.name)
            .putString(ZEBRA_UNIT_KEY, configuration.zebraUnit.name)
            .putBoolean(ZEBRA_HIGHLIGHT_ENABLED_KEY, configuration.zebraHighlightEnabled)
            .putFloat(ZEBRA_HIGHLIGHT_IRE_KEY, configuration.zebraHighlightIre)
            .putString(ZEBRA_HIGHLIGHT_COLOR_KEY, configuration.zebraHighlightColor.name)
            .putBoolean(ZEBRA_MIDTONE_ENABLED_KEY, configuration.zebraMidtoneEnabled)
            .putFloat(ZEBRA_MIDTONE_IRE_KEY, configuration.zebraMidtoneIre)
            .putString(ZEBRA_MIDTONE_COLOR_KEY, configuration.zebraMidtoneColor.name)
            .apply()
    }

    private fun loadScopeAssistConfiguration(): ScopeAssistConfiguration {
        fun waveformMode(): ScopeWaveformMode =
            preferences.getString(SCOPE_WAVEFORM_MODE_KEY, null)
                ?.let { stored -> ScopeWaveformMode.entries.firstOrNull { it.name == stored } }
                ?: ScopeWaveformMode.LUMA
        fun paradeMode(): ScopeParadeMode =
            preferences.getString(SCOPE_PARADE_MODE_KEY, null)
                ?.let { stored -> ScopeParadeMode.entries.firstOrNull { it.name == stored } }
                ?: ScopeParadeMode.RGB
        fun vectorZoom(): ScopeVectorscopeZoom =
            preferences.getString(SCOPE_VECTOR_ZOOM_KEY, null)
                ?.let { stored -> ScopeVectorscopeZoom.entries.firstOrNull { it.name == stored } }
                ?: ScopeVectorscopeZoom.X1
        fun guides(prefix: String): ScopeGuideLines =
            ScopeGuideLines(
                clip = preferences.getBoolean("$prefix.clip", true),
                crush = preferences.getBoolean("$prefix.crush", true),
                middle = preferences.getBoolean("$prefix.middle", true),
            )
        val calibrationVersion = storedInt(SCOPE_WAVEFORM_PARADE_BRIGHTNESS_VERSION_KEY)
        val storedWaveformBrightness = storedInt(SCOPE_WAVEFORM_BRIGHTNESS_KEY)
        val storedParadeBrightness = storedInt(SCOPE_PARADE_BRIGHTNESS_KEY)
        val waveformBrightness =
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(
                storedWaveformBrightness,
                calibrationVersion,
            )
        val paradeBrightness =
            ScopeAssistConfiguration.decodedWaveformParadeBrightness(
                storedParadeBrightness,
                calibrationVersion,
            )
        if (calibrationVersion == null ||
            calibrationVersion < ScopeAssistConfiguration.WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION ||
            storedWaveformBrightness != waveformBrightness ||
            storedParadeBrightness != paradeBrightness
        ) {
            preferences.edit()
                .putInt(SCOPE_WAVEFORM_BRIGHTNESS_KEY, waveformBrightness)
                .putInt(SCOPE_PARADE_BRIGHTNESS_KEY, paradeBrightness)
                .putInt(
                    SCOPE_WAVEFORM_PARADE_BRIGHTNESS_VERSION_KEY,
                    ScopeAssistConfiguration.WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION,
                )
                .apply()
        }
        return ScopeAssistConfiguration(
            waveformScale = preferences.getFloat(SCOPE_WAVEFORM_SCALE_KEY, ScopeAssistConfiguration.DEFAULT_SCALE),
            waveformMode = waveformMode(),
            waveformGuides = guides(SCOPE_WAVEFORM_GUIDES_PREFIX),
            waveformBrightness = waveformBrightness,
            paradeScale = preferences.getFloat(SCOPE_PARADE_SCALE_KEY, ScopeAssistConfiguration.DEFAULT_SCALE),
            paradeMode = paradeMode(),
            paradeGuides = guides(SCOPE_PARADE_GUIDES_PREFIX),
            paradeBrightness = paradeBrightness,
            vectorscopeScale = preferences.getFloat(SCOPE_VECTOR_SCALE_KEY, ScopeAssistConfiguration.DEFAULT_SCALE),
            vectorscopeZoom = vectorZoom(),
            vectorscopeBrightness =
                preferences.getInt(SCOPE_VECTOR_BRIGHTNESS_KEY, ScopeAssistConfiguration.DEFAULT_BRIGHTNESS),
            histogramScale = preferences.getFloat(SCOPE_HISTOGRAM_SCALE_KEY, ScopeAssistConfiguration.DEFAULT_SCALE),
            trafficLightsScale =
                preferences.getFloat(SCOPE_TRAFFIC_LIGHTS_SCALE_KEY, ScopeAssistConfiguration.DEFAULT_SCALE),
        ).normalized()
    }

    private fun persistScopeAssistConfiguration(configuration: ScopeAssistConfiguration) {
        fun SharedPreferences.Editor.putGuides(prefix: String, guides: ScopeGuideLines): SharedPreferences.Editor =
            putBoolean("$prefix.clip", guides.clip)
                .putBoolean("$prefix.crush", guides.crush)
                .putBoolean("$prefix.middle", guides.middle)

        preferences.edit()
            .putFloat(SCOPE_WAVEFORM_SCALE_KEY, configuration.waveformScale)
            .putString(SCOPE_WAVEFORM_MODE_KEY, configuration.waveformMode.name)
            .putGuides(SCOPE_WAVEFORM_GUIDES_PREFIX, configuration.waveformGuides)
            .putInt(SCOPE_WAVEFORM_BRIGHTNESS_KEY, configuration.waveformBrightness)
            .putFloat(SCOPE_PARADE_SCALE_KEY, configuration.paradeScale)
            .putString(SCOPE_PARADE_MODE_KEY, configuration.paradeMode.name)
            .putGuides(SCOPE_PARADE_GUIDES_PREFIX, configuration.paradeGuides)
            .putInt(SCOPE_PARADE_BRIGHTNESS_KEY, configuration.paradeBrightness)
            .putInt(
                SCOPE_WAVEFORM_PARADE_BRIGHTNESS_VERSION_KEY,
                ScopeAssistConfiguration.WAVEFORM_PARADE_BRIGHTNESS_CALIBRATION_VERSION,
            )
            .putFloat(SCOPE_VECTOR_SCALE_KEY, configuration.vectorscopeScale)
            .putString(SCOPE_VECTOR_ZOOM_KEY, configuration.vectorscopeZoom.name)
            .putInt(SCOPE_VECTOR_BRIGHTNESS_KEY, configuration.vectorscopeBrightness)
            .putFloat(SCOPE_HISTOGRAM_SCALE_KEY, configuration.histogramScale)
            .putFloat(SCOPE_TRAFFIC_LIGHTS_SCALE_KEY, configuration.trafficLightsScale)
            .apply()
    }

    /** Reads only a real integer, treating wrong-typed preference corruption as an absent value. */
    private fun storedInt(key: String): Int? = preferences.all[key] as? Int

    private fun loadStreamPreset(): LiveViewStreamPreset =
        LiveViewStreamPreset.fromStoredName(preferences.getString(STREAM_PRESET_KEY, null))
            ?: LiveViewStreamPreset.FAST

    private fun loadQualityBias(): LiveViewQualityBias =
        LiveViewQualityBias.fromStoredName(preferences.getString(QUALITY_BIAS_KEY, null))
            ?: LiveViewQualityBias.LATENCY

    private fun loadPortraitFeedAspect(): PortraitFeedAspect =
        PortraitFeedAspect.fromStoredName(
            preferences.getString(PORTRAIT_FEED_ASPECT_KEY, null),
        ) ?: PortraitFeedAspect.FIT_16_9

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
        const val DISPLAY_MODE_ORDER_KEY = "display.disp.order.v1"
        const val ENABLED_DISPLAY_MODES_KEY = "display.disp.enabled.v1"
        const val ASSIST_TOOLBAR_ORDER_KEY = "display.assistToolbar.order.v1"
        const val VISIBLE_ASSIST_TOOLS_KEY = "display.assistToolbar.visible.v1"
        const val TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.trafficLights.visibility.migrated.v1"
        const val AUDIO_METERS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.audioMeters.visibility.migrated.v1"
        const val LEVEL_STYLE_KEY = "assist.local.levelStyle.v1"
        const val FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.framing.visibility.migrated.v1"
        const val LEVEL_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.level.visibility.migrated.v1"
        const val GUIDES_VISIBLE_KEY = "assist.local.guides.visible.v2"
        const val GUIDE_FAMILY_KEY = "assist.local.guides.family.v2"
        const val GUIDE_RATIOS_KEY = "assist.local.guides.ratios.v2"
        const val GUIDE_MASK_KEY = "assist.local.guides.mask.v2"
        const val GRID_VISIBLE_KEY = "assist.local.grid.visible.v2"
        const val RULE_OF_THIRDS_KEY = "assist.local.ruleOfThirds"
        const val DESQUEEZE_ENABLED_KEY = "assist.local.desqueeze.enabled.v2"
        const val DESQUEEZE_RATIO_KEY = "assist.local.desqueeze.ratio.v2"
        const val DESQUEEZE_FACTOR_KEY = "assist.local.desqueeze.factor.v1"
        const val DESQUEEZE_ORIENTATION_KEY = "assist.local.desqueeze.orientation.v2"
        const val LEGACY_FRAMING_GUIDE_KEY = "assist.local.framingGuide.v1"
        const val LEGACY_DESQUEEZE_PRESENTATION_KEY = "assist.local.desqueezePresentation.v1"
        const val SCOPE_METER_PREFERENCE = "scope-meter-v1"
        const val FALSE_COLOR_REFERENCE_KEY = "assist.falseColor.reference.v1"
        const val PEAKING_SENSITIVITY_KEY = "assist.peaking.sensitivity.v1"
        const val PEAKING_COLOR_KEY = "assist.peaking.color.v1"
        const val ZEBRA_UNIT_KEY = "assist.zebra.unit.v1"
        const val ZEBRA_HIGHLIGHT_ENABLED_KEY = "assist.zebra.highlight.enabled.v1"
        const val ZEBRA_HIGHLIGHT_IRE_KEY = "assist.zebra.highlight.ire.v1"
        const val ZEBRA_HIGHLIGHT_COLOR_KEY = "assist.zebra.highlight.color.v1"
        const val ZEBRA_MIDTONE_ENABLED_KEY = "assist.zebra.midtone.enabled.v1"
        const val ZEBRA_MIDTONE_IRE_KEY = "assist.zebra.midtone." + "ire.v1"
        const val ZEBRA_MIDTONE_COLOR_KEY = "assist.zebra.midtone.color.v1"
        const val SCOPE_WAVEFORM_SCALE_KEY = "assist.scopes.waveform.scale.v1"
        const val SCOPE_WAVEFORM_MODE_KEY = "assist.scopes.waveform.mode.v1"
        const val SCOPE_WAVEFORM_GUIDES_PREFIX = "assist.scopes.waveform.guides.v1"
        const val SCOPE_WAVEFORM_BRIGHTNESS_KEY = "assist.scopes.waveform.brightness.v1"
        const val SCOPE_PARADE_SCALE_KEY = "assist.scopes.parade.scale.v1"
        const val SCOPE_PARADE_MODE_KEY = "assist.scopes.parade.mode.v1"
        const val SCOPE_PARADE_GUIDES_PREFIX = "assist.scopes.parade.guides.v1"
        const val SCOPE_PARADE_BRIGHTNESS_KEY = "assist.scopes.parade.brightness.v1"
        const val SCOPE_WAVEFORM_PARADE_BRIGHTNESS_VERSION_KEY =
            "assist.scopes.waveformParade.brightnessCalibrationVersion.v1"
        const val SCOPE_VECTOR_SCALE_KEY = "assist.scopes.vector.scale.v1"
        const val SCOPE_VECTOR_ZOOM_KEY = "assist.scopes.vector." + "zoom.v1"
        const val SCOPE_VECTOR_BRIGHTNESS_KEY = "assist.scopes.vector.brightness.v1"
        const val SCOPE_HISTOGRAM_SCALE_KEY = "assist.scopes.histogram." + "scale.v1"
        const val SCOPE_TRAFFIC_LIGHTS_SCALE_KEY = "assist.scopes.trafficLights.scale.v1"
        const val STREAM_PRESET_KEY = "link.streamPreset.v1"
        const val QUALITY_BIAS_KEY = "link.qualityBias.v1"
        const val PORTRAIT_FEED_ASPECT_KEY = "display.portraitFeedAspect.v1"

        private fun legacyScopeMeterPreference(): String =
            "assist.scopes." + "crushClipCompensation.v1"
    }
}

/**
 * "0.1.117 (42)" — versionName (versionCode), matching the iOS System tab's
 * App Version row (`OperatorSettingsPanel.appVersionText`, marketing version +
 * build number).
 */
public fun appVersionText(versionName: String, versionCode: Int): String =
    "$versionName ($versionCode)"
