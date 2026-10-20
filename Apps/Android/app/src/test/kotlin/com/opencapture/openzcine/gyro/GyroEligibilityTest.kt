package com.opencapture.openzcine.gyro

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS twin: GyroCaptureTests `selectorArms`. */
class GyroEligibilityTest {
    @Test fun `only a reported video selector arms, photo and an unread selector wait`() {
        assertFalse(gyroSelectorArms(null))
        assertFalse(gyroSelectorArms("photo"))
        assertTrue(gyroSelectorArms("video"))
    }
}
