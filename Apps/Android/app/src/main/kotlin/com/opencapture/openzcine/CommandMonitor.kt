package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The DISP 3 command dashboard (iOS `CommandMonitor`, ios/Runner/
 * MonitorPanels.swift): record chip + hero timecode, the health strip, and
 * the primary control-tile grid. The feed is unmounted in this mode — the
 * dashboard fills the deck span between the side rails (landscape) or the
 * controls-grid zone (portrait, timecode band + grid split by the caller).
 *
 * v1 renders read-only tiles from the demo session state; tap-to-open pickers
 * and long-press-drag reorder arrive with the picker chrome. The iOS
 * Image/Focus/Audio side column is deferred with them.
 */
@Composable
fun CommandDashboard(recording: Boolean, frameCount: Long, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RecordChip(recording)
            CommandTimecode(frameCount, sizeSp = 44f)
        }
        CommandHealthStrip()
        CommandGrid(Modifier.fillMaxWidth().weight(1f))
    }
}

/** Hero timecode with the accent frame field (iOS `CommandTimecodeReadout`). */
@Composable
fun CommandTimecode(frameCount: Long, sizeSp: Float, modifier: Modifier = Modifier) {
    Text(
        timecodeAnnotated(frameCount, DemoMonitorState.FRAME_RATE),
        style = chromeStyle(sizeSp, FontWeight.Normal, mono = true),
        maxLines = 1,
        modifier = modifier,
    )
}

/** Temp / Storage / Camera / Lens blocks + the FPS chip (iOS `CommandHealthStrip`). */
@Composable
private fun CommandHealthStrip() {
    Row(
        Modifier
            .fillMaxWidth()
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommandStatusBlock("Temp", "OK · 41°C", valueColor = LiveDesign.good)
        CommandStatusBlock("Storage", DemoMonitorState.MEDIA)
        CommandStatusBlock("Camera", "NIKON ZR")
        CommandStatusBlock("Lens", "NIKKOR Z 24-70")
        Box(Modifier.weight(1f))
        FpsChip(DemoMonitorState.SIGNAL_BARS, DemoMonitorState.FPS)
    }
}

@Composable
private fun CommandStatusBlock(label: String, value: String, valueColor: androidx.compose.ui.graphics.Color = LiveDesign.text) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label.uppercase(), style = chromeStyle(8.5f, FontWeight.Bold), color = LiveDesign.faint)
        Text(
            value,
            style = chromeStyle(12f, FontWeight.Medium, mono = true),
            color = valueColor,
            maxLines = 1,
        )
    }
}

/** Title/value pairs for the eight primary tiles, from the demo session state. */
private fun commandTiles(): List<Pair<String, String>> {
    fun demoValue(label: String): String =
        DemoMonitorState.VALUES.firstOrNull { it.first == label }?.second ?: "—"
    return listOf(
        "Mode" to "M",
        "ISO" to demoValue("ISO"),
        "Shutter" to demoValue("SHUTTER"),
        "Iris" to demoValue("IRIS"),
        "White Bal" to demoValue("WB"),
        "Resolution Framerate" to DemoMonitorState.RESOLUTION,
        "Codec" to DemoMonitorState.CODEC,
        "VR / e-VR" to "—",
    )
}

/**
 * The 3-column primary tile grid (iOS `CommandPrimaryGrid`). Shared by the
 * landscape DISP 3 dashboard and the portrait fit-mode/command controls zone.
 * Rows split the available height evenly, floored at 44dp.
 */
@Composable
fun CommandGrid(modifier: Modifier = Modifier) {
    val tiles = commandTiles()
    val columns = 3
    val spacing = 9.dp
    val rows = (tiles.size + columns - 1) / columns
    BoxWithConstraints(modifier) {
        val rowHeight = maxOf(44.dp, (maxHeight - spacing * (rows - 1)) / rows)
        Column(verticalArrangement = Arrangement.spacedBy(spacing)) {
            tiles.chunked(columns).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(spacing)) {
                    row.forEach { (title, value) ->
                        CommandTile(title, value, Modifier.weight(1f).height(rowHeight))
                    }
                    repeat(columns - row.size) { Box(Modifier.weight(1f)) }
                }
            }
        }
    }
}

/** One read-only control tile (iOS `CommandTile`). */
@Composable
private fun CommandTile(title: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            title.uppercase(),
            style = chromeStyle(10f, FontWeight.Bold),
            color = LiveDesign.faint,
            maxLines = 1,
        )
        Text(
            value,
            style = chromeStyle(24f, FontWeight.Medium, mono = true),
            color = LiveDesign.text,
            maxLines = 1,
        )
    }
}
