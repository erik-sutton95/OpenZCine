package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateOf
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.opencine.appkit.MonitorDisplayChrome
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplayPreferences
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.cameracontrols.PortraitFeedAspect
import com.opencapture.opencine.appkit.MonitorOperatorPreferences
import com.opencapture.opencine.media.MonitorDesqueezeDirection

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
 * The local monitor-only framing configuration consumed by the Compose feed overlays, read from
 * the shared assist state. Camera framing-grid state is intentionally absent.
 */
public data class LocalFramingAssistConfiguration(
    /** Whether selected guide frames are drawn. */
    public val guidesVisible: Boolean = false,
    /** Every delivery ratio selected by the operator. */
    public val selectedGuideRatios: Set<MonitorGuideAspect> = emptySet(),
    /** Whether the inverse union of selected guide frames is dimmed. */
    public val guideMaskEnabled: Boolean = false,
    /** Whether the locally configured grid is drawn. */
    public val gridVisible: Boolean = false,
    public val ruleOfThirdsEnabled: Boolean = true,
    public val phiGridEnabled: Boolean = false,
    public val diagonalGridEnabled: Boolean = false,
    public val centerCrosshairEnabled: Boolean = false,
    /** Whether the local camera-level overlay is visible. */
    public val levelEnabled: Boolean = false,
    /** Operator-selected presentation for the camera-level overlay. */
    public val levelStyle: LocalLevelStyle = LocalLevelStyle.HORIZON,
    /** Whether the camera-fed EV meter overlay is visible. */
    public val evMeterEnabled: Boolean = false,
    /** Whether the local de-squeeze presentation is applied. */
    public val desqueezeEnabled: Boolean = false,
    /**
     * Whether the selected mirror axes are visible in this monitor context. Display only:
     * the recording, scopes and camera-reported coordinates retain the source orientation.
     */
    public val mirrorEnabled: Boolean = false,
    /** Applied squeeze factor in 1.0...2.0. */
    public val desqueezeFactor: Float = 1f,
    /** The lens squeeze axis: horizontal widens the picture (letterbox), vertical narrows it. */
    public val desqueezeDirection: MonitorDesqueezeDirection = MonitorDesqueezeDirection.HORIZONTAL,
    /** Selected axes, independent from live/playback mirror visibility. */
    public val mirrorHorizontal: Boolean = true,
    public val mirrorVertical: Boolean = false,
) {
    /** Horizontal display transform admitted by this context's visibility. */
    public val mirrorsHorizontally: Boolean get() = mirrorEnabled && mirrorHorizontal

    /** Vertical display transform admitted by this context's visibility. */
    public val flipsVertically: Boolean get() = mirrorEnabled && mirrorVertical

    /** Whether at least one selected guide is currently visible. */
    public val drawsGuides: Boolean
        get() = guidesVisible && selectedGuideRatios.isNotEmpty()

    /** Whether at least one configured grid pattern is currently visible. */
    public val drawsGrid: Boolean
        get() = gridVisible && (ruleOfThirdsEnabled || phiGridEnabled || diagonalGridEnabled)

    /** Local horizontal monitor scale after applying the selected de-squeeze. */
    public val horizontalPresentationScale: Float
        get() = scale(MonitorDesqueezeDirection.VERTICAL)

    /** Local vertical monitor scale after applying the selected de-squeeze. */
    public val verticalPresentationScale: Float
        get() = scale(MonitorDesqueezeDirection.HORIZONTAL)

    private fun scale(direction: MonitorDesqueezeDirection): Float =
        if (desqueezeEnabled && desqueezeDirection == direction) 1f / desqueezeFactor.coerceAtLeast(1f) else 1f

    /**
     * The aspect ratio a STILL should be presented at once de-squeezed, or null when de-squeeze
     * is off (present at the image's own ratio).
     *
     * Stills cannot use the two presentation scales the way the live feed does. The feed is
     * scaled inside a fixed rect, but a still is FITTED to its container first, so scaling
     * afterwards would push the image outside the frame it was just fitted into. Handing Compose
     * a ratio lets `Modifier.aspectRatio` do the fit, and everything anchored to the resulting
     * box follows without knowing about anamorphic. iOS `desqueezedAspectRatio`.
     */
    public fun desqueezedAspectRatio(sourceWidth: Int, sourceHeight: Int): Float? {
        if (!desqueezeEnabled || sourceWidth <= 0 || sourceHeight <= 0) return null
        val width = sourceWidth * horizontalPresentationScale
        val height = sourceHeight * verticalPresentationScale
        if (width <= 0f || height <= 0f) return null
        val ratio = width / height
        return if (ratio == sourceWidth.toFloat() / sourceHeight) null else ratio
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
        private val load: () -> Boolean = { preferences.getBoolean(key, default) },
        private val store: (Boolean) -> Unit = { preferences.edit().putBoolean(key, it).apply() },
    ) {
        private val state = mutableStateOf(load())

        public var value: Boolean
            get() = state.value
            set(new) {
                state.value = new
                store(new)
            }

        public fun toggle() {
            value = !value
        }
    }

    /** One persisted string: Compose-observable value, write-through on set. */
    public inner class Text internal constructor(
        public val key: String,
        public val default: String,
    ) {
        private val state = mutableStateOf(preferences.getString(key, default) ?: default)

        public var value: String
            get() = state.value
            set(new) {
                state.value = new
                preferences.edit().putString(key, new).apply()
            }
    }

    /**
     * Each DISP mode's chrome in the shared display owner's form; `MonitorOperatorSessionModel` reads and
     * writes it. The first read after the per-capture-side store retired seeds each mode once from its saved
     * video layout, so an operator's choices carry over (the photo side and the DISP order retire).
     */
    public val displayPreferences: MonitorDisplayPreferences =
        MonitorDisplayPreferences(preferences, DISPLAY_KEYS).also { seedRetiredDisplayChrome(preferences, it) }

    /**
     * The shared operator choices on Z's existing keys, so stored values carry over unchanged.
     * Z has no HDR display or originals-cache choice; those keys are never written.
     */
    public val operatorPreferences: MonitorOperatorPreferences = MonitorOperatorPreferences(preferences,
        MonitorOperatorPreferences.Keys(keepScreenAwake = "controls.keepScreenAwake", hdrDisplay = "display.hdr",
            recordConfirmation = "controls.recordConfirmation", haptics = "controls.haptics",
            cacheOriginals = "cache.originals"))

    // Controls — all four are app-local behavior and therefore safe to expose
    // before Android has camera-property writes.
    public val recordConfirmationEnabled: Toggle = Toggle("controls.recordConfirmation", default = true,
        load = { operatorPreferences.recordConfirmation }, store = { operatorPreferences.recordConfirmation = it })
    /** Foreground hardware shutter, including volume keys while the live monitor is armed. */
    public val mediaRemoteShutterEnabled: Toggle =
        Toggle("controls.mediaRemoteShutter.v1", default = true)
    public val hapticsEnabled: Toggle = Toggle("controls.haptics", default = true,
        load = { operatorPreferences.haptics }, store = { operatorPreferences.haptics = it })
    public val keepScreenAwake: Toggle = Toggle("controls.keepScreenAwake", default = true,
        load = { operatorPreferences.keepScreenAwake }, store = { operatorPreferences.keepScreenAwake = it })
    /**
     * Turns the monitoring image upright from the body's live-view orientation. Off
     * keeps the picture in the camera's native landscape sensor orientation. Display
     * only — the recording is never affected. Default on, matching iOS
     * `autoRotateFeedEnabled`.
     */
    public val autoRotateFeedEnabled: Toggle = Toggle("controls.autoRotateFeed", default = true)

    // Sharing (the monitor relay) — iOS `relayWatcherPasscode` / `relayAllowsControlRequests`.
    // The share switch itself is runtime state, exactly like iOS's `isRelayBroadcasting`.
    public val relayWatcherPasscode: Text = Text("sharing.watcherPasscode", default = "")
    public val relayAllowsControlRequests: Toggle =
        Toggle("sharing.allowsControlRequests", default = true)
    /**
     * Broadcast priority — iOS `relayEncoderProfile`. Stored as the shared core's raw value so
     * the two shells persist the same thing, and read back through
     * [com.opencapture.openzcine.core.RelayEncoderProfile.fromWireValue], which falls back to the
     * tightest path rather than trusting whatever is on disk.
     */
    public val relayEncoderProfile: Text =
        Text(
            "sharing.encoderProfile",
            default = com.opencapture.openzcine.core.RelayEncoderProfile.LOW_LATENCY.wireValue,
        )
    /**
     * Enables the live-view focus-by-wire scrub strip in video and photo mode (**default off**).
     * Surfaced as a row inside the FOCUS popup rather than Operator Setup, mirroring the iOS
     * shell; off hides the strip even in an AF focus mode.
     *
     * The stored-key fallback IS the migration: [Toggle] only writes the key when the operator
     * flips it, so an operator who deliberately turned the dial on keeps `true`, one who turned it
     * off keeps `false`, and one who never touched it lands on the new default. Same rule as iOS
     * `PreferencesStore.loadMFScrubEnabled`.
     */
    public val mfDriveScrubEnabled: Toggle = Toggle("controls.mfDriveScrub", default = false)

    private val levelStyleState = mutableStateOf(loadLevelStyle())
    private val streamPresetState = mutableStateOf(loadStreamPreset())
    private val qualityBiasState = mutableStateOf(loadQualityBias())
    private val portraitFeedAspectState = mutableStateOf(loadPortraitFeedAspect())

    /**
     * Writes a stream-settings pick onto the setup it was made on, when there is a live one.
     *
     * A slot rather than a store handle: these settings belong to the connected setup, and only
     * the activity knows which that is. Set when a camera is accepted, cleared on disconnect —
     * so a pick made with nothing connected still moves the live value and simply has nowhere
     * durable to live, which is the honest outcome.
     */
    public var activeSetupStreamSettingsWriter:
        ((LiveViewStreamPreset?, LiveViewQualityBias?) -> Unit)? = null

    /** Requested preview-size profile, resolved by Swift before live view starts. */
    public var streamPreset: LiveViewStreamPreset
        get() = streamPresetState.value
        set(new) {
            streamPresetState.value = new
            preferences.edit().putString(STREAM_PRESET_KEY, new.name).apply()
            activeSetupStreamSettingsWriter?.invoke(new, null)
        }

    /** Requested preview-compression profile, resolved by Swift rather than Kotlin. */
    public var qualityBias: LiveViewQualityBias
        get() = qualityBiasState.value
        set(new) {
            qualityBiasState.value = new
            preferences.edit().putString(QUALITY_BIAS_KEY, new.name).apply()
            activeSetupStreamSettingsWriter?.invoke(null, new)
        }

    /**
     * Seeds the live values from the setup a session just established over, without writing back.
     *
     * The setter above is for an operator's pick; this is the setup telling the app what it runs
     * at. Routing this through the setter would write the resolved value straight back onto the
     * record and turn every default into a stored choice — after which the path rule could never
     * apply again.
     */
    public fun adoptSetupStreamSettings(
        streamPreset: LiveViewStreamPreset,
        qualityBias: LiveViewQualityBias,
    ) {
        streamPresetState.value = streamPreset
        qualityBiasState.value = qualityBias
        preferences.edit()
            .putString(STREAM_PRESET_KEY, streamPreset.name)
            .putString(QUALITY_BIAS_KEY, qualityBias.name)
            .apply()
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
            // The stored names predate the shared enum; they stay readable both ways.
            preferences.edit().putString(PORTRAIT_FEED_ASPECT_KEY,
                if (new == PortraitFeedAspect.FILL) "FILL" else "FIT_16_9").apply()
        }

    /** Selected camera-level presentation; persisted immediately on change. */
    public var levelStyle: LocalLevelStyle
        get() = levelStyleState.value
        set(new) {
            levelStyleState.value = new
            preferences.edit().putString(LEVEL_STYLE_KEY, new.name).apply()
        }

    /** The monitor keeps the screen awake only while this operator policy permits it. */
    public fun shouldKeepScreenAwake(monitorPresented: Boolean): Boolean =
        com.opencapture.opencine.appkit.MonitorScreenWakePolicy.keepAwake(keepScreenAwake.value, monitorPresented)

    /** Every persisted switch, for reset-to-defaults and key-collision checks. */
    public val all: List<Toggle> =
        listOf(
            recordConfirmationEnabled,
            mediaRemoteShutterEnabled,
            hapticsEnabled,
            keepScreenAwake,
            autoRotateFeedEnabled,
            mfDriveScrubEnabled,
        )

    private fun loadLevelStyle(): LocalLevelStyle =
        LocalLevelStyle.fromStoredName(preferences.getString(LEVEL_STYLE_KEY, null))
            ?: LocalLevelStyle.HORIZON

    /** Defaults mirror `OperatorPreferences.defaults` in the shared core — keep them in step. */
    private fun loadStreamPreset(): LiveViewStreamPreset =
        LiveViewStreamPreset.fromStoredName(preferences.getString(STREAM_PRESET_KEY, null))
            ?: LiveViewStreamPreset.SHIPPED_DEFAULT

    private fun loadQualityBias(): LiveViewQualityBias =
        LiveViewQualityBias.fromStoredName(preferences.getString(QUALITY_BIAS_KEY, null))
            ?: LiveViewQualityBias.SHIPPED_DEFAULT

    private fun loadPortraitFeedAspect(): PortraitFeedAspect =
        if (preferences.getString(PORTRAIT_FEED_ASPECT_KEY, null) == "FILL") PortraitFeedAspect.FILL
        else PortraitFeedAspect.FIT_16X9

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
        const val LEVEL_STYLE_KEY = "assist.local.levelStyle.v1"
        const val STREAM_PRESET_KEY = "link.streamPreset.v1"
        const val QUALITY_BIAS_KEY = "link.qualityBias.v1"
        const val PORTRAIT_FEED_ASPECT_KEY = "display.portraitFeedAspect.v1"
        val DISPLAY_KEYS = MonitorDisplayPreferences.Keys("monitorDisplay.live.v1", "monitorDisplay.clean.v1",
            "monitorDisplay.command.v1")
    }
}

/** The retired Z chrome store's per-section key suffixes, in the shared section's terms. */
private val RETIRED_SECTION_KEYS: Map<MonitorDisplaySection, String> = mapOf(
    MonitorDisplaySection.STATUS_BAR to "statusBar", MonitorDisplaySection.TOOL_BAR to "assistToolbar",
    MonitorDisplaySection.CAMERA_VALUES to "cameraValues", MonitorDisplaySection.LOCK_BUTTON to "lockButton",
    MonitorDisplaySection.BATTERIES to "batteryIndicators", MonitorDisplaySection.REC_READOUT to "recReadout",
    MonitorDisplaySection.TIMECODE to "timecodeReadout", MonitorDisplaySection.FORMAT to "resolutionReadout",
    MonitorDisplaySection.CODEC to "codecReadout", MonitorDisplaySection.STORAGE to "mediaReadout",
    MonitorDisplaySection.FPS to "fpsReadout", MonitorDisplaySection.RAIL_RECORD to "railRecord",
    MonitorDisplaySection.RAIL_MEDIA to "railMedia", MonitorDisplaySection.RAIL_SETTINGS to "railSettings",
    MonitorDisplaySection.FOCUS_BOX to "focusBox",
)
private val RETIRED_RAILS = setOf(MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.RAIL_MEDIA,
    MonitorDisplaySection.RAIL_SETTINGS)

/**
 * Seeds each shared layout that has never been stored from the retired video-side switches (`display.`,
 * `display.clean.`, `display.command.`), once. A rail switch never stored falls back to the older whole-rail
 * switch, as the retired store did; DISP 3 inherits DISP 1 where it has no value of its own. A mode with
 * nothing retired to carry stays unstored, so it keeps following the shared defaults.
 */
internal fun seedRetiredDisplayChrome(store: SharedPreferences, display: MonitorDisplayPreferences) {
    fun retired(prefix: String) = (RETIRED_SECTION_KEYS.values + "sideRails").any { store.contains(prefix + it) }
    fun carried(prefix: String, base: MonitorDisplayChrome, rail: (String) -> Boolean?): MonitorDisplayChrome =
        RETIRED_SECTION_KEYS.entries.fold(base) { chrome, (section, key) ->
            val value = when {
                store.contains(prefix + key) -> store.getBoolean(prefix + key, true)
                section in RETIRED_RAILS -> rail(prefix) ?: chrome.isVisible(section)
                else -> chrome.isVisible(section)
            }
            if (chrome.isVisible(section) == value) chrome else chrome.toggling(section)
        }
    fun wholeRail(prefix: String): Boolean? =
        if (store.contains(prefix + "sideRails")) store.getBoolean(prefix + "sideRails", true) else null
    val live = carried("display.", MonitorDisplayChrome.liveDefaults, ::wholeRail)
    if (!display.hasStoredLayout(MonitorDisplayMode.LIVE) && retired("display.")) display.live = live
    if (!display.hasStoredLayout(MonitorDisplayMode.CLEAN) && retired("display.clean."))
        display.clean = carried("display.clean.", MonitorDisplayChrome.cleanDefaults, ::wholeRail)
    if (!display.hasStoredLayout(MonitorDisplayMode.COMMAND) && (retired("display.command.") || retired("display.")))
        display.command = carried("display.command.", live) { wholeRail(it) ?: wholeRail("display.") }
}

/**
 * "0.1.117 (42)" — versionName (versionCode), matching the iOS System tab's
 * App Version row (`OperatorSettingsPanel.appVersionText`, marketing version +
 * build number).
 */
public fun appVersionText(versionName: String, versionCode: Int): String =
    "$versionName ($versionCode)"
