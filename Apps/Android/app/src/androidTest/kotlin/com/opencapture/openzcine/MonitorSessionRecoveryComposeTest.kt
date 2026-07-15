package com.opencapture.openzcine

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.ReconnectBackoff
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MonitorSessionRecoveryComposeTest {
    @get:Rule val composeRule = createComposeRule()

    @Test
    fun recoveryFollowsLifecyclePermissionAndCompositionOwnership() {
        val lifecycleOwner = ManualLifecycleOwner()
        val session = ComposeRecoverySession()
        val enabled = mutableStateOf(true)
        val mounted = mutableStateOf(true)
        composeRule.setContent {
            CompositionLocalProvider(LocalLifecycleOwner provides lifecycleOwner) {
                if (mounted.value) {
                    MonitorSessionRecoveryEffect(
                        session = session,
                        enabled = enabled.value,
                        retryPolicy = ReconnectBackoff(0L, 0L, jitterFraction = 0.0),
                    )
                }
            }
        }

        composeRule.runOnIdle { lifecycleOwner.moveTo(Lifecycle.State.STARTED) }
        composeRule.waitUntil(CONDITION_TIMEOUT_MILLIS) { session.connectCount == 1 }

        composeRule.runOnIdle { session.loseConnection() }
        composeRule.waitUntil(CONDITION_TIMEOUT_MILLIS) { session.connectCount == 2 }

        composeRule.runOnIdle { lifecycleOwner.moveTo(Lifecycle.State.CREATED) }
        composeRule.waitForIdle()
        composeRule.runOnIdle { session.loseConnection() }
        composeRule.waitForIdle()
        composeRule.runOnIdle { assertEquals(2, session.connectCount) }

        composeRule.runOnIdle { lifecycleOwner.moveTo(Lifecycle.State.STARTED) }
        composeRule.waitUntil(CONDITION_TIMEOUT_MILLIS) { session.connectCount == 3 }

        composeRule.runOnIdle { enabled.value = false }
        composeRule.waitForIdle()
        composeRule.runOnIdle { session.loseConnection() }
        composeRule.waitForIdle()
        composeRule.runOnIdle { assertEquals(3, session.connectCount) }

        composeRule.runOnIdle {
            enabled.value = true
            session.restoreConnection()
        }
        composeRule.waitForIdle()
        composeRule.runOnIdle { mounted.value = false }
        composeRule.waitForIdle()
        composeRule.runOnIdle { session.loseConnection() }
        composeRule.waitForIdle()
        composeRule.runOnIdle { assertEquals(3, session.connectCount) }
    }

    private class ManualLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this)

        override val lifecycle: Lifecycle = registry

        fun moveTo(state: Lifecycle.State) {
            registry.currentState = state
        }
    }

    private class ComposeRecoverySession : CameraSession {
        private val mutableState =
            MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
        override val state: StateFlow<CameraSessionState> = mutableState
        override val recordingState: StateFlow<CameraRecordingState> =
            MutableStateFlow(CameraRecordingState.STANDBY)

        @Volatile var connectCount: Int = 0
            private set

        override suspend fun connect() {
            connectCount += 1
            restoreConnection()
        }

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() {
            loseConnection()
        }

        fun loseConnection() {
            mutableState.value = CameraSessionState.Disconnected
        }

        fun restoreConnection() {
            mutableState.value =
                CameraSessionState.Connected(
                    CameraIdentity("Recovery camera", "NIKON ZR", "COMPOSE-RECOVERY"),
                )
        }
    }

    private companion object {
        const val CONDITION_TIMEOUT_MILLIS = 5_000L
    }
}
