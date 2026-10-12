package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateOf
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.opencine.appkit.MonitorOperatorPreferences
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.openzcine.R

/**
 * Top-level monitor layout selected by the operator's DISP button.
 *
 * Persisted order and enablement use the stable enum names.
 */
public enum class MonitorDisplayMode(
    /** Operator-facing settings label. */
    public val label: String,
) {
    /** Camera feed with operator overlays and controls. */
    LIVE("Live"),

    /** Camera feed with the live tool chrome removed. */
    CLEAN("Clean"),

    /** Camera-backed command dashboard with the live-view consumer released. */
    COMMAND("Command"),
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

/**
 * Which capture side of the camera a monitor layout belongs to, mirroring the shared core's
 * `CaptureLayoutMode`. A cinema operator and a stills shooter want different chrome on the same
 * phone, so every configuration is keyed by DISP mode **and** this.
 */
public enum class CaptureLayoutMode(
    /** Operator-facing label for the Display tab's layout switch. */
    public val title: String,
) {
    VIDEO("Video"),
    PHOTO("Photo"),
}

/**
 * One switchable piece of monitor chrome, mirroring iOS
 * `DisplayChromeVisibility.Section`. Each DISP mode owns its own set of these, per capture side.
 */
public enum class ChromeSection(
    /** Operator-facing label; matches the iOS `Section.title` strings. */
    public val title: String,
    /** Stored-preference suffix, appended to the set's key prefix. */
    internal val key: String,
) {
    STATUS_BAR("Status Bar", "statusBar"),

    /**
     * **Legacy.** The whole right rail used to be one switch, which is why record, Media, Settings
     * and DISP had no controls of their own. They are now [RAIL_RECORD], [RAIL_MEDIA],
     * [RAIL_SETTINGS] and [RAIL_DISP]; this survives only as the migration source for those four
     * and is configurable in no mode.
     */
    SIDE_RAILS("Side Rail", "sideRails"),
    ASSIST_TOOLBAR("Tool Bar", "assistToolbar"),
    CAMERA_VALUES("Camera Values", "cameraValues"),
    LOCK_BUTTON("Lock Button", "lockButton"),
    BATTERY_INDICATORS("Batteries", "batteryIndicators"),
    REC_READOUT("REC", "recReadout"),
    CODEC_READOUT("CODEC", "codecReadout"),
    MEDIA_READOUT("MEDIA", "mediaReadout"),
    FPS_READOUT("FPS", "fpsReadout"),
    TIMECODE_READOUT("TIMECODE", "timecodeReadout"),
    RESOLUTION_READOUT("RESOLUTION", "resolutionReadout"),
    RAIL_RECORD("Record", "railRecord"),
    RAIL_MEDIA("Media", "railMedia"),
    RAIL_SETTINGS("Settings", "railSettings"),
    RAIL_DISP("DISP", "railDisp"),
    FOCUS_BOX("AF Box", "focusBox"),
    ;

    /**
     * Whether the operator may show or hide this in [mode], mirroring
     * `DisplayChromeVisibility.isConfigurable(_:in:)`.
     *
     * Live and clean offer the **same** list — clean is DISP 1 with different defaults, not a
     * smaller feature. Command replaces the feed with the dashboard, so it only owns the rail
     * cluster. [SIDE_RAILS] belongs to nobody: it is the retired whole-rail blob.
     */
    public fun isConfigurableIn(mode: MonitorDisplayMode): Boolean =
        when {
            this == SIDE_RAILS -> false
            // Never hideable, in any mode or configuration — it is the only visible way to
            // change mode, and a feed swipe the operator has to already know about is not an
            // escape route. Mirrors the core's `isConfigurable`.
            this == RAIL_DISP -> false
            mode == MonitorDisplayMode.COMMAND ->
                this == LOCK_BUTTON || this == BATTERY_INDICATORS || this in railControls
            else -> true
        }

    public companion object {
        /** The sections [mode] lets the operator show or hide, in render order. */
        public fun configurableIn(mode: MonitorDisplayMode): List<ChromeSection> =
            entries.filter { it.isConfigurableIn(mode) }

        /**
         * The status-bar cells. In photography the same three slots carry SHOTS, image area and
         * quality — one cell, one switch, whichever capture mode the body is in.
         */
        public val statusBarReadouts: List<ChromeSection> =
            listOf(
                REC_READOUT,
                TIMECODE_READOUT,
                RESOLUTION_READOUT,
                CODEC_READOUT,
                MEDIA_READOUT,
                FPS_READOUT,
            )

        /** The four side-rail controls, top to bottom as the landscape rail draws them. */
        public val railControls: List<ChromeSection> =
            listOf(RAIL_DISP, RAIL_RECORD, RAIL_MEDIA, RAIL_SETTINGS)
    }
}

/**
 * Which side-rail controls mount right now, guarantees applied. Mirrors the shared core's
 * `MonitorChromePolicy.SideRailPlan` — see [OperatorSettings.sideRailPlan].
 */
public data class SideRailPlan(
    val lock: Boolean,
    val batteries: Boolean,
    val disp: Boolean,
    val record: Boolean,
    val media: Boolean,
    val settings: Boolean,
) {
    /** Whether the rail mounts anything at all — the portrait system band draws only then. */
    public val isEmpty: Boolean
        get() = !(lock || batteries || disp || record || media || settings)
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

    // Display chrome — maps to iOS `DisplayChromeVisibility`. One set per (DISP mode, capture
    // side); each set is keyed `<prefix><section.key>`, so DISP 1 video keeps the original
    // `display.statusBar`-style keys and nothing an operator already stored moves.
    //
    // A [Toggle] writes its key only when the operator flips it, so every `default` below IS the
    // migration: an explicit choice survives, and anything untouched picks up the new stock value.

    /** The pre-split whole-rail value for one set — the migration source for its four controls. */
    private fun storedSideRails(prefix: String, fallback: Boolean): Boolean =
        preferences.getBoolean(prefix + ChromeSection.SIDE_RAILS.key, fallback)

    private val liveSideRailsStored = storedSideRails("display.", fallback = true)
    private val cleanSideRailsStored = storedSideRails("display.clean.", fallback = true)
    private val commandSideRailsStored =
        storedSideRails("display.command.", fallback = liveSideRailsStored)

    /** One DISP mode's chrome switches on one capture side, mirroring iOS `DisplayChromeVisibility`. */
    @Stable
    public inner class ChromeVisibility internal constructor(
        keyPrefix: String,
        defaultFor: (ChromeSection) -> Boolean,
    ) {
        private val toggles: Map<ChromeSection, Toggle> =
            ChromeSection.entries.associateWith {
                Toggle(keyPrefix + it.key, default = defaultFor(it))
            }

        public operator fun get(section: ChromeSection): Toggle = toggles.getValue(section)

        public val statusBar: Toggle get() = get(ChromeSection.STATUS_BAR)
        public val sideRails: Toggle get() = get(ChromeSection.SIDE_RAILS)
        public val assistToolbar: Toggle get() = get(ChromeSection.ASSIST_TOOLBAR)
        public val cameraValues: Toggle get() = get(ChromeSection.CAMERA_VALUES)
        public val lockButton: Toggle get() = get(ChromeSection.LOCK_BUTTON)
        public val batteryIndicators: Toggle get() = get(ChromeSection.BATTERY_INDICATORS)
        public val recReadout: Toggle get() = get(ChromeSection.REC_READOUT)
        public val codecReadout: Toggle get() = get(ChromeSection.CODEC_READOUT)
        public val mediaReadout: Toggle get() = get(ChromeSection.MEDIA_READOUT)
        public val fpsReadout: Toggle get() = get(ChromeSection.FPS_READOUT)
        public val railRecord: Toggle get() = get(ChromeSection.RAIL_RECORD)
        public val railMedia: Toggle get() = get(ChromeSection.RAIL_MEDIA)
        public val railSettings: Toggle get() = get(ChromeSection.RAIL_SETTINGS)
        public val railDisp: Toggle get() = get(ChromeSection.RAIL_DISP)
        public val focusBox: Toggle get() = get(ChromeSection.FOCUS_BOX)
    }

    private val liveChrome =
        ChromeVisibility("display.") { section ->
            if (section in ChromeSection.railControls) liveSideRailsStored else true
        }

    /**
     * DISP 2's stock configuration: a bare image plus the operator's way around it. The status
     * deck, both bottom strips and the lock key start off; the rail, the focus box and the
     * batteries start on, because a clean view with no focus feedback, no battery and no route to
     * Settings is a view you have to leave to use. The readout flags stay on so switching the bar
     * back on yields a complete bar rather than an empty pill.
     */
    private val cleanChrome =
        ChromeVisibility("display.clean.") { section ->
            when (section) {
                ChromeSection.STATUS_BAR,
                ChromeSection.ASSIST_TOOLBAR,
                ChromeSection.CAMERA_VALUES,
                ChromeSection.LOCK_BUTTON,
                -> false
                in ChromeSection.railControls -> cleanSideRailsStored
                else -> true
            }
        }

    // DISP 3 inherits DISP 1's *current* values, matching the Swift decode, so a rail or battery
    // cluster the operator had hidden stays hidden on the dashboard.
    private val commandChrome =
        ChromeVisibility("display.command.") { section ->
            if (section in ChromeSection.railControls) {
                commandSideRailsStored
            } else {
                liveChrome[section].value
            }
        }

    // Photography's counterparts. Each seeds from the video side, so an operator who configured
    // DISP 1 for video sees the same thing the first time the body switches to stills — until they
    // deliberately diverge the two.
    private val photoLiveChrome =
        ChromeVisibility("display.photo.") { liveChrome[it].value }
    private val photoCleanChrome =
        ChromeVisibility("display.photo.clean.") { cleanChrome[it].value }
    private val photoCommandChrome =
        ChromeVisibility("display.photo.command.") { commandChrome[it].value }

    // The original DISP 1 video names, kept because they are the app's oldest preference surface.
    public val statusBarVisible: Toggle get() = liveChrome.statusBar
    public val sideRailsVisible: Toggle get() = liveChrome.sideRails
    public val assistToolbarVisible: Toggle get() = liveChrome.assistToolbar
    public val cameraValuesVisible: Toggle get() = liveChrome.cameraValues
    public val recReadoutVisible: Toggle get() = liveChrome.recReadout
    public val codecReadoutVisible: Toggle get() = liveChrome.codecReadout
    public val mediaReadoutVisible: Toggle get() = liveChrome.mediaReadout
    public val fpsReadoutVisible: Toggle get() = liveChrome.fpsReadout

    /** The chrome configuration [mode] renders on the [capture] side of the camera. */
    public fun chrome(
        mode: MonitorDisplayMode,
        capture: CaptureLayoutMode = CaptureLayoutMode.VIDEO,
    ): ChromeVisibility =
        when (capture) {
            CaptureLayoutMode.VIDEO ->
                when (mode) {
                    MonitorDisplayMode.LIVE -> liveChrome
                    MonitorDisplayMode.CLEAN -> cleanChrome
                    MonitorDisplayMode.COMMAND -> commandChrome
                }
            CaptureLayoutMode.PHOTO ->
                when (mode) {
                    MonitorDisplayMode.LIVE -> photoLiveChrome
                    MonitorDisplayMode.CLEAN -> photoCleanChrome
                    MonitorDisplayMode.COMMAND -> photoCommandChrome
                }
        }

    /** Flips one chrome section for one DISP mode; sections the mode does not own are ignored. */
    public fun toggleChrome(
        section: ChromeSection,
        mode: MonitorDisplayMode,
        capture: CaptureLayoutMode = CaptureLayoutMode.VIDEO,
    ) {
        if (!section.isConfigurableIn(mode)) return
        chrome(mode, capture)[section].toggle()
    }

    /** Restores one DISP mode's chrome on one capture side to its stock configuration. */
    public fun resetChromeVisibility(
        mode: MonitorDisplayMode,
        capture: CaptureLayoutMode = CaptureLayoutMode.VIDEO,
    ) {
        val chrome = chrome(mode, capture)
        ChromeSection.entries.forEach { chrome[it].value = chrome[it].default }
    }

    /**
     * Which side-rail controls mount for one chrome / lock / recording state, mirroring the core's
     * `MonitorChromePolicy.sideRailPlan`. One boolean per control, because the rail is six
     * independent elements and used to be one switch.
     *
     * Two carry guarantees, because hiding them would leave no way out of the operator's own
     * configuration: **record** stays while a take is rolling or a command is in flight, and
     * **Settings** stays when no enabled DISP mode carries one. The DISP key needs no guarantee —
     * the feed swipe (down → clean, up → live) changes mode without it — and the lock key's own
     * guarantee is [monitorShowsLockControl]'s.
     */
    public fun sideRailPlan(
        mode: MonitorDisplayMode,
        capture: CaptureLayoutMode,
        interfaceLocked: Boolean,
        recordingOrPending: Boolean,
    ): SideRailPlan {
        val chrome = chrome(mode, capture)
        val settingsReachable =
            enabledDisplayModes.any { chrome(it, capture).railSettings.value }
        return SideRailPlan(
            lock = chrome.lockButton.value || interfaceLocked,
            batteries = chrome.batteryIndicators.value,
            disp = true, // Always on — not a preference the operator can reach.

            record = chrome.railRecord.value || recordingOrPending,
            media = chrome.railMedia.value,
            settings = chrome.railSettings.value || !settingsReachable,
        )
    }

    internal val displaySession = com.opencapture.opencine.appkit.MonitorDisplaySession(MonitorDisplayMode.LIVE)

    /**
     * The DISP mode whose chrome the operator is editing on the monitor itself, or `null` when the
     * monitor is live. Session-only — never persisted, so a crash or relaunch cannot strand the
     * operator in the editor.
     */
    public val chromeEditorMode: MonitorDisplayMode?
        get() = displaySession.editingMode

    /** Opens the Edit view on [mode]. The caller dismisses Operator Setup. */
    public fun beginChromeEditing(mode: MonitorDisplayMode) {
        displaySession.beginEditing(mode)
    }

    public fun endChromeEditing() {
        displaySession.finishEditing(enabledDisplayModeOrder)
    }

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
            preferences.edit().putString(PORTRAIT_FEED_ASPECT_KEY, new.name).apply()
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
        monitorPresented && keepScreenAwake.value

    /** Every persisted switch, for reset-to-defaults and key-collision checks. */
    public val all: List<Toggle> =
        // Every chrome set, every capture side — six sets of seventeen, generated rather than
        // listed, so a new section cannot be added to the enum and forgotten here.
        MonitorDisplayMode.entries.flatMap { mode ->
            CaptureLayoutMode.entries.flatMap { capture ->
                ChromeSection.entries.map { chrome(mode, capture)[it] }
            }
        } +
        listOf(
            recordConfirmationEnabled,
            mediaRemoteShutterEnabled,
            hapticsEnabled,
            keepScreenAwake,
            autoRotateFeedEnabled,
            mfDriveScrubEnabled,
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
        PortraitFeedAspect.fromStoredName(
            preferences.getString(PORTRAIT_FEED_ASPECT_KEY, null),
        ) ?: PortraitFeedAspect.FIT_16_9

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
        const val DISPLAY_MODE_ORDER_KEY = "display.disp.order.v1"
        const val ENABLED_DISPLAY_MODES_KEY = "display.disp.enabled.v1"
        const val LEVEL_STYLE_KEY = "assist.local.levelStyle.v1"
        const val STREAM_PRESET_KEY = "link.streamPreset.v1"
        const val QUALITY_BIAS_KEY = "link.qualityBias.v1"
        const val PORTRAIT_FEED_ASPECT_KEY = "display.portraitFeedAspect.v1"
    }
}

/**
 * "0.1.117 (42)" — versionName (versionCode), matching the iOS System tab's
 * App Version row (`OperatorSettingsPanel.appVersionText`, marketing version +
 * build number).
 */
public fun appVersionText(versionName: String, versionCode: Int): String =
    "$versionName ($versionCode)"
