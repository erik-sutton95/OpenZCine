package com.opencapture.openzcine

import com.opencapture.opencine.appkit.MonitorAssistState

/** An in-memory assist set with nothing switched on and nothing saved. */
internal fun idleNikonAssists(): NikonAssists =
    NikonAssists(MonitorAssistState().apply { syncVisible(emptySet()) }, FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)) {}
