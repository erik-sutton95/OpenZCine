package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals

class WhiteBalanceTintGridTest {
    @Test
    fun `label matches shared-core WhiteBalanceTint convention`() {
        assertEquals("Neutral", WhiteBalanceTintGrid.label(0, 0))
        assertEquals("A1 · M0.25", WhiteBalanceTintGrid.label(2, -1))
        assertEquals("B1.5 · G0.75", WhiteBalanceTintGrid.label(-3, 3))
        assertEquals("A3", WhiteBalanceTintGrid.label(6, 0))
        assertEquals("G1.5", WhiteBalanceTintGrid.label(0, 6))
    }

    @Test
    fun `cells round-trip from operator labels`() {
        assertEquals(0 to 0, WhiteBalanceTintGrid.cellsFromLabel("Neutral"))
        assertEquals(2 to -1, WhiteBalanceTintGrid.cellsFromLabel("A1 · M0.25"))
        assertEquals(-3 to 3, WhiteBalanceTintGrid.cellsFromLabel("B1.5 · G0.75"))
        assertEquals(2 to 2, WhiteBalanceTintGrid.cellsFromLabel("A1 · G0.5"))
    }

    @Test
    fun `full grid is 13 by 13 unique labels`() {
        val labels = WhiteBalanceTintGrid.allLabels()
        assertEquals(169, labels.size)
        assertEquals(169, labels.toSet().size)
        // Row-major greenMagenta outer (−6…+6), amberBlue inner (−6…+6).
        assertEquals("B3 · M1.5", labels.first())
        assertEquals("A3 · G1.5", labels.last())
    }
}
