package com.opencapture.openzcine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.compose.runtime.remember
import com.opencapture.opencine.appkitnative.MonitorCacheOwnerComposeDriver
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.runtime.MonitorFeedEffectsCacheOwnerNativeProof
import com.opencapture.openzcine.bridge.SwiftCore
import org.junit.Before
import org.junit.Test
import kotlin.test.assertTrue
import org.junit.runner.RunWith

/** Actual app packer/profile/private factory bindings to the shared SIMULATED native proof. */
@RunWith(AndroidJUnit4::class)
class FeedEffectsCacheOwnerNativeTest {
    @Before fun loadTheActualStagedLibrary() {
        assertTrue(SwiftCore.isAvailable, "The actual staged Swift library must load before its JNI calls")
    }
    private val proof get() = MonitorFeedEffectsCacheOwnerNativeProof(object : MonitorFeedEffectsCacheOwnerNativeProof.Binding {
        override val context get() = InstrumentationRegistry.getInstrumentation().targetContext
        override fun nativeVersion(): String = SwiftCore.coreVersion()
        override fun packedCube(seed: Int) = SwiftCore.bakeMonitorFalseColorCube(1, 1, (180 + seed).toFloat())
        override val vectorOrdinals = 0..7
        override fun vectorBakers(): Map<String, (Int) -> ByteArray?> = linkedMapOf(
            "legacy-composite" to { curve -> SwiftCore.bakeFalseColorCube(1, curve % 4, 180f) },
            "legacy-paint" to { curve -> SwiftCore.bakeFalseColorLimitsPaint(curve % 4, 180f) },
            "legacy-weight" to { curve -> SwiftCore.bakeFalseColorLimitsWeight(curve % 4, 180f) },
            "monitor-composite" to { curve -> SwiftCore.bakeMonitorFalseColorCube(1 + if (curve >= 4) 4 else 0, curve % 4, 180f) },
            "monitor-paint" to { curve -> SwiftCore.bakeMonitorFalseColorLimitsPaint(curve, 180f) },
            "monitor-weight" to { curve -> SwiftCore.bakeMonitorFalseColorLimitsWeight(curve, 180f) })
        override fun compositionScene(): MonitorFeedEffectsCacheOwnerNativeProof.CompositionScene {
            val driver = MonitorCacheOwnerComposeDriver(InstrumentationRegistry.getInstrumentation()) { _, source ->
                val plans = rememberFeedEffectsRenderPlans(source)
                plans to remember(plans) {
                    { requireNotNull(plans.create(FeedEffects(falseColor = FeedFalseColorScale.IRE),
                        FeedEffectsConfiguration(), ExposureAssistCameraInput(codec = "N-RAW", iso = 800L, baseIso = "800"))).nativePlan }
                }
            }.start()
            return MonitorFeedEffectsCacheOwnerNativeProof.CompositionScene(
                driver::snapshot, driver::retiredPlan, driver::command, driver::close)
        }
        override fun planOwner(): MonitorFeedEffectsCacheOwnerNativeProof.PlanOwner = object : MonitorFeedEffectsCacheOwnerNativeProof.PlanOwner {
            private val plans = FeedEffectsRenderPlans()
            override fun plan() = requireNotNull(plans.create(FeedEffects(falseColor = FeedFalseColorScale.IRE),
                FeedEffectsConfiguration(), ExposureAssistCameraInput(codec = "N-RAW", iso = 800L, baseIso = "800"))).nativePlan
            override fun close() = plans.close()
        }
    })
    @Test fun actualOldAndNewStagedNativeBytes() = proof.actualNativeBytesMatchOldStagedLibrary(
        requireNotNull(InstrumentationRegistry.getArguments().getString("cache_reference_mode")))
    @Test fun actualNativeCacheCapacityAndRetirement() = proof.actualNativePayloadsObeyEightEntryLruAndImmediateRetirement()
    @Test fun actualEnteredNativeBakeRetires() = proof.enteredActualNativeBakeCannotRefillRetiredOwner()
    @Test fun actualFacadeEscapedPlansKeepRendering() = proof.actualFacadePlansRemainRenderableAfterOnlyTheirCacheRetires()
    @Test fun actualComposeCacheOwnersSurviveCoverageRotationDetachAndFinalRetirement() =
        proof.actualComposeCacheOwnersSurviveCoverageRotationDetachAndFinalRetirement()
}
