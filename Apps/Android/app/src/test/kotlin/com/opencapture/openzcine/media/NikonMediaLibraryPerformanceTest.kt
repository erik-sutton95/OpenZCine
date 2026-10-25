package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * SIMULATED 3200-object Nikon card (1500 NEF+JPEG pairs, 200 clips) in 32-object pages. Field
 * report 2026-10-25: a large card stalled the gallery and select/share/delete for long periods.
 */
class NikonMediaLibraryPerformanceTest {
    private class Preferences : MediaLibraryPreferences {
        private val values = mutableMapOf<String, String>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
    }

    private val clips: List<NikonMediaClipRecord> = buildList {
        for (index in 0 until 1500) {
            val stem = "DSC_%04d".format(index + 1)
            for ((suffix, handle) in listOf("NEF" to 1L, "JPG" to 2L)) add(NikonMediaClipRecord(
                handle = index * 4L + handle, storageId = 65_537, sizeBytes = 24_000_000,
                captureDate = "20261025T%02d%02d00".format(index / 60 % 24, index % 60), pixelWidth = 6048, pixelHeight = 4032,
                filename = "$stem.$suffix", contentKind = NikonMediaContentKind.STILL_PHOTO, stillPhoto = null))
        }
        for (index in 0 until 200) add(NikonMediaClipRecord(handle = 100_000L + index, storageId = 65_537, sizeBytes = 900_000_000,
            captureDate = "20261025T120000", pixelWidth = 3840, pixelHeight = 2160, filename = "DSC_%04d.MOV".format(1501 + index),
            contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null))
    }

    @Test fun deletionAndActionChecksDecodeTheIndexOnce() {
        val root = createTempDirectory("SIMULATED-nikon-perf")
        try {
            val index = MediaLibraryIndex(Preferences())
            index.rememberCameraListing("SIMULATED", clips)
            val cache = MediaCacheStore(root)
            val codec = NikonMediaLibraryCodec("SIMULATED", null, cache, { emptySet() }, { false })
            val actions = NikonMediaLibraryActions(index, cache, { null }, { codec })
            val selection = clips.take(300).map { NikonLibraryClip("SIMULATED", it) }
            val started = System.nanoTime()
            val capture = actions.capture(selection)
            var current = true
            repeat(5) { current = current && capture.sourceIsCurrent }
            val millis = (System.nanoTime() - started) / 1_000_000
            println("MEDIA-PERF-ANDROID z.capture300.checks5.ms: $millis")
            assertTrue(current)
            assertTrue(millis < 300, "capturing 300 clips and 5 deletion checks took $millis ms")
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun aListingPageMapsOnlyItsOwnRows() {
        val root = createTempDirectory("SIMULATED-nikon-perf")
        try {
            val codec = NikonMediaLibraryCodec("SIMULATED", null, MediaCacheStore(root), { emptySet() }, { false })
            var existing = emptyList<MonitorMediaRecord<NikonLibraryClip>>()
            val pages = clips.map { NikonLibraryClip("SIMULATED", it) }.chunked(32)
            pages.forEachIndexed { page, rows ->
                val capture = codec.assembleCatalog(existing, rows, emptyList(), reset = page == 0, complete = page == pages.lastIndex)
                // Apply as the shared owner does: removals, upserts, surviving amendments, order.
                val values = LinkedHashMap(existing.associateBy { it.asset.id })
                capture.removed.forEach(values::remove)
                capture.upserts.forEach { values[it.asset.id] = it }
                capture.amendments.forEach { if (it.asset.id in values) values[it.asset.id] = it }
                existing = (capture.order.orEmpty() + values.keys).distinct().mapNotNull(values::get)
            }
            println("MEDIA-PERF-ANDROID z.listing.recordMappings: ${codec.recordMappings} for ${clips.size} rows")
            assertEquals(clips.size, existing.size)
            assertTrue(codec.recordMappings <= clips.size * 2,
                "listing ${clips.size} rows mapped ${codec.recordMappings} records")
        } finally { root.toFile().deleteRecursively() }
    }
}
