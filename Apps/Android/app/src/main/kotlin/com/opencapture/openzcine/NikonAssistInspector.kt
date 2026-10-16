package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.LUTPicker
import com.opencapture.opencine.cameracontrols.LUTSplitComparisonBar
import com.opencapture.opencine.cameracontrols.LutPickerEntry
import com.opencapture.opencine.cameracontrols.LutPickerLibrary
import com.opencapture.opencine.cameracontrols.MonitorLutCategory
import com.opencapture.opencine.cameracontrols.LutPickerLayout
import com.opencapture.opencine.cameracontrols.LutPickerFilter
import com.opencapture.opencine.cameracontrols.LutPickerEmpty
import com.opencapture.opencine.cameracontrols.LutPickerAction
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.reconciledLutSelectionAfterDeletion
import kotlinx.coroutines.launch

/** A palette chip: a shared assist, or PLAY (photography's instant review, this camera's own). */
internal sealed interface NikonAssistChip {
    val id: String

    data class Tool(val tool: MonitorAssistTool) : NikonAssistChip {
        override val id: String get() = tool.name
    }

    data object InstantReview : NikonAssistChip {
        override val id: String get() = "PLAY"
    }
}

/** The live palette for this camera's capabilities: the cinema set, or PLAY plus the photo toolset. */
internal fun nikonLiveAssistChips(photography: Boolean, imageEffects: Boolean): List<NikonAssistChip> {
    val tools =
        MonitorAssistTool.settingsCases.filter {
            it != MonitorAssistTool.ND && (imageEffects || !it.isImageEffect) &&
                if (photography) it.appliesToPhotography else !it.isPhotographyOnly
        }.map(NikonAssistChip::Tool)
    return if (photography) listOf(NikonAssistChip.InstantReview) + tools else tools
}

/** The shared playback set (no camera level or EV needle); this camera has no ND source. */
internal fun nikonPlaybackAssistTools(imageEffects: Boolean): List<MonitorAssistTool> =
    MonitorAssistTool.playbackToolbarCases.filter {
        it != MonitorAssistTool.ND && (imageEffects || !it.isImageEffect)
    }

/** The camera level has a style; camera meters carry no operator-tunable options. */
internal val MonitorAssistTool.nikonHasOptions: Boolean
    get() = this !in setOf(MonitorAssistTool.EV, MonitorAssistTool.AUDIO, MonitorAssistTool.ND)

/** The approved palette defaults, with the between-shots PLAY and EV leading the photo toolset. */
internal val nikonUsageSeed =
    mapOf(
        "PLAY" to 8, "EV" to 7, "PEAK" to 6, "FALSE" to 5, "ZEBRA" to 4, "LUT" to 4, "WAVE" to 3,
        "GUIDES" to 2, "GRID" to 2, "HISTO" to 2, "VECTOR" to 1, "PARADE" to 1, "LIGHTS" to 1,
        "CROSS" to 1, "MIRROR" to 1, "AUDIO" to 1,
    )

/** Output-space filter supplied as a value to the shared catalogue. */
private enum class RedOutputSpaceFilter(val label: String, val needle: String?) {
    ALL("All", null), REC709("Rec.709", "REC709"), REC2020("Rec.2020", "REC2020"),
}

/** Nikon supplies catalogue values/actions; the shared picker owns tabs, rows and confirmation. */
@Composable
internal fun NikonLutOptions(
    assists: NikonAssists,
    lutLibrary: AndroidLutLibrary?,
    onOpenRedDownload: () -> Unit,
    onRequestLutImport: (() -> Unit)?,
    includesComparison: Boolean = true,
) {
    val shared = assists.shared
    val stored = lutLibrary?.entries?.collectAsState()?.value.orEmpty()
    val scope = rememberCoroutineScope()
    var feedback by remember { mutableStateOf<String?>(null) }
    var filter by remember { mutableStateOf(RedOutputSpaceFilter.ALL) }
    val selected = assists.lut
    val builtIn = FeedLut.entries.map { LutPickerEntry(it.name, it.label) }
    fun storedEntry(entry: com.opencapture.openzcine.lut.StoredLutEntry) = LutPickerEntry(
        entry.selection.fileName,
        if (entry.selection.category == StoredLutCategory.RED) shortRedPresetName(entry.selection.fileName)
        else entry.displayName,
    )
    fun apply(entry: com.opencapture.openzcine.lut.StoredLutEntry) {
        val library = lutLibrary ?: return
        scope.launch {
            if (library.prepare(entry.selection)) {
                assists.selectLut(FeedLutSelection.Stored(entry.selection))
                feedback = null
            } else feedback = library.failures.value[entry.selection]?.operatorMessage
                ?: "This LUT could not be prepared."
        }
    }
    fun library(category: MonitorLutCategory): LutPickerLibrary {
        val all = stored.filter { it.selection.category == category }
        val filtered = if (category == StoredLutCategory.RED) all.filter {
            filter.needle == null || it.selection.fileName.uppercase().contains(filter.needle!!)
        } else all
        val preferred = if (category == StoredLutCategory.RED) defaultRedLutEntry(all) else all.firstOrNull()
        val entries = if (preferred != null && preferred in filtered)
            listOf(preferred) + filtered.filterNot { it == preferred } else filtered
        val active = (selected as? FeedLutSelection.Stored)?.value?.takeIf { it.category == category }
        return LutPickerLibrary(
            title = if (category == StoredLutCategory.RED) "RED" else "Custom",
            entries = entries.map(::storedEntry), isCurrent = active != null,
            selectedId = active?.fileName,
            representative = preferred?.takeIf { it in filtered }?.let(::storedEntry)
                ?: entries.firstOrNull()?.let(::storedEntry),
            layout = if (category == StoredLutCategory.CUSTOM) LutPickerLayout.FILES else LutPickerLayout.DRUM,
            filter = if (category == StoredLutCategory.RED && all.isNotEmpty()) LutPickerFilter(
                RedOutputSpaceFilter.entries.map { it.label }, filter.label,
                onSelect = { label ->
                    filter = RedOutputSpaceFilter.entries.first { it.label == label }
                    val visible = all.filter {
                        filter.needle == null || it.selection.fileName.uppercase().contains(filter.needle!!)
                    }
                    if (active != null && visible.none { it.selection == active })
                        visible.firstOrNull()?.let(::apply)
                },
            ) else null,
            markedIds = if (category == StoredLutCategory.RED) setOfNotNull(preferred?.selection?.fileName) else emptySet(),
            empty = if (category == StoredLutCategory.RED) LutPickerEmpty(
                "RED IPP2 LUTs", "Download RED's official looks. You'll accept RED's terms.",
                LutPickerAction("Download from RED", onOpenRedDownload),
            ) else LutPickerEmpty("No custom LUTs yet", "Import a .cube file to add your own look."),
            onSelect = { choice -> entries.firstOrNull { it.selection.fileName == choice.id }?.let(::apply) },
            onDelete = { choice ->
                val entry = all.firstOrNull { it.selection.fileName == choice.id }
                val owner = lutLibrary
                if (entry != null && owner != null) scope.launch {
                    if (owner.delete(entry.selection)) {
                        if (assists.lut == FeedLutSelection.Stored(entry.selection))
                            assists.selectLut(reconciledLutSelectionAfterDeletion(
                                assists.lut, entry.selection, owner.firstPreparedReplacement(entry.selection),
                            ))
                        feedback = "${entry.displayName} deleted."
                    } else feedback = "This LUT could not be deleted."
                }
            },
            onImport = if (category == StoredLutCategory.CUSTOM) onRequestLutImport else null,
        )
    }
    val active = (selected as? FeedLutSelection.BuiltIn)?.value
    LUTPicker(
        libraries = listOf(
            LutPickerLibrary("Built-in", builtIn, active != null, active?.name,
                onSelect = { entry ->
                    assists.selectLut(FeedLutSelection.BuiltIn(FeedLut.valueOf(entry.id)))
                    feedback = null
                }, representative = builtIn.firstOrNull(), caption = active?.credit.orEmpty()),
            library(StoredLutCategory.RED), library(StoredLutCategory.CUSTOM),
        ), embedded = !includesComparison, message = feedback,
        footer = if (includesComparison) ({
            LUTSplitComparisonBar(shared.splitComparison, shared.splitVertical,
                lutExposureStops = null,
                onToggleSplit = { shared.setSplitComparison(!shared.splitComparison) },
                onSplitVertical = { shared.setSplitComparison(true, it) })
        }) else null,
    )
}

/** iOS `LUTLibraryIndex.defaultRedLUT` preference order (file-name heuristics). */
private fun defaultRedLutEntry(
    entries: List<com.opencapture.openzcine.lut.StoredLutEntry>,
): com.opencapture.openzcine.lut.StoredLutEntry? {
    if (entries.isEmpty()) return null
    fun score(fileName: String): Int {
        val upper = fileName.uppercase()
        var s = 0
        if (upper.contains("REC709") || upper.contains("REC_709")) s += 4
        if (upper.contains("MEDIUM")) s += 2
        if (upper.contains("SOFT") || upper.contains("ROLLOFF")) s += 1
        if (upper.contains("CONTRAST")) s += 1
        return s
    }
    return entries.maxByOrNull { score(it.selection.fileName) }
}

/** iOS `RedPresetName.short`: strip N-Log/IPP2 noise for the drum. */
private fun shortRedPresetName(fileName: String): String {
    var name = fileName.removeSuffix(".cube").removeSuffix(".CUBE")
    name =
        name
            .replace(Regex("(?i)N[-_]?Log[_-]?"), "")
            .replace(Regex("(?i)IPP2[_-]?"), "")
            .replace('_', ' ')
            .replace(Regex("\\s+"), " ")
            .trim()
    return name.ifBlank { fileName }
}
