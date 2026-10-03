package com.opencapture.openzcine.settings

import androidx.compose.foundation.ScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.res.stringResource
import com.opencapture.monitorui.settings.MonitorDisplayChoice
import com.opencapture.monitorui.settings.MonitorDisplayOrderGroup
import com.opencapture.monitorui.settings.MonitorDisplayOrderItem
import com.opencapture.monitorui.settings.MonitorDisplayOrderList
import com.opencapture.monitorui.settings.MonitorDisplaySection
import com.opencapture.monitorui.settings.MonitorDisplaySettings
import com.opencapture.monitorui.settings.MonitorDisplayToggle
import com.opencapture.monitorui.settings.MonitorSettingsScrollContext
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.R
import com.opencapture.openzcine.labelResource
import com.opencapture.openzcine.titleResource

/** Existing saved values and admitted Nikon actions; common code owns the Display assembly. */
@Composable
internal fun NikonDisplaySettings(
    settings: OperatorSettings,
    compact: Boolean,
    onToggle: (OperatorSettings.Toggle) -> Unit,
    onInteraction: () -> Unit,
    parentScrollState: ScrollState,
    viewportBounds: Rect?,
    liveCaptureMode: CaptureLayoutMode,
    onEditView: (MonitorDisplayMode) -> Unit,
) {
    var expandedMode by rememberSaveable { mutableStateOf<MonitorDisplayMode?>(null) }
    var pickedCapture by rememberSaveable { mutableStateOf<CaptureLayoutMode?>(null) }
    val capture = pickedCapture ?: liveCaptureMode
    val tools = assistOrder(settings, onInteraction)
    val pins = AssistTool.entries.map { tool ->
        val title = stringResource(tool.titleResource())
        MonitorDisplayToggle(tool.name, title, settings.isPinnedToCleanView(tool), action = {
            settings.toggleCleanViewPin(tool)
            onInteraction()
        })
    }
    val sections = MonitorDisplayMode.entries.map { mode ->
        val eligible = mode != MonitorDisplayMode.COMMAND && capture == liveCaptureMode
        val visibility = ChromeSection.configurableIn(mode).map { section ->
            val toggle = settings.chrome(mode, capture)[section]
            MonitorDisplayToggle(section.name, section.title, toggle.value, action = { onToggle(toggle) })
        }
        val readouts = ChromeSection.statusBarReadouts.map { section ->
            val toggle = settings.chrome(mode, capture)[section]
            MonitorDisplayToggle(section.name, section.title, toggle.value, action = { onToggle(toggle) })
        }
        MonitorDisplaySection(
            id = mode.name,
            title = "DISP ${mode.ordinal + 1} · ${stringResource(mode.labelResource())}",
            caption = stringResource(when (mode) {
                MonitorDisplayMode.LIVE -> R.string.settings_disp_live_caption
                MonitorDisplayMode.CLEAN -> R.string.settings_disp_clean_caption
                MonitorDisplayMode.COMMAND -> R.string.settings_disp_command_caption
            }),
            reset = { settings.resetChromeVisibility(mode, capture); onInteraction() },
            editTitle = stringResource(R.string.settings_edit_view),
            edit = if (eligible) ({ onEditView(mode) }) else null,
            unavailableEditHelp = if (mode == MonitorDisplayMode.COMMAND) null else
                stringResource(R.string.settings_layout_for_other_side, capture.title.lowercase()),
            visibility = visibility,
            readoutsTitle = stringResource(R.string.settings_live_readouts),
            readouts = readouts,
            pinsTitle = stringResource(R.string.settings_clean_view_tools),
            pins = if (mode == MonitorDisplayMode.CLEAN) pins else emptyList(),
            tools = if (mode == MonitorDisplayMode.LIVE) tools else null,
        )
    }
    MonitorDisplaySettings(
        layoutTitle = stringResource(R.string.settings_layout_for),
        layoutHelp = stringResource(R.string.settings_layout_for_help),
        choices = CaptureLayoutMode.entries.map { MonitorDisplayChoice(it.name, it.title) },
        selection = capture.name,
        onSelect = { id -> CaptureLayoutMode.entries.firstOrNull { it.name == id }?.let {
            pickedCapture = it
            onInteraction()
        } },
        expandedSection = expandedMode?.name,
        onExpand = { id -> expandedMode = MonitorDisplayMode.entries.firstOrNull { it.name == id }; onInteraction() },
        sections = sections,
        order = displayOrder(settings, onInteraction),
        compact = compact,
        onInteraction = onInteraction,
        scrollContext = MonitorSettingsScrollContext(parentScrollState, viewportBounds),
    )
}

@Composable
private fun assistOrder(settings: OperatorSettings, onInteraction: () -> Unit): MonitorDisplayOrderGroup =
    MonitorDisplayOrderGroup(title = "", caption = stringResource(R.string.settings_assist_toolbar_caption),
        items = settings.assistToolbarOrder.mapIndexed { index, tool ->
            val title = stringResource(tool.titleResource())
            val visible = settings.isAssistToolbarToolVisible(tool)
            MonitorDisplayOrderItem(id = tool.name, title = title, isOn = visible,
                supplement = if (tool == AssistTool.LUT) stringResource(R.string.settings_pinned) else null,
                visibilityLabel = stringResource(R.string.settings_toolbar_visibility, title),
                visibilityValue = stringResource(if (visible) R.string.status_visible else R.string.status_hidden),
                reorderLabel = stringResource(R.string.settings_reorder_position, title, index + 1),
                moveEarlierLabel = stringResource(R.string.settings_move_earlier, title),
                moveLaterLabel = stringResource(R.string.settings_move_later, title),
                positionLabel = stringResource(R.string.settings_position_number, index + 1),
                positionDescription = stringResource(R.string.settings_position, index + 1),
                toggle = if (tool == AssistTool.LUT) null else ({
                    settings.toggleAssistToolbarToolVisibility(tool)
                    onInteraction()
                }))
        }, move = { id, target -> AssistTool.entries.firstOrNull { it.name == id }?.let {
            settings.moveAssistToolbarTool(it, target)
        } })

@Composable
private fun displayOrder(settings: OperatorSettings, onInteraction: () -> Unit): MonitorDisplayOrderGroup =
    MonitorDisplayOrderGroup(title = stringResource(R.string.settings_disp_order),
        caption = stringResource(R.string.settings_disp_order_caption),
        items = settings.displayModeOrder.mapIndexed { index, mode ->
            val title = stringResource(mode.labelResource())
            val enabled = mode in settings.enabledDisplayModes
            MonitorDisplayOrderItem(id = mode.name, title = title, isOn = enabled,
                visibilityLabel = stringResource(R.string.settings_disp_include, title),
                visibilityValue = stringResource(if (enabled) R.string.status_enabled else R.string.status_disabled),
                reorderLabel = stringResource(R.string.settings_reorder_position, title, index + 1),
                moveEarlierLabel = stringResource(R.string.settings_move_earlier, title),
                moveLaterLabel = stringResource(R.string.settings_move_later, title),
                positionLabel = stringResource(R.string.settings_position_number, index + 1),
                positionDescription = stringResource(R.string.settings_position, index + 1),
                toggle = { if (settings.toggleDisplayMode(mode)) onInteraction() })
        }, reset = { settings.resetDisplayModePreferences(); onInteraction() },
        move = { id, target -> MonitorDisplayMode.entries.firstOrNull { it.name == id }?.let {
            settings.moveDisplayMode(it, target)
        } })

/** Thin domain adapter retained for native tests and focused compositions. */
@Composable
internal fun AssistToolbarOrderList(settings: OperatorSettings, onInteraction: () -> Unit,
    parentScrollState: ScrollState? = null, viewportBounds: Rect? = null) {
    val order = assistOrder(settings, onInteraction)
    MonitorDisplayOrderList(order.items, order.move, onInteraction, parentScrollState, viewportBounds)
}

@Composable
internal fun DisplayModeOrderList(settings: OperatorSettings, onInteraction: () -> Unit) {
    val order = displayOrder(settings, onInteraction)
    MonitorDisplayOrderList(order.items, order.move, onInteraction)
}
