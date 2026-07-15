package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateOf
import com.opencapture.openzcine.AssistTool

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
    /** The local anamorphic factor. */
    public val desqueezeRatio: LocalDesqueezeRatio,
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
                1f / desqueezeRatio.factor
            } else {
                1f
            }

    /** Local vertical monitor scale after applying the selected de-squeeze. */
    public val verticalPresentationScale: Float
        get() =
            if (desqueezeEnabled && desqueezeOrientation == LocalDesqueezeOrientation.VERTICAL) {
                1f / desqueezeRatio.factor
            } else {
                1f
            }

    /** Human-readable accessibility summary that distinguishes local from camera state. */
    public val accessibilitySummary: String
        get() =
            buildString {
                append("Local framing assists. ")
                append(
                    if (drawsGuides) {
                        "${selectedGuideRatios.size} delivery guide${if (selectedGuideRatios.size == 1) "" else "s"} on. "
                    } else {
                        "Delivery guides off. "
                    },
                )
                append(if (guideMaskEnabled) "Mask outside selected frames on. " else "Mask outside selected frames off. ")
                append(if (drawsGrid) "Composition grid on. " else "Composition grid off. ")
                append(if (centerCrosshairEnabled) "Centre crosshair on. " else "Centre crosshair off. ")
                append(
                    if (desqueezeEnabled) {
                        "${desqueezeOrientation.label} desqueeze ${desqueezeRatio.label}. "
                    } else {
                        "Desqueeze off. "
                    },
                )
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
    private val desqueezeOrientationState = mutableStateOf(loadDesqueezeOrientation())
    private val levelStyleState = mutableStateOf(loadLevelStyle())
    private val scopeCrushClipCompensationState = mutableStateOf(loadScopeCrushClipCompensation())

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
        val next = selectedGuideRatiosState.value.toMutableSet()
        if (!next.add(ratio)) next.remove(ratio)
        setSelectedGuideRatios(next)
        guidesVisible.value = next.isNotEmpty()
    }

    /** The selected local anamorphic factor; it applies only when [desqueezeEnabled] is on. */
    public var desqueezeRatio: LocalDesqueezeRatio
        get() = desqueezeRatioState.value
        set(new) {
            desqueezeRatioState.value = new
            preferences.edit().putString(DESQUEEZE_RATIO_KEY, new.name).apply()
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
            AssistTool.DESQ -> desqueezeEnabled.toggle()
            else -> Unit
        }
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
            .putBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, true)
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
        if (!preferences.getBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, false)) {
            // Framing tools are a complete local assist group. Add them once
            // for existing custom toolbar configurations, then preserve every
            // later operator hide/show decision.
            migrated += AssistTool.framingTools
            editor.putBoolean(FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY, true)
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

    private fun legacyDesqueezeRatio(): LocalDesqueezeRatio =
        when (preferences.getString(LEGACY_DESQUEEZE_PRESENTATION_KEY, null)) {
            "X133" -> LocalDesqueezeRatio.X133
            "X150" -> LocalDesqueezeRatio.X150
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

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
        const val ASSIST_TOOLBAR_ORDER_KEY = "display.assistToolbar.order.v1"
        const val VISIBLE_ASSIST_TOOLS_KEY = "display.assistToolbar.visible.v1"
        const val TRAFFIC_LIGHTS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.trafficLights.visibility.migrated.v1"
        const val AUDIO_METERS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.audioMeters.visibility.migrated.v1"
        const val LEVEL_STYLE_KEY = "assist.local.levelStyle.v1"
        const val FRAMING_TOOLS_VISIBILITY_MIGRATED_KEY =
            "display.assistToolbar.framing.visibility.migrated.v1"
        const val GUIDES_VISIBLE_KEY = "assist.local.guides.visible.v2"
        const val GUIDE_FAMILY_KEY = "assist.local.guides.family.v2"
        const val GUIDE_RATIOS_KEY = "assist.local.guides.ratios.v2"
        const val GUIDE_MASK_KEY = "assist.local.guides.mask.v2"
        const val GRID_VISIBLE_KEY = "assist.local.grid.visible.v2"
        const val RULE_OF_THIRDS_KEY = "assist.local.ruleOfThirds"
        const val DESQUEEZE_ENABLED_KEY = "assist.local.desqueeze.enabled.v2"
        const val DESQUEEZE_RATIO_KEY = "assist.local.desqueeze.ratio.v2"
        const val DESQUEEZE_ORIENTATION_KEY = "assist.local.desqueeze.orientation.v2"
        const val LEGACY_FRAMING_GUIDE_KEY = "assist.local.framingGuide.v1"
        const val LEGACY_DESQUEEZE_PRESENTATION_KEY = "assist.local.desqueezePresentation.v1"
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
