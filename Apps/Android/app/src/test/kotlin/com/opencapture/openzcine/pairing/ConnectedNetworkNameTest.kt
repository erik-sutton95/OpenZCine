package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ConnectedNetworkNameTest {
    /** The SSID the platform hands back is quoted, and sometimes refused outright. */
    @Test
    fun `a platform ssid is unwrapped and its refusals rejected`() {
        assertEquals("Studio", ConnectedNetworkName.sanitized("\"Studio\""))
        assertEquals("Studio", ConnectedNetworkName.sanitized("  Studio  "))
        assertNull(ConnectedNetworkName.sanitized(null))
        assertNull(ConnectedNetworkName.sanitized(""))
        assertNull(ConnectedNetworkName.sanitized("\"\""))
        assertNull(ConnectedNetworkName.sanitized("<unknown ssid>"))
        // A camera's own access point is never an infrastructure network.
        assertNull(ConnectedNetworkName.sanitized("\"NIKON_Z6_123456\""))
    }
}
