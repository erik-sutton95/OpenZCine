package com.opencapture.openzcine

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.AppShell
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.CamerasScreen
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.OperatorConsent
import com.opencapture.opencine.appkit.OperatorConsentRequest
import com.opencapture.opencine.appkit.PairScreen
import com.opencapture.opencine.appkit.SavedCamerasStore
import com.opencapture.opencine.appkit.ShellActions
import com.opencapture.opencine.appkit.ShellBrand
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.StoredString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED decisions over the actual public shared screens (Swift
 * `StandaloneConsentPresentationTests`). The models have no integrations, so nothing can dial.
 */
@RunWith(AndroidJUnit4::class)
class OperatorConsentPresentationComposeTest {
    @get:Rule val compose = createComposeRule()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var answers = 0
    private var cancels = 0

    @After fun end() = scope.cancel()

    @Test fun standaloneCamerasScreenAnswersAndCancels() {
        val cameras = cameras()
        compose.setContent { CamerasScreen(cameras, "SIMULATED", onPair = {}, onMedia = {}, onSettings = {}) }
        answerThenCancel(cameras.consent)
    }

    @Test fun standalonePairScreenAnswersAndCancels() {
        val cameras = cameras()
        compose.setContent { PairScreen(cameras, onDone = {}, onDiagnostics = {}, onReportProblem = {}) }
        answerThenCancel(cameras.consent)
    }

    @Test fun aScreenUnderItsOwnShellAddsNoSecondDialog() {
        val cameras = cameras()
        compose.setContent {
            AppShell(
                shell(cameras), ShellBrand("SIMULATED"), ShellActions(diagnostics = {}, reportProblem = {}),
                monitor = {}, page = {},
                prePage = { CamerasScreen(cameras, "SIMULATED", onPair = {}, onMedia = {}, onSettings = {}) },
            )
        }
        answerThenCancel(cameras.consent)
    }

    @Test fun anotherOwnersShellNeitherSuppressesNorLosesItsDecisionWhenTheChildLeaves() {
        val parent = cameras()
        val child = cameras()
        var showsChild by mutableStateOf(true)
        compose.setContent {
            AppShell(
                shell(parent), ShellBrand("SIMULATED"), ShellActions(diagnostics = {}, reportProblem = {}),
                monitor = {}, page = {},
                prePage = {
                    if (showsChild) CamerasScreen(child, "SIMULATED", onPair = {}, onMedia = {}, onSettings = {})
                },
            )
        }
        answerThenCancel(child.consent)
        compose.runOnIdle { present(parent.consent, "Parent decision") }
        compose.onAllNodesWithText("Parent decision").assertCountEquals(1)
        compose.runOnIdle { showsChild = false }
        compose.waitForIdle()
        compose.onAllNodesWithText("Parent decision").assertCountEquals(1)
        compose.onNodeWithText(CONFIRM).performClick()
        compose.waitForIdle()
        assertEquals(2, answers)
        compose.onAllNodesWithText("Parent decision").assertCountEquals(0)
    }

    @Test fun aReplacedDecisionCannotAnswerForItsSuccessor() {
        val cameras = cameras()
        var stale = 0
        compose.setContent { CamerasScreen(cameras, "SIMULATED", onPair = {}, onMedia = {}, onSettings = {}) }
        compose.runOnIdle {
            cameras.consent.present(
                OperatorConsentRequest("Earlier decision", "SIMULATED", CONFIRM, DECLINE, onConfirm = { stale += 1 }, onCancel = { stale += 1 }),
                source = "review",
            )
            present(cameras.consent)
        }
        compose.onAllNodesWithText("Earlier decision").assertCountEquals(0)
        compose.onAllNodesWithText(TITLE).assertCountEquals(1)
        compose.onNodeWithText(CONFIRM).performClick()
        compose.waitForIdle()
        assertEquals(1, answers)
        assertEquals(0, stale)
    }

    private fun answerThenCancel(owner: OperatorConsent) {
        val answered = answers
        compose.runOnIdle { present(owner) }
        compose.onAllNodesWithText(TITLE).assertCountEquals(1)
        compose.onAllNodesWithText(CONFIRM).assertCountEquals(1)
        compose.onNodeWithText(CONFIRM).performClick()
        compose.waitForIdle()
        assertEquals(answered + 1, answers)
        compose.onAllNodesWithText(TITLE).assertCountEquals(0)
        val cancelled = cancels
        compose.runOnIdle { present(owner) }
        compose.onAllNodesWithText(TITLE).assertCountEquals(1)
        compose.onNodeWithText(DECLINE).performClick()
        compose.waitForIdle()
        assertEquals(cancelled + 1, cancels)
        assertEquals(answered + 1, answers)
        compose.onAllNodesWithText(TITLE).assertCountEquals(0)
    }

    private fun present(owner: OperatorConsent, title: String = TITLE) {
        owner.present(
            OperatorConsentRequest(title, "No camera commands are connected.", CONFIRM, DECLINE, onConfirm = { answers += 1 }, onCancel = { cancels += 1 }),
            source = "review",
        )
    }

    private fun cameras(): CamerasModel {
        val document = object : StoredString {
            var value: String? = null
            override fun read(): String? = value
            override fun write(value: String) { this.value = value }
        }
        return CamerasModel(emptyList(), SavedCamerasStore(document), scope)
    }

    private fun shell(cameras: CamerasModel) = ShellModel(cameras, MonitorControlModel(scope))

    private companion object {
        const val TITLE = "SIMULATED decision"
        const val CONFIRM = "Confirm SIMULATED"
        const val DECLINE = "Decline SIMULATED"
    }
}
