package com.opencapture.openzcine

import android.content.Context
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.printToString
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MultiviewStagePreferencesStore
import com.opencapture.opencine.appkit.MultiviewStageLayout
import com.opencapture.opencine.appkit.enqueueAdd
import com.opencapture.opencine.appkit.pickerRows
import com.opencapture.opencine.appkit.recordPlan
import com.opencapture.opencine.core.StationHostPath
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlException
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.openzcine.multiview.ZCineMemberTransport
import com.opencapture.openzcine.multiview.ZCineMultiview
import com.opencapture.openzcine.multiview.ZCineMultiviewEnvironment
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * SIMULATED bodies inside the actual MainActivity: the shared Multiview stage over scripted Nikon
 * member transports, its borrowed monitor and its retained composition. Physical Nikon behavior is
 * untested.
 */
@RunWith(AndroidJUnit4::class)
class MultiviewRoundTripMainActivityTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    /** This phone on a router's Wi-Fi. */
    private object PhoneOnWiFi : StationHostPath {
        override fun address(hotspot: Boolean): String? = if (hotspot) null else "192.168.1.10"
        override fun netmask(hotspot: Boolean): String? = if (hotspot) null else "255.255.255.0"
        override suspend fun join(network: StationNetwork): String? = null
    }

    private fun root(): AppRoot =
        MainActivity::class.java.getDeclaredField("root").apply { isAccessible = true }.get(compose.activity) as AppRoot

    /** A frame every 100 ms carrying [jpeg] (empty: header only). */
    private fun frames(jpeg: ByteArray = ByteArray(0)): Flow<LiveFrame> = flow {
        while (true) {
            emit(LiveFrame(System.nanoTime(), jpeg))
            delay(100)
        }
    }

    /** The scripted network: one body per host, all of them seen by the passive pass. */
    private fun scripted(bodies: Map<String, CameraSession>, jpeg: ByteArray = ByteArray(0)) = ZCineMultiviewEnvironment(
        connect = { host -> ZCineMemberTransport(bodies[host] ?: error("Nothing answered"), frames(jpeg)) },
        currentHolder = { null },
        sightings = { _, _, excluded ->
            bodies.keys.filter { it !in excluded }.map { NikonSighting(it, "SIMULATED", NikonSighting.Source.NETWORK) }
        },
        saved = { emptyList() },
        hostPath = PhoneOnWiFi,
        presentationStore = MultiviewStagePreferencesStore(
            compose.activity.applicationContext.getSharedPreferences(ZCineMultiview.PRESENTATION_PREFERENCES, Context.MODE_PRIVATE),
            ZCineMultiview.PRESENTATION_KEY,
        ),
    )

    /** Opens the actual stage over [bodies] and adds each one to its own tile, in order. */
    private fun openStage(root: AppRoot, bodies: Map<String, CameraSession>, jpeg: ByteArray = ByteArray(0)): ZCineMultiview {
        lateinit var stage: ZCineMultiview
        compose.runOnIdle { stage = root.openMultiview(scripted(bodies, jpeg)) }
        compose.waitUntil(5_000) { stage.coordinator.pickerRows().size == bodies.size }
        compose.runOnIdle {
            stage.coordinator.pickerRows().forEachIndexed { slot, row -> assertTrue(stage.coordinator.enqueueAdd(row.id, slot)) }
        }
        compose.waitUntil(10_000) { bodies.keys.indices.all { stage.coordinator.members[it].publishing } }
        return stage
    }

    @Test fun borrowedMonitorKeepsTheActualStageAndPresentationWithoutCameraCommands() {
        val saved = PreferencesSnapshot(compose.activity.applicationContext, ZCineMultiview.PRESENTATION_PREFERENCES)
        val session = CountedSession(FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "multiview-round-trip")))
        runBlocking { session.connect() }
        val root = root()
        try {
            val stage = openStage(root, mapOf("192.168.1.20" to session))
            compose.runOnIdle {
                stage.coordinator.presentation.apply {
                    layout = MultiviewStageLayout.GRID
                    selected = 0
                    fill = true
                    clean = false
                    toolsExpanded = true
                }
            }
            val original = compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id
            compose.onNodeWithContentDescription("Select camera A", substring = true, useUnmergedTree = true)
                .performTouchInput { doubleClick() }
            try {
                compose.waitUntil(5_000) {
                    compose.onAllNodes(hasContentDescription("Return to Multiview"), useUnmergedTree = true)
                        .fetchSemanticsNodes().isNotEmpty()
                }
            } catch (timeout: ComposeTimeoutException) {
                val state = runCatching {
                    buildString {
                        appendLine("monitorSession=${root.monitorSession != null}")
                        appendLine("lentSlot=${stage.lentSlot}")
                        appendLine(compose.onRoot(useUnmergedTree = true).printToString())
                    }
                }.getOrElse { "state capture failed: ${it.message}" }
                println("SIMULATED multiview readiness failure\n$state")
                throw timeout
            }
            compose.runOnIdle { assertSame(session, root.monitorSession, "the monitor shows the member's own session") }
            compose.onNodeWithContentDescription("Return to Multiview", useUnmergedTree = true).performClick()
            compose.waitUntil(5_000) { root.monitorSession == null && stage.lentSlot == null }
            val returned = compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id
            assertEquals(original, returned, "The actual native stage composition must survive Live View")
            compose.runOnIdle {
                assertSame(session, stage.links[0].transport?.session)
                assertEquals(MultiviewStageLayout.GRID, stage.coordinator.presentation.layout)
                assertEquals(true, stage.coordinator.presentation.fill)
                assertEquals(true, stage.coordinator.presentation.toolsExpanded)
                assertNull(root.monitorSession)
                assertEquals(0, session.commands)
                assertEquals(0, session.disconnects)
                root.closeMultiview()
            }
        } finally { saved.restore() }
    }

    @Test fun hiddenStageRetiresGroupConfirmationWithUnchangedRecordContext() {
        val saved = PreferencesSnapshot(compose.activity.applicationContext, ZCineMultiview.PRESENTATION_PREFERENCES)
        val fake = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "hidden-confirmation"))
        val cover = FakeCameraSession(CameraIdentity("SIMULATED cover", "SIMULATED", "cover-only"))
        runBlocking { fake.connect(); fake.setRecording(false); cover.connect() }
        val session = CountedSession(fake)
        val root = root()
        try {
            val stage = openStage(root, mapOf("192.168.1.21" to session))
            val original = compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id
            compose.waitUntil(5_000) { stage.coordinator.recordPlan(null).isExecutable }
            compose.onNodeWithTag("multiview.recordAll").performClick()
            compose.onNodeWithText("Start recording?").assertIsDisplayed()
            val oldStart = assertNotNull(compose.onNodeWithText("Start").fetchSemanticsNode()
                .config[SemanticsActions.OnClick].action)
            // Retain the exact app callback installed on the actual rendered button. The
            // semantics wrapper plays a sound first and refuses detached nodes before calling
            // the app. This second receipt reaches the app's approval-token guard directly.
            val oldAppStart = originalButtonCallback(oldStart)
            fun replayRetiredStart() {
                try { oldStart() } catch (error: IllegalStateException) {
                    // Compose itself refuses an event whose actual modifier node was detached.
                    // A different failure remains a test failure; no camera command is permitted.
                    assertEquals("Cannot read CompositionLocal because the Modifier node is not currently attached.",
                        error.message)
                }
            }
            // Cover the actual retained stage with a monitor that is not its loan.
            compose.runOnIdle { root.monitorSession = cover }
            compose.waitForIdle()
            compose.onNodeWithText("Start recording?").assertDoesNotExist()
            compose.runOnIdle {
                replayRetiredStart()
                oldAppStart()
                assertEquals(0, session.commands)
                root.monitorSession = null
            }
            compose.waitForIdle()
            compose.onNodeWithText("Start recording?").assertDoesNotExist()
            compose.runOnIdle { replayRetiredStart(); oldAppStart(); assertEquals(0, session.commands) }
            assertEquals(original, compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id)
            compose.runOnIdle {
                assertSame(session, stage.links[0].transport?.session)
                assertEquals(0, session.commands)
            }
            compose.onNodeWithTag("multiview.recordAll").performClick()
            compose.onNodeWithText("Start recording?").assertIsDisplayed()
            compose.runOnIdle { replayRetiredStart(); oldAppStart(); assertEquals(0, session.commands) }
            compose.onNodeWithText("Start recording?").assertIsDisplayed()
            compose.onNodeWithText("Cancel").performClick()
            compose.runOnIdle {
                assertEquals(0, session.commands)
                root.closeMultiview()
            }
        } finally { saved.restore() }
    }

    @Test fun actualMultiviewSettingsRouteOnlyToSelectedMember() {
        val saved = PreferencesSnapshot(compose.activity.applicationContext, ZCineMultiview.PRESENTATION_PREFERENCES)
        val fakeA = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED-A", "settings-A"))
        val fakeB = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED-B", "settings-B"))
        runBlocking {
            fakeA.connect(); fakeB.connect()
            fakeA.applyControl(CameraControl.ISO, "400")
        }
        val first = CountedSession(fakeA)
        val second = CountedSession(fakeB)
        val root = root()
        try {
            val stage = openStage(root, linkedMapOf("192.168.1.30" to first, "192.168.1.31" to second))
            compose.runOnIdle { stage.coordinator.presentation.toolsExpanded = true }
            compose.onNodeWithTag("multiview.recordAll").assertIsDisplayed()
            compose.onNodeWithTag("multiview.settings").assertIsDisplayed().performClick()
            compose.onNodeWithTag("multiview.settings.panel").assertIsDisplayed()
            compose.waitUntil(5_000) {
                compose.onAllNodes(androidx.compose.ui.test.hasTestTag("multiview.settings.iso")).fetchSemanticsNodes().isNotEmpty()
            }
            val oldISO = assertNotNull(compose.onNodeWithTag("multiview.settings.iso")
                .fetchSemanticsNode().config[SemanticsActions.SetProgress].action)
            compose.runOnIdle { oldISO(4f) }
            compose.waitUntil(5_000) { first.writes == listOf(CameraControl.ISO to "500") }
            compose.runOnIdle { assertTrue(second.writes.isEmpty()) }
            compose.onNodeWithTag("multiview.settings.camera.1").performClick()
            compose.onNodeWithTag("multiview.settings.iso").assertIsDisplayed()
            val drained = AtomicBoolean(false)
            compose.runOnIdle {
                oldISO(5f)
                root.scope.launch { delay(250); drained.set(true) }
            }
            compose.waitUntil(5_000) { drained.get() }
            compose.runOnIdle {
                assertEquals(listOf(CameraControl.ISO to "500"), first.writes)
                assertTrue(second.writes.isEmpty())
            }
            compose.onNodeWithTag("monitor.capture.close").performClick()
            compose.onNodeWithTag("multiview.settings.panel").assertDoesNotExist()
            compose.runOnIdle { assertEquals(0, first.recordCommands + second.recordCommands); root.closeMultiview() }
        } finally { saved.restore() }
    }

    /** SIMULATED N-Log members: the Auto LUT grades each tile's own picture, and the LUT tool turns it off. */
    @Test fun actualMultiviewLutToolGradesEachMembersOwnPicture() {
        assumeTrue("Native looks need API 33 and the staged Swift core",
            com.opencapture.openzcine.multicam.multicamLookRendererFactory(null) != null)
        val saved = PreferencesSnapshot(compose.activity.applicationContext, ZCineMultiview.PRESENTATION_PREFERENCES)
        val sessions = listOf("lut-A", "lut-B").map { serial ->
            CountedSession(FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", serial)).also { runBlocking { it.connect() } }, tone = "N-Log")
        }
        val red = android.graphics.Bitmap.createBitmap(64, 64, android.graphics.Bitmap.Config.ARGB_8888)
            .apply { eraseColor(android.graphics.Color.rgb(220, 30, 30)) }
        val jpeg = ByteArrayOutputStream().also { red.compress(android.graphics.Bitmap.CompressFormat.JPEG, 100, it) }.toByteArray()
        val root = root()
        fun isRaw(color: Int) = kotlin.math.abs(android.graphics.Color.red(color) - 220) <= 8 &&
            kotlin.math.abs(android.graphics.Color.green(color) - 30) <= 8 &&
            kotlin.math.abs(android.graphics.Color.blue(color) - 30) <= 8
        try {
            val stage = openStage(root, linkedMapOf("192.168.1.40" to sessions[0], "192.168.1.41" to sessions[1]), jpeg)
            fun tilePixel(slot: Int): Int? {
                var color: Int? = null
                compose.runOnIdle { color = stage.picture(slot)?.asAndroidBitmap()?.getPixel(32, 32) }
                return color
            }
            compose.runOnIdle { stage.coordinator.presentation.toolsExpanded = true }
            compose.onNodeWithTag("multicam.tile.picture.0", useUnmergedTree = true).assertExists()
            // Auto LUT starts on and follows each body's N-Log.
            compose.waitUntil(10_000) { (0..1).all { slot -> tilePixel(slot)?.let { !isRaw(it) } == true } }
            compose.onNodeWithTag("multiview.lut").assertIsDisplayed().performClick()
            compose.waitUntil(10_000) { (0..1).all { slot -> tilePixel(slot)?.let(::isRaw) == true } }
            compose.onNodeWithTag("multiview.lut").performClick()
            compose.waitUntil(10_000) { (0..1).all { slot -> tilePixel(slot)?.let { !isRaw(it) } == true } }
            compose.runOnIdle {
                assertEquals(0, sessions.sumOf { it.commands })
                root.closeMultiview()
            }
        } finally { saved.restore() }
    }

    @Suppress("UNCHECKED_CAST")
    private fun originalButtonCallback(semanticsAction: () -> Boolean): () -> Unit {
        val node = semanticsAction.javaClass.declaredFields.firstNotNullOfOrNull { field ->
            field.isAccessible = true
            field.get(semanticsAction)?.takeIf { captured ->
                generateSequence(captured.javaClass as Class<*>?) { it.superclass }
                    .any { it.name == "androidx.compose.foundation.AbstractClickableNode" }
            }
        }
        val actualNode = assertNotNull(node, "Actual rendered semantics action must retain its click node")
        val owner = generateSequence(actualNode.javaClass as Class<*>?) { it.superclass }
            .first { it.name == "androidx.compose.foundation.AbstractClickableNode" }
        val callbackField = owner.getDeclaredField("onClick").apply { isAccessible = true }
        assertEquals("kotlin.jvm.functions.Function0", callbackField.type.name, "Pinned Compose callback shape changed")
        val callback = callbackField.get(actualNode)
        return assertNotNull(callback as? (() -> Unit), "Actual button must hold its original app callback")
    }

    /** Counts what reaches the body; [tone] stands in for the codec tone the body reports. */
    private class CountedSession(private val delegate: CameraSession, tone: String? = null) : CameraSession by delegate {
        var commands = 0
        var recordCommands = 0
        val writes = mutableListOf<Pair<CameraControl, String>>()
        var disconnects = 0
        private val toned: StateFlow<CameraPropertySnapshot>? =
            tone?.let { MutableStateFlow(delegate.cameraProperties.value.copy(movieTone = it)) }
        override val cameraProperties: StateFlow<CameraPropertySnapshot> get() = toned ?: delegate.cameraProperties
        override val reportedCameraProperties: StateFlow<CameraPropertySnapshot>
            get() = toned ?: delegate.reportedCameraProperties
        override suspend fun setRecording(recording: Boolean) { commands++; recordCommands++; delegate.setRecording(recording) }
        override suspend fun applyControl(control: CameraControl, label: String) { commands++; writes += control to label; delegate.applyControl(control, label) }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) {
            if (!admission.admits(this)) throw CameraControlException.CommandRejected
            applyControl(control, label)
        }
        override suspend fun disconnect() { disconnects++; delegate.disconnect() }
    }
}
