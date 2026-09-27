package com.gwitko.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentWidgetModelTest {
    @Test
    fun aOneRowWidgetIsTheSmallForm() {
        // 2x1 on common launchers: about 110-180 x 40-90 dp.
        val spec = WidgetSpec.select(widthDp = 150, heightDp = 60)
        assertTrue(spec.small)
        assertEquals(0, spec.lines)
        assertFalse(spec.weekRing)
    }

    @Test
    fun aFourByTwoWidgetShowsThreeLinesAndBothRings() {
        assertEquals(WidgetSpec(small = false, lines = 3, weekRing = true), WidgetSpec.select(300, 180))
    }

    @Test
    fun anUnknownSizeIsTheFourByTwoDefault() {
        assertEquals(WidgetSpec(small = false, lines = 3, weekRing = true), WidgetSpec.select(0, 0))
    }

    @Test
    fun linesFollowTheHeight() {
        assertEquals(1, WidgetSpec.select(300, WidgetSpec.SMALL_MAX_HEIGHT_DP).lines)
        assertEquals(1, WidgetSpec.select(300, WidgetSpec.TWO_LINES_HEIGHT_DP - 1).lines)
        assertEquals(2, WidgetSpec.select(300, WidgetSpec.TWO_LINES_HEIGHT_DP).lines)
        assertEquals(2, WidgetSpec.select(300, WidgetSpec.THREE_LINES_HEIGHT_DP - 1).lines)
        assertEquals(3, WidgetSpec.select(300, WidgetSpec.THREE_LINES_HEIGHT_DP).lines)
        assertTrue(WidgetSpec.select(300, WidgetSpec.SMALL_MAX_HEIGHT_DP - 1).small)
    }

    @Test
    fun aNarrowTallWidgetDropsTheWeekRing() {
        val spec = WidgetSpec.select(150, 200)
        assertFalse(spec.small)
        assertFalse(spec.weekRing)
        assertTrue(WidgetSpec.select(WidgetSpec.NARROW_MAX_WIDTH_DP, 200).weekRing)
    }

    @Test
    fun aLineKeepsItsTokenWhileShownAndNewLinesGetNewOnes() {
        var next = 0
        val first = WidgetLineGuard.reissue(emptyMap(), listOf("h/a", "h/b"), { "t${next++}" })
        assertEquals(mapOf("h/a" to "t0", "h/b" to "t1"), first)
        val second = WidgetLineGuard.reissue(first, listOf("h/b", "h/c"), { "t${next++}" })
        // b keeps its token (a widget not redrawn yet stays tappable), a is gone.
        assertEquals(mapOf("h/b" to "t1", "h/c" to "t2"), second)
    }

    @Test
    fun onlyAnIssuedTokenResolves() {
        val issued = mapOf("h/a" to "0123456789abcdef0123456789abcdef", "h/b" to "fedcba9876543210fedcba9876543210")
        assertEquals("h/b", WidgetLineGuard.resolve(issued, "fedcba9876543210fedcba9876543210"))
        // Another app's intent: no token, an empty one, or a guess.
        assertNull(WidgetLineGuard.resolve(issued, null))
        assertNull(WidgetLineGuard.resolve(issued, ""))
        assertNull(WidgetLineGuard.resolve(issued, "0123456789abcdef0123456789abcdee"))
        assertNull(WidgetLineGuard.resolve(issued, "h/a"))
        assertNull(WidgetLineGuard.resolve(emptyMap(), "0123456789abcdef0123456789abcdef"))
    }

    @Test
    fun theTileHasNewsWhenSomeoneNeedsYouOrIsStuck() {
        assertFalse(WidgetDashboard(needsYou = 0, working = 3, stuck = 0, done = 2).hasNews)
        assertFalse(WidgetDashboard(needsYou = 0, working = 3, stuck = null, done = null).hasNews)
        assertTrue(WidgetDashboard(needsYou = 2, working = 0, stuck = null, done = null).hasNews)
        assertTrue(WidgetDashboard(needsYou = 0, working = 0, stuck = 1, done = 0).hasNews)
    }

    @Test
    fun aLineReadsAgentMachineReason() {
        val line = DashboardLine(stuck = true, name = "api", host = "dev box", reason = "npm test failed 3 times")
        assertEquals("api · dev box · npm test failed 3 times", line.text())
        assertFalse(line.tappable)
        assertNotEquals(line.key, DashboardLine(false, "api", "dev", "", hostId = "h", agentId = "a").key)
    }

    @Test
    fun ringColoursFollowTheLevel() {
        val theme = WidgetTheme.EVERFOREST
        assertEquals(theme.accent, theme.ringColor("normal"))
        assertEquals(theme.warning, theme.ringColor("warning"))
        assertEquals(theme.urgent, theme.ringColor("critical"))
    }
}
