package com.opencapture.openzcine.settings

import com.opencapture.opencine.appkit.MonitorDisplaySection

/** What a Nikon source can ever fill, for the Display rows. No Nikon source feeds a color chip, a zoom chip or a
 * gimbal stick; the live monitor narrows this further to what feeds it now. */
internal val NIKON_DISPLAY_SECTIONS: Set<MonitorDisplaySection> = MonitorDisplaySection.entries.toSet() -
    setOf(MonitorDisplaySection.COLOR, MonitorDisplaySection.ZOOM_CHIP, MonitorDisplaySection.GIMBAL_STICK)
