package com.opencapture.openzcine.conformance

import com.opencapture.monitorui.MonitorCapabilities
import com.opencapture.opencine.appuitesting.ConformanceApp
import com.opencapture.opencine.appuitesting.ConformanceProfile
import com.opencapture.openzcine.MainActivity

/**
 * The shared conformance scenarios (docs/conformance/SCENARIOS.md) against the real launcher, staged
 * by the Debug review host with SIMULATED sources only. ConformanceCoverageTest fails when one is missing.
 */
class GalleryRoundTrip : com.opencapture.opencine.appuitesting.GalleryRoundTrip(ZReview)

class ShareRoundTrip : com.opencapture.opencine.appuitesting.ShareRoundTrip(ZReview)

class ConfirmationCancel : com.opencapture.opencine.appuitesting.ConfirmationCancel(ZReview)

class ChromeEditReturn : com.opencapture.opencine.appuitesting.ChromeEditReturn(ZReview)

class AccessibilityTraversal : com.opencapture.opencine.appuitesting.AccessibilityTraversal(ZReview)

class ScreenMatrix : com.opencapture.opencine.appuitesting.ScreenMatrix(ZReview)

class ConformanceCoverageTest : com.opencapture.opencine.appuitesting.ConformanceCoverageTest(ZReview)

private object ZReview : ConformanceApp {
    override val activity = MainActivity::class.java
    // This local library has no connected camera or optional camera services.
    override val profile = ConformanceProfile("ZCine", MonitorCapabilities())
}
