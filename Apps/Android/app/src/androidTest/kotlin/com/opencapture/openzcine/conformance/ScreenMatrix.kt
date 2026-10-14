package com.opencapture.openzcine.conformance

import com.opencapture.monitorui.MonitorCapabilities
import com.opencapture.opencine.appuitesting.ConformanceApp
import com.opencapture.opencine.appuitesting.ConformanceProfile
import com.opencapture.openzcine.MainActivity

/** SIMULATED screenshot matrix only (A7 increment 5): every key screen, light and dark, both
 *  orientations, with the checkpoint geometry invariants and one screenshot per cell. */
class ScreenMatrix : com.opencapture.opencine.appuitesting.ScreenMatrix(ZMatrixReview)

private object ZMatrixReview : ConformanceApp {
    override val activity = MainActivity::class.java
    // A local review has no connected camera or optional camera controls.
    override val profile = ConformanceProfile("ZCine", MonitorCapabilities())
}
