package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraPropertySnapshotWire
import com.opencapture.opencine.nikon.NikonDescriptorForm
import com.opencapture.opencine.nikon.NikonDescriptorOptionOrigin
import com.opencapture.opencine.nikon.NikonDescriptorReadOutcome
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SupportStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** SIMULATED app projections, not hardware admission. */
class GroupedStabilizationTest {
    @Test fun `last valid parsed read-only survives completed negative and early aborted generations`() {
        for (latest in listOf("rejected", "malformed", "notAttempted")) {
            val payload = listOf(
                "result\taccepted", "codec\tH.265", "vibrationReduction\tON", "electronicVr\tOFF",
                "options.vibrationReduction\tOFF\u001FON\u001FSPORT", "options.electronicVr\tOFF\u001FON",
                "descriptor.vibrationReduction.outcome\t$latest",
                "descriptor.vibrationReduction.support\tunknown",
                "descriptor.vibrationReduction.latestOutcome\t$latest",
                "descriptor.vibrationReduction.origin\tlegacyFallback",
                "descriptor.vibrationReduction.lastValidOutcome\tdescribed",
                "descriptor.vibrationReduction.lastValidSupport\tsupported",
                "descriptor.vibrationReduction.lastValidAccess\treadOnly",
                "descriptor.vibrationReduction.lastValidForm\tenumeration",
                "descriptor.vibrationReduction.lastValidChoices\tSPORT",
            ).joinToString("\n")
            val decoded = CameraPropertySnapshotWire.decode(payload)
            assertTrue(decoded.isValid)
            val host = group(decoded.snapshot)
            assertEquals(listOf("OFF", "ON", "SPORT"), host.rows[0].options)
            assertNull(host.rows[0].request)
            assertNotNull(host.rows[1].request)
        }
    }

    @Test fun `decoded read-only descriptor facts reach actual grouped host and withhold requests`() {
        val payload = """
            result	accepted
            codec	H.265
            vibrationReduction	ON
            electronicVr	OFF
            options.vibrationReduction	SPORT${'\u001F'}OFF${'\u001F'}ON
            options.electronicVr	OFF${'\u001F'}ON
            descriptor.vibrationReduction.outcome	described
            descriptor.vibrationReduction.support	supported
            descriptor.vibrationReduction.access	readOnly
            descriptor.vibrationReduction.form	enumeration
            descriptor.vibrationReduction.choices${'\t'}
            descriptor.vibrationReduction.origin	legacyFallback
            descriptor.vibrationReduction.operation	getDevicePropDesc
            descriptor.vibrationReduction.response	8193
            descriptor.vibrationReduction.latestOutcome	mediaBusy
            descriptor.electronicVr.outcome	described
            descriptor.electronicVr.support	supported
            descriptor.electronicVr.access	readWrite
            descriptor.electronicVr.form	enumeration
            descriptor.electronicVr.choices	ON${'\u001F'}OFF
            descriptor.electronicVr.origin	descriptor
            descriptor.electronicVr.latestOutcome	described
            descriptor.electronicVr.latestSupport	supported
            descriptor.electronicVr.latestAccess	readOnly
            descriptor.electronicVr.latestForm	enumeration
            descriptor.electronicVr.latestChoices${'\t'}
            descriptor.electronicVr.latestOperation	getDevicePropDescEx
            descriptor.electronicVr.latestResponse	8193
        """.trimIndent()
        val decoded = CameraPropertySnapshotWire.decode(payload)
        assertTrue(decoded.isValid)
        val presentation = dashboard(decoded.snapshot)
        val host = presentation.stabilization
        assertNull(presentation.panelTiles.single { it.kind == CommandTileKind.STABILIZATION }.request)
        assertTrue(host.rows.all { it.request == null })
        assertTrue(host.rows.all { it.unavailableReason != null })
        assertEquals(group(snapshot()).rows.map { it.options }, host.rows.map { it.options })
        assertEquals(listOf("ON", "OFF"), host.rows.map { it.current })
        assertEquals(setOf(CameraControl.VIBRATION_REDUCTION, CameraControl.ELECTRONIC_VR), host.descriptors.keys)
        val vr = host.descriptors.getValue(CameraControl.VIBRATION_REDUCTION)
        assertEquals(NikonDescriptorReadOutcome.DESCRIBED, vr.observation.outcome)
        assertEquals(SettingAccess.READ_ONLY, vr.observation.capability.access)
        assertEquals(emptyList(), vr.observation.capability.offer)
        assertEquals(NikonDescriptorForm.ENUMERATION, vr.observation.form)
        assertEquals(NikonDescriptorOptionOrigin.LEGACY_FALLBACK, vr.optionOrigin)
        assertEquals("getDevicePropDesc", vr.observation.operation)
        assertEquals(8193, vr.observation.response)
        assertEquals(NikonDescriptorReadOutcome.MEDIA_BUSY, vr.latestAttempt.outcome)
        assertEquals(SupportStatus.UNKNOWN, vr.latestAttempt.capability.support)
        assertNull(vr.latestAttempt.capability.offer)
        val evr = host.descriptors.getValue(CameraControl.ELECTRONIC_VR)
        assertEquals(listOf("ON", "OFF"), evr.observation.capability.offer)
        assertEquals(NikonDescriptorOptionOrigin.DESCRIPTOR, evr.optionOrigin)
        assertEquals(NikonDescriptorReadOutcome.DESCRIBED, evr.latestAttempt.outcome)
        assertEquals(SettingAccess.READ_ONLY, evr.latestAttempt.capability.access)
        assertEquals(emptyList(), evr.latestAttempt.capability.offer)
        assertEquals("getDevicePropDescEx", evr.latestAttempt.operation)
        assertEquals(8193, evr.latestAttempt.response)
        assertEquals(listOf("OFF", "ON"), host.rows[1].options)
        for (codec in listOf(null, "", "N-RAW")) {
            val gated = dashboard(decoded.snapshot.copy(codec = codec)).stabilization
            assertTrue(gated.rows.all { it.request == null })
            assertEquals(host.rows.map { it.options }, gated.rows.map { it.options })
            assertEquals(evr, gated.descriptors.getValue(CameraControl.ELECTRONIC_VR))
        }
    }

    @Test fun `latest actual described access supersedes retained access but failed attempts retain it`() {
        val base = "result\taccepted\ncodec\tH.265\nvibrationReduction\tON\nelectronicVr\tOFF" +
            "\noptions.vibrationReduction\tSPORT\u001FOFF\u001FON\noptions.electronicVr\tOFF\u001FON"
        val cases = listOf(
            Triple("readOnly", "readWrite", true),
            Triple("readWrite", "readOnly", false),
            Triple("readOnly", null, false),
            Triple("futureAccess", null, true),
        )
        for ((retainedAccess, latestAccess, offered) in cases) {
            val fields = listOf(
                "descriptor.vibrationReduction.outcome\tdescribed",
                "descriptor.vibrationReduction.support\tsupported",
                "descriptor.vibrationReduction.access\t$retainedAccess",
                "descriptor.vibrationReduction.form\tenumeration",
                "descriptor.vibrationReduction.choices\tON",
                "descriptor.vibrationReduction.origin\tlegacyFallback",
                "descriptor.vibrationReduction.latestOutcome\t${if (latestAccess == null) "transportFailed" else "described"}",
            ) + if (latestAccess == null) emptyList() else listOf(
                "descriptor.vibrationReduction.latestSupport\tsupported",
                "descriptor.vibrationReduction.latestAccess\t$latestAccess",
                "descriptor.vibrationReduction.latestForm\tenumeration",
                "descriptor.vibrationReduction.latestChoices\tSPORT\u001FOFF\u001FON",
            )
            val decoded = CameraPropertySnapshotWire.decode(base + "\n" + fields.joinToString("\n"))
            assertTrue(decoded.isValid)
            val rows = dashboard(decoded.snapshot).stabilization.rows
            assertEquals(offered, rows[0].request != null)
            assertEquals(listOf("SPORT", "OFF", "ON"), rows[0].options)
            assertEquals("ON", rows[0].current)
            assertNotNull(rows[1].request)
        }
        // A describe refusal is not a failed setting write and cannot invalidate a legacy domain.
        val rejected = CameraPropertySnapshotWire.decode(base + "\n" + listOf(
            "descriptor.vibrationReduction.outcome\trejected",
            "descriptor.vibrationReduction.support\tunknown",
            "descriptor.vibrationReduction.operation\tgetDevicePropDescEx",
            "descriptor.vibrationReduction.response\t8202",
            "descriptor.vibrationReduction.origin\tlegacyFallback",
            "descriptor.vibrationReduction.latestOutcome\trejected",
        ).joinToString("\n"))
        val host = group(rejected.snapshot)
        assertNotNull(host.rows[0].request)
        val evidence = host.descriptors.getValue(CameraControl.VIBRATION_REDUCTION)
        assertEquals(NikonDescriptorReadOutcome.REJECTED, evidence.observation.outcome)
        assertEquals(SupportStatus.UNKNOWN, evidence.observation.capability.support)
        assertEquals(8202, evidence.observation.response)
    }

    @Test fun `actual source codec refusal cannot be bypassed by stale known display selection`() {
        // Native projected() uses recognizedCurrentCodec(actual fileType) and emits no e-VR
        // options for these inputs. A stale codecSelection is display content, never that domain.
        for (actual in listOf(null, "future codec", "N-RAW", "R3D NE")) {
            val payload = listOfNotNull(
                "result\taccepted", actual?.let { "codec\t$it" }, "codecSelection\tH.265",
                "vibrationReduction\tON", "electronicVr\tOFF",
                "options.vibrationReduction\tSPORT\u001FOFF\u001FON", "options.electronicVr\t",
            ).joinToString("\n")
            val decoded = CameraPropertySnapshotWire.decode(payload)
            assertTrue(decoded.isValid)
            val rows = group(decoded.snapshot).rows
            assertNotNull(rows[0].request)
            assertNull(rows[1].request)
            assertEquals("OFF", rows[1].current)
            assertTrue(rows[1].options.isEmpty())
            assertNotNull(rows[1].unavailableReason)
        }
    }

    @Test fun `old and future descriptor payloads remain unknown in grouped host`() {
        val legacy = "result\taccepted\ncodec\tH.265\nvibrationReduction\tON\nelectronicVr\tOFF" +
            "\noptions.vibrationReduction\tSPORT\u001FOFF\u001FON\noptions.electronicVr\tOFF\u001FON"
        val future = legacy + """
            descriptor.vibrationReduction.outcome	futureOutcome
            descriptor.vibrationReduction.support	supported
            descriptor.vibrationReduction.access	futureAccess
            descriptor.vibrationReduction.origin	futureOrigin
            descriptor.vibrationReduction.latestOutcome	futureOutcome
        """.trimIndent().let { "\n$it" }
        for (payload in listOf(legacy, future)) {
            val decoded = CameraPropertySnapshotWire.decode(payload)
            assertTrue(decoded.isValid)
            val host = group(decoded.snapshot)
            assertEquals(group(snapshot()).rows, host.rows)
            val vr = host.descriptors.getValue(CameraControl.VIBRATION_REDUCTION)
            assertEquals(NikonDescriptorReadOutcome.UNKNOWN, vr.observation.outcome)
            assertEquals(NikonDescriptorReadOutcome.UNKNOWN, vr.latestAttempt.outcome)
            assertEquals(SupportStatus.UNKNOWN, vr.observation.capability.support)
            assertEquals(NikonDescriptorOptionOrigin.UNKNOWN, vr.optionOrigin)
            assertNull(vr.observation.capability.offer)
        }
    }

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
