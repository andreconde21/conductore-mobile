package com.gwitko.conduit

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentStatusSnapshotParseTest {
    private val v2 = """
        {"version":2,"monitoring":true,"attentionCount":2,"updatedAt":1790000000000,
         "agents":[{"name":"api","host":"dev","state":"needsInput","label":"Needs input"},
                   {"name":"web","host":"dev","state":"working","label":"Working"},
                   {"name":"ops","host":"prod","state":"blocked","label":"Blocked"}],
         "limits":[{"label":"5h","usedPct":42,"level":"normal"}]}
    """.trimIndent()

    private val v3 = """
        {"version":3,"monitoring":true,"attentionCount":1,"updatedAt":1790000000000,
         "agents":[],"limits":[{"label":"7d","usedPct":85,"level":"warning","resetsAt":1790000600000}],
         "dashboard":{"needsYou":1,"working":3,"stuck":1,"done":4,"factsAt":1789999940000,
           "lines":[{"kind":"needsYou","name":"api","host":"dev","reason":"approve Bash",
                     "hostId":"host-1","agentId":"s1","workspace":"w1","tab":"t1","pane":"p1"},
                    {"kind":"stuck","name":"web","host":"dev","reason":"npm test failed 3 times",
                     "hostId":"host-1","agentId":"s2"},
                    {"kind":"stuck","name":"a","host":"b","reason":"c","hostId":"h","agentId":"x"},
                    {"kind":"stuck","name":"over","host":"the","reason":"cap","hostId":"h","agentId":"y"}]},
         "theme":{"dark":false,"surface":4294965995,"onSurface":4283782485,"muted":4287932536,
           "border":4291940030,"accent":4282225805,"onAccent":4294967295,"warning":4292128281,
           "urgent":4294078538}}
    """.trimIndent()

    @Test
    fun aVersion2PayloadKeepsWorkingWithTheAttentionCountAlone() {
        val snapshot = AgentStatusSnapshot.parse(v2)!!
        assertEquals(2, snapshot.version)
        assertNull(snapshot.theme)
        val dashboard = snapshot.dashboard
        assertEquals(2, dashboard.needsYou)
        assertNull(dashboard.working)
        assertNull(dashboard.stuck)
        assertNull(dashboard.done)
        assertEquals(0L, dashboard.factsAtMillis)
        // Its agents needing input become lines, not tappable (no host ids).
        assertEquals(listOf("api", "ops"), dashboard.lines.map { it.name })
        assertEquals("needs input", dashboard.lines.first().reason)
        assertFalse(dashboard.lines.any { it.tappable })
        assertEquals(42, snapshot.limit("5h")!!.usedPct)
    }

    @Test
    fun aVersion3PayloadCarriesTheDashboardAndTheTheme() {
        val snapshot = AgentStatusSnapshot.parse(v3)!!
        val dashboard = snapshot.dashboard
        assertEquals(1, dashboard.needsYou)
        assertEquals(3, dashboard.working)
        assertEquals(1, dashboard.stuck)
        assertEquals(4, dashboard.done)
        assertEquals(1789999940000L, dashboard.factsAtMillis)
        assertEquals(WidgetDashboard.MAX_LINES, dashboard.lines.size)
        val first = dashboard.lines.first()
        assertFalse(first.stuck)
        assertEquals("host-1/s1", first.key)
        assertEquals("w1", first.workspace)
        assertEquals("p1", first.pane)
        assertTrue(dashboard.lines[1].stuck)
        assertEquals("", dashboard.lines[1].workspace)

        val theme = snapshot.theme!!
        assertFalse(theme.dark)
        // Unsigned ARGB from Dart back to a signed colour int.
        assertEquals(0xFFFFFAEB.toInt(), theme.surface)
        assertEquals(0xFFF2704A.toInt(), theme.urgent)
    }

    @Test
    fun unknownCountsStayUnknown() {
        val snapshot = AgentStatusSnapshot.parse(
            """{"version":3,"monitoring":true,"attentionCount":0,"dashboard":{"needsYou":0,"working":2}}""",
        )!!
        assertEquals(2, snapshot.dashboard.working)
        assertNull(snapshot.dashboard.stuck)
        assertNull(snapshot.dashboard.done)
        assertNull(snapshot.theme)
    }

    @Test
    fun aVersion3PayloadWithoutADashboardFallsBackToTheCount() {
        val snapshot = AgentStatusSnapshot.parse("""{"version":3,"monitoring":false,"attentionCount":0}""")!!
        assertEquals(0, snapshot.dashboard.needsYou)
        assertNull(snapshot.dashboard.stuck)
    }

    @Test
    fun anIncompleteThemeIsIgnored() {
        val snapshot = AgentStatusSnapshot.parse("""{"version":3,"theme":{"dark":true,"surface":1}}""")!!
        assertNull(snapshot.theme)
    }

    @Test
    fun somethingThatIsNotAPayloadIsNull() {
        assertNull(AgentStatusSnapshot.parse("not json"))
    }

    @Test
    fun notMonitoringDropsTheLiveDataButKeepsLimitsAndTheme() {
        val stored = AgentStatusSnapshot.notMonitoring(v3)!!
        val snapshot = AgentStatusSnapshot.parse(stored)!!
        assertFalse(snapshot.monitoring)
        assertEquals(3, snapshot.version)
        assertEquals(0, snapshot.dashboard.needsYou)
        assertTrue(snapshot.dashboard.lines.isEmpty())
        assertNotNull(snapshot.theme)
        assertEquals(85, snapshot.limit("7d")!!.usedPct)
        assertFalse(JSONObject(stored).has("dashboard"))
        assertNull(AgentStatusSnapshot.notMonitoring("[]"))
    }
}
