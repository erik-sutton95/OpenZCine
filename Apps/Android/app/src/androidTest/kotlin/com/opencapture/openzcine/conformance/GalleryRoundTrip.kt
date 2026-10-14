package com.opencapture.openzcine.conformance

import com.opencapture.monitorui.MonitorCapabilities
import com.opencapture.opencine.appuitesting.ConformanceApp
import com.opencapture.opencine.appuitesting.ConformanceProfile
import com.opencapture.openzcine.MainActivity

/** SIMULATED S1 only: real MainActivity, local cache, shared gallery and native player. */
class GalleryRoundTrip : com.opencapture.opencine.appuitesting.GalleryRoundTrip(ZLocalReview)

private object ZLocalReview : ConformanceApp {
    override val activity = MainActivity::class.java
    // This local library has no connected camera or optional camera services.
    override val profile = ConformanceProfile("ZCine", MonitorCapabilities())
}
