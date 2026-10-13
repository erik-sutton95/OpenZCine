package com.opencapture.openzcine.gyro

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class GyroMountOptionTest {
    @Test fun `catalog preserves core descriptions and omitted groups`() {
        val option = option("unconfigured", "XYZ")
        val mounted = option("testMount", "YxZ").put("group", "Screen toward you")
        val values = decodeGyroMountPresets(JSONArray(listOf(option, mounted)).toString())
        assertNull(values.first().group)
        assertEquals("Screen toward you", values.last().group)
        assertEquals("YxZ", values.last().orientation)
        assertEquals("Test mount detail", values.last().detail)
    }

    @Test fun `invalid catalog is rejected before presenting options`() {
        val unconfigured = option("unconfigured", "XYZ")
        assertTrue(runCatching { decodeGyroMountPresets("[]") }.isFailure)
        assertTrue(runCatching {
            decodeGyroMountPresets(JSONArray(listOf(unconfigured, unconfigured)).toString())
        }.isFailure)
        assertTrue(runCatching {
            decodeGyroMountPresets(JSONArray(listOf(unconfigured.put("detail", ""))).toString())
        }.isFailure)
    }

    @Test fun `legacy logs remain unconfigured and each log uses its stored mount`() {
        val legacy = GyroLogEntry(JSONObject().put("id", "legacy"), null, File("legacy.gcsv"))
        val mounted = GyroLogEntry(JSONObject().put("id", "mounted").put("mountPreset", "rearLeft"),
            null, File("mounted.gcsv"))
        assertEquals("unconfigured", legacy.mountPreset)
        assertEquals("rearLeft", mounted.mountPreset)
    }

    @Test fun `stored log description survives restrictions on current selectable mounts`() {
        val unconfigured = GyroMountOption("unconfigured", "Unconfigured", null, "Unconfigured",
            "Set alignment in Gyroflow", "XYZ")
        val stored = GyroMountOption("rearLeft", "Landscape", "Screen toward you", "USB-C left",
            "USB-C left · screen toward you", "xyZ")
        val state = GyroCaptureState(mountOptions = listOf(unconfigured),
            mountCatalog = listOf(unconfigured, stored).associateBy { it.id })
        val entry = GyroLogEntry(JSONObject().put("id", "stored").put("mountPreset", stored.id),
            null, File("stored.gcsv"))
        assertEquals(stored.detail, entry.mountDetail(state.mountCatalog))
        assertEquals(listOf("unconfigured"), state.mountOptions.map { it.id })
        val unknown = entry.copy(descriptor = JSONObject().put("id", "unknown").put("mountPreset", "removed"))
        assertEquals(unconfigured.detail, unknown.mountDetail(state.mountCatalog))
    }

    private fun option(id: String, orientation: String): JSONObject = JSONObject().put("id", id)
        .put("title", "Test mount").put("shortLabel", "Test").put("detail", "Test mount detail")
        .put("orientation", orientation)
}
