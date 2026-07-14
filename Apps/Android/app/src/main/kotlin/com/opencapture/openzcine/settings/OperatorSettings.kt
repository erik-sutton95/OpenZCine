package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateOf
import com.opencapture.openzcine.AssistTool

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

    // Controls — all three are app-local behavior and therefore safe to expose
    // before Android has camera-property writes.
    public val recordConfirmationEnabled: Toggle =
        Toggle("controls.recordConfirmation", default = true)
    public val hapticsEnabled: Toggle = Toggle("controls.haptics", default = true)
    public val keepScreenAwake: Toggle = Toggle("controls.keepScreenAwake", default = true)

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
        get() = assistToolbarOrder.filter(::isAssistToolbarToolVisible)

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
            hapticsEnabled,
            keepScreenAwake,
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
        return preferences.getStringSet(VISIBLE_ASSIST_TOOLS_KEY, emptySet())
            ?.mapNotNull(AssistTool::fromStoredName)
            ?.toSet()
            .orEmpty()
    }

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
        const val ASSIST_TOOLBAR_ORDER_KEY = "display.assistToolbar.order.v1"
        const val VISIBLE_ASSIST_TOOLS_KEY = "display.assistToolbar.visible.v1"
    }
}

/**
 * "0.1.117 (42)" — versionName (versionCode), matching the iOS System tab's
 * App Version row (`OperatorSettingsPanel.appVersionText`, marketing version +
 * build number).
 */
public fun appVersionText(versionName: String, versionCode: Int): String =
    "$versionName ($versionCode)"
