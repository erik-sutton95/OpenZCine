package com.opencapture.openzcine

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.StillPickerLadders
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** A3-28: QUALITY and the LUT looks sit on the shared Core drums, not app wheels. */
@RunWith(AndroidJUnit4::class)
class SharedDrumsComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val sharedDrum = SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)

    @Test
    fun qualityTiersAreTheSharedValueDrum() {
        val writes = mutableListOf<Pair<CameraControl, String>>()
        val request = CommandControlRequest("QUALITY", CameraControl.STILL_QUALITY, "RAW+JPEG Normal",
            StillPickerLadders.QUALITY_OPTIONS)
        val picker = MonitorPickerPresentation(MonitorPickerKind.QUALITY, "QUALITY", "RAW · JPEG/HEIF",
            listOf(MonitorPickerModePresentation("QUALITY", request)))
        composeRule.setContent {
            OpenZCineTheme {
                QualityPickerPanelBody(picker, nefCompression = null,
                    onSelect = { sent, label -> writes += sent.control to label })
            }
        }
        composeRule.onNode(hasContentDescription("On") and sharedDrum).assertExists()
        val tier = composeRule.onNode(hasContentDescription("Normal") and sharedDrum)
        composeRule.runOnIdle { assertEquals("opening the panel writes nothing", emptyList<Any>(), writes) }
        tier.performSemanticsAction(SemanticsActions.SetProgress) { it(StillQualityConfig.TIER_OPTIONS.indexOf("Fine").toFloat()) }
        composeRule.runOnIdle { assertEquals(listOf(CameraControl.STILL_QUALITY to "RAW+JPEG Fine"), writes) }
    }

    @Test
    fun lutLooksAreTheSharedLabelWheel() {
        val assists = idleNikonAssists()
        composeRule.setContent {
            OpenZCineTheme {
                Column {
                    NikonLutOptions(assists, lutLibrary = null, onOpenRedDownload = {}, onRequestLutImport = null)
                }
            }
        }
        composeRule.runOnIdle { assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), assists.lut) }
        // The shared wheel's rows are accessible buttons; the app wheel's were raw pointer input. The
        // row below the seated look is the one the lazy wheel has laid out.
        composeRule.onNodeWithText(FeedLut.NLOG_709.label).performSemanticsAction(SemanticsActions.OnClick)
        composeRule.runOnIdle { assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), assists.lut) }
    }
}
