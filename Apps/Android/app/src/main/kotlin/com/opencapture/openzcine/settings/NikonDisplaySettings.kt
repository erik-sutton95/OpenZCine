package com.opencapture.openzcine.settings

import androidx.compose.foundation.ScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.res.stringResource
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.settings.MonitorDisplayChoice
import com.opencapture.monitorui.settings.MonitorDisplayOrderGroup
import com.opencapture.monitorui.settings.MonitorDisplayOrderItem
import com.opencapture.monitorui.settings.MonitorDisplayOrderList
import com.opencapture.monitorui.settings.MonitorDisplaySection
import com.opencapture.monitorui.settings.MonitorDisplaySettings
import com.opencapture.monitorui.settings.MonitorDisplayToggle
import com.opencapture.monitorui.settings.MonitorSettingsScrollContext
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.cameracontrols.MonitorOperatorBorrowedDisplay
import com.opencapture.openzcine.R

/** Existing saved values and admitted Nikon actions; common code owns the Display assembly. */
@Composable
internal fun rememberNikonBorrowedDisplay(
    settings: OperatorSettings,
    assist: MonitorAssistState,
    onToggle: (OperatorSettings.Toggle) -> Unit,
    onInteraction: () -> Unit,
    liveCaptureMode: CaptureLayoutMode,
    onEditView: (MonitorDisplayMode) -> Unit,
): MonitorOperatorBorrowedDisplay {
    var expandedMode by rememberSaveable { mutableStateOf<MonitorDisplayMode?>(null) }
    var pickedCapture by rememberSaveable { mutableStateOf<CaptureLayoutMode?>(null) }
    val capture = pickedCapture ?: liveCaptureMode
    val pins = MonitorAssistTool.cleanPinCases.filter { it != MonitorAssistTool.ND }.map { tool ->
        MonitorDisplayToggle(tool.name, tool.title, tool in assist.pinned, action = {
            assist.togglePin(tool)
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
        )
    }
    return MonitorOperatorBorrowedDisplay(
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
    )
}

/** Compatibility leaf; production settings pass the same values into the complete shared page. */
@Composable
internal fun NikonDisplaySettings(
    settings: OperatorSettings, assist: MonitorAssistState, compact: Boolean,
    onToggle: (OperatorSettings.Toggle) -> Unit, onInteraction: () -> Unit,
    parentScrollState: ScrollState, viewportBounds: Rect?, liveCaptureMode: CaptureLayoutMode,
    onEditView: (MonitorDisplayMode) -> Unit,
) {
    val display = rememberNikonBorrowedDisplay(settings, assist, onToggle, onInteraction, liveCaptureMode, onEditView)
    MonitorDisplaySettings(display.layoutTitle, display.layoutHelp, display.choices, display.selection,
        display.onSelect, display.expandedSection, display.onExpand, display.sections, display.order,
        compact, onInteraction, MonitorSettingsScrollContext(parentScrollState, viewportBounds))
}

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
internal fun DisplayModeOrderList(settings: OperatorSettings, onInteraction: () -> Unit,
    parentScrollState: ScrollState? = null, viewportBounds: Rect? = null) {
    val order = displayOrder(settings, onInteraction)
    MonitorDisplayOrderList(order.items, order.move, onInteraction, parentScrollState, viewportBounds)
}
