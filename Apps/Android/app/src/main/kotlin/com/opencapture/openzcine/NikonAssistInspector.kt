package com.opencapture.openzcine

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.cameracontrols.LUTPicker
import com.opencapture.opencine.cameracontrols.LutPickerAction
import com.opencapture.opencine.cameracontrols.LutPickerEmpty
import com.opencapture.opencine.cameracontrols.LutPickerEntry
import com.opencapture.opencine.cameracontrols.LutPickerFilter
import com.opencapture.opencine.cameracontrols.LutPickerLayout
import com.opencapture.opencine.cameracontrols.LutPickerLibrary
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutEntry
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

@Composable
private fun OptionCopy(message: String) {
    Text(message, style = chromeStyle(11f, FontWeight.Normal), color = LiveDesign.muted, maxLines = 3,
        overflow = TextOverflow.Ellipsis)
}

/** iOS `NikonLUTPicker.RedOutputFilter`: one output space of the RED list (raw file tokens). */
internal enum class RedOutputSpaceFilter(val label: String, val needle: String?) {
    ALL("All", null),
    REC709("Rec.709", "REC709"),
    REC2020("Rec.2020", "REC2020"),
}

/**
 * Built-in, RED and Custom as the shared picker's libraries (iOS `NikonLUTPicker.libraries`):
 * RED is a library value with its output-space filter, starred default and download action;
 * imported cubes use the shared file list.
 */
internal fun nikonLutLibraries(
    applied: FeedLutSelection,
    stored: List<StoredLutEntry>,
    redFilter: RedOutputSpaceFilter,
    onRedFilter: (RedOutputSpaceFilter) -> Unit,
    onBuiltIn: (FeedLut) -> Unit,
    onStored: (StoredLutEntry) -> Unit,
    onDelete: ((StoredLutEntry) -> Unit)?,
    onImport: (() -> Unit)?,
    onOpenRedDownload: () -> Unit,
): List<LutPickerLibrary> {
    val builtIn = (applied as? FeedLutSelection.BuiltIn)?.value
    val appliedStored = (applied as? FeedLutSelection.Stored)?.value
    fun builtInEntry(lut: FeedLut) = LutPickerEntry(lut.id, lut.label)
    fun storedIn(category: StoredLutCategory) = stored.filter { it.selection.category == category }
    fun appliedIn(category: StoredLutCategory) = appliedStored?.takeIf { it.category == category }?.fileName
    val allRed = storedIn(StoredLutCategory.RED)
    val red = filteredRedLutEntries(allRed, redFilter)
    val defaultRed = defaultRedLutEntry(allRed)
    fun redEntry(entry: StoredLutEntry) =
        LutPickerEntry(entry.selection.fileName, shortRedPresetName(entry.selection.fileName))
    val custom = storedIn(StoredLutCategory.CUSTOM)
    fun customEntry(entry: StoredLutEntry) = LutPickerEntry(entry.selection.fileName, entry.displayName)
    fun pick(entries: List<StoredLutEntry>): (LutPickerEntry) -> Unit =
        { look -> entries.firstOrNull { it.selection.fileName == look.id }?.let(onStored) }
    fun delete(entries: List<StoredLutEntry>): ((LutPickerEntry) -> Unit)? =
        onDelete?.let { delete -> { look -> entries.firstOrNull { it.selection.fileName == look.id }?.let(delete) } }
    return listOf(
        LutPickerLibrary(
            title = "Built-in", entries = FeedLut.entries.map(::builtInEntry),
            isCurrent = builtIn != null, selectedId = builtIn?.id,
            onSelect = { look -> FeedLut.entries.firstOrNull { it.id == look.id }?.let(onBuiltIn) },
            representative = builtInEntry(FeedLut.LOG3G10_709),
            // Community-contributed looks are credited here, not in the narrow drum row.
            caption = builtIn?.credit.orEmpty(),
        ),
        LutPickerLibrary(
            title = "RED", entries = red.map(::redEntry),
            isCurrent = appliedIn(StoredLutCategory.RED) != null,
            selectedId = appliedIn(StoredLutCategory.RED)?.takeIf { id -> red.any { it.selection.fileName == id } },
            onSelect = pick(allRed),
            representative = defaultRed?.let(::redEntry),
            filter = if (allRed.isEmpty()) null else LutPickerFilter(
                RedOutputSpaceFilter.entries.map { it.label }, redFilter.label,
            ) { label -> RedOutputSpaceFilter.entries.firstOrNull { it.label == label }?.let(onRedFilter) },
            markedIds = setOfNotNull(defaultRed?.selection?.fileName),
            empty = LutPickerEmpty(
                "RED IPP2 LUTs", "Download RED's official looks. You'll accept RED's terms.",
                // Always tappable: the download screen explains a blocked route.
                LutPickerAction("Download from RED", onOpenRedDownload),
            ),
            onDelete = delete(allRed),
        ),
        LutPickerLibrary(
            title = "Custom", entries = custom.map(::customEntry), layout = LutPickerLayout.FILES,
            isCurrent = appliedIn(StoredLutCategory.CUSTOM) != null,
            selectedId = appliedIn(StoredLutCategory.CUSTOM),
            onSelect = pick(custom),
            representative = custom.firstOrNull()?.let(::customEntry),
            empty = LutPickerEmpty(hint = "Import a .cube file to add your own look."),
            onDelete = delete(custom), onImport = onImport,
        ),
    )
}

/** The RED looks in one output space, the recommended default first so the drum lands on it. */
internal fun filteredRedLutEntries(red: List<StoredLutEntry>, filter: RedOutputSpaceFilter): List<StoredLutEntry> {
    val visible = filter.needle?.let { needle -> red.filter { it.selection.fileName.uppercase().contains(needle) } } ?: red
    val default = defaultRedLutEntry(red)?.takeIf { it in visible } ?: return visible
    return listOf(default) + (visible - default)
}

/**
 * The shared LUT picker on Nikon's looks (iOS `NikonLUTPicker`). The inspector footer pins the
 * comparison; a stored look applies once its cube is prepared, and a failure reads under it.
 */
@Composable
internal fun NikonLutOptions(
    assists: NikonAssists,
    lutLibrary: AndroidLutLibrary?,
    onOpenRedDownload: () -> Unit,
    onRequestLutImport: (() -> Unit)?,
) {
    val storedEntries = lutLibrary?.entries?.collectAsState()?.value.orEmpty()
    val scope = rememberCoroutineScope()
    var feedback by remember { mutableStateOf<String?>(null) }
    var redFilter by remember { mutableStateOf(RedOutputSpaceFilter.ALL) }
    val applyStored: (StoredLutEntry) -> Unit = { entry ->
        val library = lutLibrary
        if (library != null && assists.lut != FeedLutSelection.Stored(entry.selection)) {
            scope.launch {
                if (library.prepare(entry.selection)) {
                    assists.selectLut(FeedLutSelection.Stored(entry.selection))
                    feedback = null
                } else {
                    feedback =
                        library.failures.value[entry.selection]?.operatorMessage
                            ?: "This LUT could not be prepared."
                }
            }
        }
    }
    val deleteStored: ((StoredLutEntry) -> Unit)? = lutLibrary?.let { library ->
        { entry ->
            scope.launch {
                if (library.delete(entry.selection)) {
                    if (assists.lut == FeedLutSelection.Stored(entry.selection)) {
                        // iOS: keep LUT tool on; same-category replacement else Log3G10→709.
                        assists.selectLut(
                            reconciledLutSelectionAfterDeletion(
                                assists.lut, entry.selection, library.firstPreparedReplacement(entry.selection),
                            ),
                        )
                    }
                    feedback = "${entry.displayName} deleted."
                } else {
                    feedback = "This LUT could not be deleted."
                }
            }
        }
    }
    val libraries =
        nikonLutLibraries(
            applied = assists.lut, stored = storedEntries, redFilter = redFilter,
            onRedFilter = { next ->
                redFilter = next
                // iOS: the applied RED look stays on the visible drum; one outside the new filter
                // snaps to the filter's first look.
                val red = storedEntries.filter { it.selection.category == StoredLutCategory.RED }
                val visible = filteredRedLutEntries(red, next)
                val applied = (assists.lut as? FeedLutSelection.Stored)?.value
                if (applied?.category == StoredLutCategory.RED && visible.none { it.selection == applied }) {
                    visible.firstOrNull()?.let(applyStored)
                }
            },
            onBuiltIn = { lut ->
                if (assists.lut != FeedLutSelection.BuiltIn(lut)) {
                    assists.selectLut(FeedLutSelection.BuiltIn(lut))
                    feedback = null
                }
            },
            onStored = applyStored,
            onDelete = deleteStored,
            onImport = onRequestLutImport,
            onOpenRedDownload = onOpenRedDownload,
        )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        LUTPicker(libraries, embedded = true)
        feedback?.let { message -> OptionCopy(message) }
    }
}

/** iOS `LUTLibraryIndex.defaultRedLUT` preference order (file-name heuristics). */
private fun defaultRedLutEntry(entries: List<StoredLutEntry>): StoredLutEntry? {
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
