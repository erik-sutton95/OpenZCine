package com.opencapture.openzcine

import android.content.Intent
import android.os.SystemClock
import androidx.compose.runtime.Recomposer
import androidx.compose.ui.platform.InfiniteAnimationPolicy
import androidx.compose.ui.platform.compositionContext
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.fail

/**
 * A4-25/A4-26: the window paces infinite animations, and a recreated activity (a configuration
 * change the manifest does not declare, such as a locale change) keeps the live session instead of
 * disconnecting it and composing a new one.
 */
@RunWith(AndroidJUnit4::class)
class MonitorRootRecreationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun theWindowRecomposerPacesInfiniteAnimations() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val recomposer = activity.window.decorView.compositionContext as? Recomposer
                assertNotNull(recomposer?.effectCoroutineContext?.get(InfiniteAnimationPolicy), "a paced window recomposer")
            }
        }
    }

    @Test fun recreationKeepsTheLiveSession() {
        val demo = Intent(instrumentation.targetContext, MainActivity::class.java).putExtra("zc.demo.feed", true)
        ActivityScenario.launch<MainActivity>(demo).use { scenario ->
            lateinit var first: CameraSession
            scenario.onActivity { first = assertNotNull(liveSession(it)) }
            scenario.recreate()
            SystemClock.sleep(1_000) // the old composition's teardown has run
            scenario.onActivity { assertSame(first, liveSession(it), "the recreated activity shows the same session") }
            assertIs<CameraSessionState.Connected>(first.state.value, "the session stayed connected")
        }
    }

    /** The monitor's session in the retained root; reflective, so the test also reports on an activity without one. */
    private fun liveSession(activity: MainActivity): CameraSession? {
        val root =
            runCatching { MainActivity::class.java.getDeclaredField("root").apply { isAccessible = true }.get(activity) }
                .getOrElse { fail("MainActivity keeps no activity-retained root ($it)") }
        return root!!.javaClass.getMethod("getMonitorSession").invoke(root) as CameraSession?
    }
}
