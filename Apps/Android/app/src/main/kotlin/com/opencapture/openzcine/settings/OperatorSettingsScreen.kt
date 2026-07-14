package com.opencapture.openzcine.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.BuildConfig
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.glass

/**
 * Operator Setup rail tabs — the Android v1 subset of the iOS
 * `OperatorSettingsTab` set (Link / View Assist / Controls / Display /
 * Storage / System). Link, Controls, and Storage arrive with the features
 * that back them (link scoring, touch safety, media cache).
 */
public enum class OperatorSettingsTab(
    public val title: String,
    public val railSubtitle: String,
    public val subtitle: String,
    public val pill: String,
) {
    ASSIST("View Assist", "Scopes & overlays", "Behavior for live-view tools.", "ASSIST"),
    DISPLAY("Display", "Live view", "Live view buttons and chrome.", "VISIBILITY"),
    SYSTEM("System", "App behavior", "App-level behavior.", "APP"),
}

/**
 * The full-screen Operator Settings surface — a 1:1 structural port of the
 * iOS `OperatorSettingsPanel` (ios/Runner/MonitorPanels.swift): floating close
 * button, eyebrow/title header with the live tile, vertical tab rail, and a
 * rounded content pane per tab. [assistState] is the monitor toolbar's state,
 * so view-assist changes apply immediately and persist through one seam.
 */
@Composable
public fun OperatorSettingsScreen(
    session: CameraSession,
    assistState: AssistState,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val settings = remember { OperatorSettings(context) }
    var selectedTab by rememberSaveable { mutableStateOf(OperatorSettingsTab.ASSIST) }

    BoxWithConstraints(
        Modifier.fillMaxSize()
            .background(LiveDesign.background)
            // A hit-testable node at the root keeps every pointer event on
            // this surface — without it, taps between rows would fall through
            // to the monitor chrome's buttons underneath (Compose siblings
            // below stay hit-testable wherever the overlay itself has no
            // pointer node).
            .pointerInput(Unit) { detectTapGestures {} }
            .windowInsetsPadding(WindowInsets.safeDrawing)
    ) {
        val compact = maxWidth < 600.dp
        Column(
            Modifier.fillMaxSize()
                .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // The floating PanelCloseButton overlays this row's leading corner
            // (the iOS iPad clearance fix — `closeButtonClearance`): inset the
            // header to start beside it, (16 + 37 + 8) − 16dp of panel padding.
            SettingsHeader(session, compact)
            if (compact) {
                SettingsTabStrip(selectedTab, onSelect = { selectedTab = it })
                SettingsContentPane(
                    selectedTab,
                    settings,
                    assistState,
                    compact = true,
                    modifier = Modifier.weight(1f),
                )
            } else {
                Row(
                    Modifier.fillMaxWidth().weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    SettingsTabRail(selectedTab, onSelect = { selectedTab = it })
                    SettingsContentPane(
                        selectedTab,
                        settings,
                        assistState,
                        compact = false,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
        // Floats in the very top-left corner, outside the layout flow, at the
        // iOS metrics (leading 16, top 22).
        Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
    }
}

/** Eyebrow + title with the live tile pinned trailing (iOS `settingsTop`). */
@Composable
private fun SettingsHeader(session: CameraSession, compact: Boolean) {
    if (compact) {
        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SettingsTitle(Modifier.padding(start = 45.dp))
            SettingsLiveTile(session, Modifier.fillMaxWidth(), expanded = true)
        }
    } else {
        Row(
            Modifier.fillMaxWidth().padding(start = 45.dp),
            verticalAlignment = Alignment.Top,
        ) {
            SettingsTitle()
            Spacer(Modifier.weight(1f))
            SettingsLiveTile(session, expanded = false)
        }
    }
}

@Composable
private fun SettingsTitle(modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            "OPENZCINE",
            color = LiveDesign.accent,
            fontSize = 9.5.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.8.sp,
        )
        Text(
            "Operator Setup",
            style = chromeStyle(24f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
    }
}

/** Link-state tile: status dot, title/detail, meter bars (iOS `SettingsLiveTile`). */
@Composable
private fun SettingsLiveTile(
    session: CameraSession,
    modifier: Modifier = Modifier,
    expanded: Boolean,
) {
    val state by session.state.collectAsState()
    val linked = state is CameraSessionState.Connected
    val tint = if (linked) LiveDesign.good else LiveDesign.faint
    val detail =
        when (val current = state) {
            is CameraSessionState.Connected -> "${current.identity.name} · PTP-IP"
            CameraSessionState.Connecting -> "Connecting…"
            CameraSessionState.Disconnected -> "No camera"
        }
    Row(
        modifier.background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(tint, CircleShape))
        Column(
            if (expanded) Modifier.weight(1f) else Modifier.widthIn(max = 180.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                if (linked) "Active Link" else "No Link",
                style = chromeStyle(12f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
            Text(
                detail,
                style = chromeStyle(10.5f, FontWeight.Medium, mono = true),
                color = LiveDesign.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // ponytail: bars are binary (4 or 0) until Android grows the iOS
        // linkHealth score; swap in the quartile mapping with it.
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
            repeat(4) { index ->
                Box(
                    Modifier.size(width = 3.dp, height = (6 + index * 3).dp)
                        .background(
                            if (linked) tint.copy(alpha = 0.52f + index * 0.12f)
                            else LiveDesign.hairline,
                            CircleShape,
                        )
                )
            }
        }
    }
}

/** Horizontal tab selector used when the landscape rail cannot fit. */
@Composable
private fun SettingsTabStrip(
    selected: OperatorSettingsTab,
    onSelect: (OperatorSettingsTab) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().glass(ChromeShape).padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        OperatorSettingsTab.entries.forEach { tab ->
            val active = tab == selected
            Column(
                Modifier.weight(1f)
                    .height(43.dp)
                    .background(
                        if (active) LiveDesign.surface else LiveDesign.surface.copy(alpha = 0f),
                        ChromeShape,
                    )
                    .settingsClickable(role = Role.Tab) { onSelect(tab) }
                    .padding(horizontal = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    tab.title,
                    style = chromeStyle(11.5f, FontWeight.SemiBold),
                    color = if (active) LiveDesign.text else LiveDesign.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Box(
                    Modifier.padding(top = 3.dp)
                        .size(width = 18.dp, height = 3.dp)
                        .background(
                            if (active) LiveDesign.accent else LiveDesign.accent.copy(alpha = 0f),
                            CircleShape,
                        )
                )
            }
        }
    }
}

/** Vertical tab rail, 146dp wide on full-height glass (iOS `settingsRail`). */
@Composable
private fun SettingsTabRail(selected: OperatorSettingsTab, onSelect: (OperatorSettingsTab) -> Unit) {
    Column(
        Modifier.width(146.dp).fillMaxHeight().glass(ChromeShape).padding(6.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        OperatorSettingsTab.entries.forEach { tab ->
            SettingsTabButton(tab, active = tab == selected, onClick = { onSelect(tab) })
        }
    }
}

/** One rail tab: accent capsule + title over subtitle (iOS `settingsTabButton`). */
@Composable
private fun SettingsTabButton(tab: OperatorSettingsTab, active: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .height(43.dp)
            .background(if (active) LiveDesign.surface else LiveDesign.surface.copy(alpha = 0f), ChromeShape)
            .settingsClickable(role = Role.Tab, onClick = onClick)
            .padding(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(width = 6.dp, height = 26.dp)
                .background(
                    if (active) LiveDesign.accent else LiveDesign.accent.copy(alpha = 0f),
                    CircleShape,
                )
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                tab.title,
                style = chromeStyle(13f, FontWeight.SemiBold),
                color = if (active) LiveDesign.text else LiveDesign.muted,
                maxLines = 1,
            )
            Text(
                tab.railSubtitle,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.faint,
                maxLines = 1,
            )
        }
    }
}

/** Rounded content pane: tab title/subtitle + pill header over scrolling rows. */
@Composable
private fun SettingsContentPane(
    tab: OperatorSettingsTab,
    settings: OperatorSettings,
    assistState: AssistState,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxSize()
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(
                    tab.title,
                    style = chromeStyle(24f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                Text(
                    tab.subtitle,
                    style = chromeStyle(12.5f, FontWeight.Normal),
                    color = LiveDesign.muted,
                    maxLines = 2,
                )
            }
            Spacer(Modifier.weight(1f))
            Text(
                tab.pill,
                color = LiveDesign.accent,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.6.sp,
                modifier =
                    Modifier.border(1.dp, LiveDesign.accentDim, CircleShape)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }
        // Fresh scroll position per tab. ponytail: iOS persists per-tab
        // offsets across panel dismissal; add if the rows ever grow that long.
        key(tab) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (tab) {
                    OperatorSettingsTab.ASSIST -> AssistRows(assistState)
                    OperatorSettingsTab.DISPLAY -> DisplayRows(settings, compact)
                    OperatorSettingsTab.SYSTEM -> SystemRows()
                }
            }
        }
    }
}

/**
 * View Assist tab. These switches are alternate controls for the monitor's
 * shared [AssistState], so changes immediately reach effects and scopes.
 */
@Composable
private fun AssistRows(assistState: AssistState) {
    SettingsRowCard {
        SettingsSwitchRow(
            "False Color",
            isOn = assistState.isOn(AssistTool.FALSE),
            showTopDivider = false,
        ) { assistState.toggle(AssistTool.FALSE) }
        SettingsSwitchRow("Zebra", isOn = assistState.isOn(AssistTool.ZEBRA)) {
            assistState.toggle(AssistTool.ZEBRA)
        }
        SettingsSwitchRow("Focus Peaking", isOn = assistState.isOn(AssistTool.PEAK)) {
            assistState.toggle(AssistTool.PEAK)
        }
        SettingsSwitchRow("Waveform", isOn = assistState.isOn(AssistTool.WAVE)) {
            assistState.toggle(AssistTool.WAVE)
        }
    }
}

/**
 * Display tab. Readout visibility persists but the monitor `InfoPill` does
 * not consume it yet — that wiring belongs to the shell task (the monitor
 * files are deliberately out of scope here; see [OperatorSettings]).
 */
@Composable
private fun DisplayRows(settings: OperatorSettings, compact: Boolean) {
    SettingsGroupCard(
        title = "Live Status Readouts",
        caption = "Hide readouts you do not ride during a take.",
    ) {
        if (compact) {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    DisplayToggleItem(
                        "REC",
                        isOn = settings.recReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { settings.recReadoutVisible.toggle() }
                    DisplayToggleItem(
                        "CODEC",
                        isOn = settings.codecReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { settings.codecReadoutVisible.toggle() }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    DisplayToggleItem(
                        "MEDIA",
                        isOn = settings.mediaReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { settings.mediaReadoutVisible.toggle() }
                    DisplayToggleItem(
                        "FPS",
                        isOn = settings.fpsReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { settings.fpsReadoutVisible.toggle() }
                }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                DisplayToggleItem(
                    "REC",
                    isOn = settings.recReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { settings.recReadoutVisible.toggle() }
                DisplayToggleItem(
                    "CODEC",
                    isOn = settings.codecReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { settings.codecReadoutVisible.toggle() }
                DisplayToggleItem(
                    "MEDIA",
                    isOn = settings.mediaReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { settings.mediaReadoutVisible.toggle() }
                DisplayToggleItem(
                    "FPS",
                    isOn = settings.fpsReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { settings.fpsReadoutVisible.toggle() }
            }
        }
    }
}

/** System tab — fully real: version, support, legal links, licenses (iOS `systemRows`). */
@Composable
private fun SystemRows() {
    val uriHandler = LocalUriHandler.current
    SettingsRowCard {
        SettingsInlineRow("Theme", showTopDivider = false) {
            SettingsValueText("Warm Dark")
        }
        SettingsInlineRow("Protocol Implementation") {
            SettingsValueText("PTP / PTP-IP")
        }
        SettingsInlineRow("App Version") {
            SettingsValueText(appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
        }
        SettingsInlineRow("Support") {
            SettingsLinkAction("Open") { uriHandler.openUri("https://openzcine.app/support/") }
        }
        SettingsInlineRow("Legal") {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SettingsQuietLink("Privacy") { uriHandler.openUri("https://openzcine.app/privacy") }
                SettingsQuietLink("Terms") { uriHandler.openUri("https://openzcine.app/terms") }
            }
        }
        SettingsInlineRow("Open-Source Licenses") {
            SettingsValueText("Third-Party Notices")
        }
    }
}
