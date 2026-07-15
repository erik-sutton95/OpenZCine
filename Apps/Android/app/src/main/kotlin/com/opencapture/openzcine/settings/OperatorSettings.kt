package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateOf
import com.opencapture.openzcine.AssistTool

/**
 * A local delivery-frame guide drawn over the Android monitor feed.
 *
 * This deliberately models only OpenZCine's composited guide. It is not the
 * Nikon body's `GridDisplay` camera property, which remains camera-owned.
 */
public enum class LocalFramingGuide(
    /** Operator-facing ratio label. */
    public val label: String,
    /** Width divided by height for the guide, or `null` when hidden. */
    public val aspectRatio: Float?,
) {
    /** Do not draw a delivery-frame guide. */
    OFF("Off", null),
    /** Cinema delivery frame. */
    CINEMA_239("2.39:1", 2.39f),
    /** Widescreen delivery frame. */
    WIDESCREEN_16_9("16:9", 16f / 9f),
    ;

    internal companion object {
        fun fromStoredName(value: String?): LocalFramingGuide? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * Local horizontal presentation scale for anamorphic material.
 *
 * The scale mirrors the iOS monitor's horizontal de-squeeze geometry: a
 * selected squeeze factor occupies a centred `1 / factor` presentation rect.
 * It affects only the Android monitor composition and never writes to camera
 * properties or media files.
 */
public enum class LocalDesqueezePresentation(
    /** Operator-facing squeeze factor label. */
    public val label: String,
    /** Horizontal monitor scale applied to the local presentation. */
    public val horizontalPresentationScale: Float,
) {
    /** Preserve the source presentation. */
    OFF("Off", 1f),
    /** Present with a 1.33× horizontal anamorphic factor. */
    X133("1.33×", 1f / 1.33f),
    /** Present with a 1.5× horizontal anamorphic factor. */
    X150("1.5×", 1f / 1.5f),
    /** Present with a 1.65× horizontal anamorphic factor. */
    X165("1.65×", 1f / 1.65f),
    /** Present with a 1.8× horizontal anamorphic factor. */
    X180("1.8×", 1f / 1.8f),
    /** Present with a 2× horizontal anamorphic factor. */
    X200("2×", 0.5f),
    ;

    internal companion object {
        fun fromStoredName(value: String?): LocalDesqueezePresentation? =
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

/**
 * The local monitor-only framing configuration consumed by the Compose feed
 * overlay. Camera framing-grid state is intentionally absent.
 */
public data class LocalFramingAssistConfiguration(
    /** Whether the local thirds grid is drawn. */
    public val ruleOfThirdsEnabled: Boolean,
    /** Whether the local centre crosshair is drawn. */
    public val centerCrosshairEnabled: Boolean,
    /** The local delivery-frame guide. */
    public val guide: LocalFramingGuide,
    /** The local anamorphic presentation choice. */
    public val desqueezePresentation: LocalDesqueezePresentation,
    /** Whether the local camera-level overlay is visible. */
    public val levelEnabled: Boolean = false,
    /** Operator-selected presentation for the camera-level overlay. */
    public val levelStyle: LocalLevelStyle = LocalLevelStyle.HORIZON,
) {
    /** Human-readable accessibility summary that distinguishes local from camera state. */
    public val accessibilitySummary: String
        get() =
            buildString {
                append("Local framing assists. ")
                append(if (ruleOfThirdsEnabled) "Rule-of-thirds grid on. " else "Rule-of-thirds grid off. ")
                append(if (centerCrosshairEnabled) "Centre crosshair on. " else "Centre crosshair off. ")
                append("Frame guide ${guide.label}. ")
                append("Desqueeze presentation ${desqueezePresentation.label}. ")
                append(if (levelEnabled) "Camera level ${levelStyle.label}. " else "Camera level off. ")
                append("Camera Grid Display is unchanged.")
            }
}

/**
 * Persisted operator preferences — the Android counterpart of the iOS shell's
 * `OperatorPreferences` (UserDefaults-backed). Every value is Compose-observable
 * and writes through to app-private [SharedPreferences] on change.
 *
 * Camera-owned values (exposure, codec, resolution, and live-view transport)
 * deliberately do not belong here. This store only owns local monitor behavior.
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

    // Display chrome — maps to the local, supported subset of iOS
    // `DisplayChromeVisibility`. `sideRailsVisible` remains intentionally out
    // of this Android surface: hiding the only Settings entry would strand an
    // operator without an equivalent recovery affordance.
    public val statusBarVisible: Toggle = Toggle("display.statusBar", default = true)
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
    /** Opt-in foreground media-button shutter; it never intercepts phone volume keys. */
    public val mediaRemoteShutterEnabled: Toggle =
        Toggle("controls.mediaRemoteShutter.v1", default = false)
    public val hapticsEnabled: Toggle = Toggle("controls.haptics", default = true)
    public val keepScreenAwake: Toggle = Toggle("controls.keepScreenAwake", default = true)

    // View Assist — local composited framing aids. These values deliberately
    // stay separate from the camera-owned GridDisplay property so a monitor
    // operator never accidentally changes the body while composing a shot.
    public val ruleOfThirdsEnabled: Toggle = Toggle("assist.local.ruleOfThirds", default = false)
    public val centerCrosshairEnabled: Toggle = Toggle("assist.local.centerCrosshair", default = false)
    /** Enables the local camera-level assist; it never writes a camera property. */
    public val levelAssistEnabled: Toggle = Toggle("assist.local.level", default = false)
    /** Shows the shared Swift meter's RGB edge blocks on the histogram. */
    public val histogramTrafficLightsEnabled: Toggle =
        Toggle("assist.scopes.histogramTrafficLights.v1", default = true)

    private val framingGuideState = mutableStateOf(loadFramingGuide())
    private val desqueezePresentationState = mutableStateOf(loadDesqueezePresentation())
    private val levelStyleState = mutableStateOf(loadLevelStyle())
    private val scopeCrushClipCompensationState = mutableStateOf(loadScopeCrushClipCompensation())

    /** Selected local delivery-frame guide; persisted immediately on change. */
    public var framingGuide: LocalFramingGuide
        get() = framingGuideState.value
        set(new) {
            framingGuideState.value = new
            preferences.edit().putString(FRAMING_GUIDE_KEY, new.name).apply()
        }

    /** Selected local anamorphic presentation; persisted immediately on change. */
    public var desqueezePresentation: LocalDesqueezePresentation
        get() = desqueezePresentationState.value
        set(new) {
            desqueezePresentationState.value = new
            preferences.edit().putString(DESQUEEZE_PRESENTATION_KEY, new.name).apply()
        }

    /** Selected camera-level presentation; persisted immediately on change. */
    public var levelStyle: LocalLevelStyle
        get() = levelStyleState.value
        set(new) {
            levelStyleState.value = new
            preferences.edit().putString(LEVEL_STYLE_KEY, new.name).apply()
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

    /** Compose-observable framing state for the monitor overlay. */
    public val localFramingAssistConfiguration: LocalFramingAssistConfiguration
        get() =
            LocalFramingAssistConfiguration(
                ruleOfThirdsEnabled = ruleOfThirdsEnabled.value,
                centerCrosshairEnabled = centerCrosshairEnabled.value,
                guide = framingGuide,
                desqueezePresentation = desqueezePresentation,
                levelEnabled = levelAssistEnabled.value,
                levelStyle = levelStyle,
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
            .apply()
    }

    /** Moves [tool] one supported toolbar slot in [direction] (`-1` or `1`). */
    public fun moveAssistToolbarTool(tool: AssistTool, direction: Int) {
        require(direction == -1 || direction == 1) { "direction must be -1 or 1." }
        val current = assistToolbarOrderState.value
        val index = current.indexOf(tool)
        val target = index + direction
        if (index < 0 || target !in current.indices) return

        val next = current.toMutableList()
        next[index] = next[target]
        next[target] = tool
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
            .apply()
    }

    /** The monitor keeps the screen awake only while this operator policy permits it. */
    public fun shouldKeepScreenAwake(monitorPresented: Boolean): Boolean =
        monitorPresented && keepScreenAwake.value

    /** Every persisted switch, for reset-to-defaults and key-collision checks. */
    public val all: List<Toggle> =
        listOf(
            statusBarVisible,
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
            ruleOfThirdsEnabled,
            centerCrosshairEnabled,
            levelAssistEnabled,
        )

    private fun loadAssistToolbarOrder(): List<AssistTool> {
        val stored =
            preferences.getString(ASSIST_TOOLBAR_ORDER_KEY, null)
                ?.split(',')
                ?.mapNotNull(AssistTool::fromStoredName)
                .orEmpty()
        val deduplicated = stored.distinct()
        return deduplicated + AssistTool.entries.filterNot(deduplicated::contains)
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
        if (changed) {
            editor.putStringSet(VISIBLE_ASSIST_TOOLS_KEY, migrated.mapTo(linkedSetOf()) { it.name }).apply()
        }
        return migrated
    }

    private fun loadFramingGuide(): LocalFramingGuide =
        LocalFramingGuide.fromStoredName(preferences.getString(FRAMING_GUIDE_KEY, null))
            ?: LocalFramingGuide.OFF

    private fun loadDesqueezePresentation(): LocalDesqueezePresentation =
        LocalDesqueezePresentation.fromStoredName(
            preferences.getString(DESQUEEZE_PRESENTATION_KEY, null),
        ) ?: LocalDesqueezePresentation.OFF

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

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
        const val ASSIST_TOOLBAR_ORDER_KEY = "display.assistToolbar.order.v1"
        const val VISIBLE_ASSIST_TOOLS_KEY = "display.assistToolbar.visible.v1"
        const val TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.trafficLights.visibility.migrated.v1"
        const val AUDIO_METERS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.audioMeters.visibility.migrated.v1"
        const val FRAMING_GUIDE_KEY = "assist.local.framingGuide.v1"
        const val DESQUEEZE_PRESENTATION_KEY = "assist.local.desqueezePresentation.v1"
        const val LEVEL_STYLE_KEY = "assist.local.levelStyle.v1"
        const val SCOPE_METER_PREFERENCE = "scope-meter-v1"

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
