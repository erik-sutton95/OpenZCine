package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** SIMULATED app projections, not hardware admission. */
class GroupedStabilizationTest {
    private fun dashboard(snapshot: CameraPropertySnapshot) = commandDashboardPresentation(
        snapshot, CameraPropertyRefreshStatus.Ready,
        CameraSessionState.Connected(CameraIdentity("SIMULATED", "SIMULATED", "group")),
        CommandTileKind.entries.toList(),
    )

    private fun snapshot(codec: String? = "H.265", vr: String? = "ON", evr: String? = "OFF",
        vrOptions: List<String> = listOf("SPORT", "OFF", "ON"),
        evrOptions: List<String> = listOf("OFF", "ON")) = CameraPropertySnapshot(
        codec = codec, vibrationReduction = vr, electronicVr = evr,
        controlCapabilities = CameraControlCapabilities(vibrationReduction = vrOptions, electronicVr = evrOptions),
    )

    private fun group(snapshot: CameraPropertySnapshot): CommandStabilizationRequest =
        assertIs(dashboard(snapshot).panelTiles.single { it.kind == CommandTileKind.STABILIZATION }.request)

    @Test fun `one visible tile carries two distinct exact writes`() {
        val presentation = dashboard(snapshot())
        assertEquals(1, presentation.panelTiles.count { it.kind == CommandTileKind.STABILIZATION })
        assertEquals(0, presentation.panelTiles.count { it.kind == CommandTileKind.ELECTRONIC_VR })
        assertEquals("ON / OFF", presentation.panelTiles.single { it.kind == CommandTileKind.STABILIZATION }.value)
        val rows = group(snapshot()).rows
        assertEquals(listOf(CameraControl.VIBRATION_REDUCTION, CameraControl.ELECTRONIC_VR), rows.map { it.id })
        assertEquals(listOf("ON", "OFF"), rows.map { it.current })
        assertEquals(listOf("SPORT", "OFF", "ON"), rows[0].options)
        val sent = mutableListOf<Pair<CameraControl, String>>()
        rows[0].select("SPORT", true, { true }, { request, label -> sent += request.control to label }, { _, _ -> error("Unexpected refusal") })
        assertEquals(listOf(CameraControl.VIBRATION_REDUCTION to "SPORT"), sent)
        rows[1].select("ON", true, { true }, { request, label -> sent += request.control to label }, { _, _ -> error("Unexpected refusal") })
        assertEquals(listOf(CameraControl.VIBRATION_REDUCTION to "SPORT", CameraControl.ELECTRONIC_VR to "ON"), sent)
    }

    @Test fun `either admitted row opens with unavailable companion observation intact`() {
        val movieUnavailable = group(snapshot(vrOptions = emptyList())).rows
        assertEquals("ON", movieUnavailable[0].current)
        assertNull(movieUnavailable[0].request)
        assertNotNull(movieUnavailable[0].unavailableReason)
        assertNotNull(movieUnavailable[1].request)
        val electronicUnavailable = group(snapshot(evrOptions = emptyList())).rows
        assertEquals("OFF", electronicUnavailable[1].current)
        assertNull(electronicUnavailable[1].request)
        assertNotNull(electronicUnavailable[0].request)
        val neither = dashboard(snapshot(vrOptions = emptyList(), evrOptions = emptyList()))
        assertNull(neither.panelTiles.single { it.kind == CommandTileKind.STABILIZATION }.request)
    }

    @Test fun `single control routes retain their existing typed projections`() {
        val presentation = dashboard(snapshot().copy(iso = 800, exposureMode = "M"))
        for (tile in presentation.tiles.filter { it.kind != CommandTileKind.STABILIZATION }) {
            assertEquals(tile.request, presentation.panelTiles.single { it.kind == tile.kind }.request)
        }
        assertEquals(presentation.sections.flatMap { it.cells }.map { it.request },
            presentation.panelSections.flatMap { it.cells }.map { it.request })
    }

    @Test fun `RAW nil blank and empty observations retain existing separate admission`() {
        for (codec in listOf(null, "", " ", "N-RAW", "R3D NE", "ProRes RAW HQ")) {
            val rows = group(snapshot(codec = codec)).rows
            assertNotNull(rows[0].request)
            assertEquals("OFF", rows[1].current)
            assertNull(rows[1].request)
            assertEquals("Electronic VR is unavailable for this camera or active codec.", rows[1].unavailableReason)
        }
        for (unknown in listOf(null, "", " ")) {
            val rows = group(snapshot(vr = unknown)).rows
            assertNull(rows[0].current)
            assertNull(rows[0].request)
            assertEquals(listOf("SPORT", "OFF", "ON"), rows[0].options)
            assertNotNull(rows[1].request)
        }
        for (observation in listOf("unrecognized", UNAVAILABLE_MONITOR_VALUE)) {
            val unlisted = group(snapshot(vr = observation)).rows[0]
            assertEquals(observation, unlisted.current)
            assertNotNull(unlisted.request)
        }
    }

    @Test fun `visible reorder preserves hidden slot and old payload without load migration`() {
        val key = "display.commandGrid.order.v1"
        for (position in listOf(0, 3, 8)) {
            val full = mutableListOf(CommandTileKind.MODE, CommandTileKind.ISO, CommandTileKind.SHUTTER,
                CommandTileKind.IRIS, CommandTileKind.WHITE_BALANCE, CommandTileKind.RESOLUTION_FRAMERATE,
                CommandTileKind.CODEC, CommandTileKind.STABILIZATION)
            full.add(position, CommandTileKind.ELECTRONIC_VR)
            val payload = full.joinToString(",") { it.name } + ",ISO,RETIRED"
            val storage = TestSharedPreferences()
            storage.edit().putString(key, payload).apply()
            val store = commandTileOrderStore(storage)
            assertEquals(full, store.load())
            assertEquals(payload, storage.getString(key, null))
            val moved = moveCommandTile(store.load(), CommandTileKind.STABILIZATION, 1)
            assertEquals(CommandTileKind.ELECTRONIC_VR, moved[position])
            assertEquals(listOf(CommandTileKind.MODE, CommandTileKind.STABILIZATION, CommandTileKind.ISO,
                CommandTileKind.SHUTTER, CommandTileKind.IRIS, CommandTileKind.WHITE_BALANCE,
                CommandTileKind.RESOLUTION_FRAMERATE, CommandTileKind.CODEC), visibleCommandTileOrder(moved))
            store.save(moved)
            assertEquals(moved, store.load())
            assertEquals(moved.joinToString(",") { it.name }, storage.getString(key, null))
            assertEquals(moved, moveCommandTile(moved, CommandTileKind.ELECTRONIC_VR, 0))
        }
    }
}
