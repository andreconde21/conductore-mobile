package com.gwitko.conduit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LauncherDetailsModelTest {
    private val pkg = "com.outsmartis.conductore"
    private val activity = "com.gwitko.conduit.MainActivity"

    // As Dart writes it: agents most urgent first, ids and changedAt per agent.
    private val payload = """
        {"version":3,"monitoring":true,"attentionCount":2,"updatedAt":1790000000000,
         "agents":[
           {"name":"api","host":"dev","state":"needsInput","label":"Needs input",
            "hostId":"host-1","agentId":"s1","workspace":"w1","tab":"t1","pane":"p1","changedAt":1789999000000},
           {"name":"ops","host":"prod","state":"blocked","label":"Blocked",
            "hostId":"host-2","agentId":"s2","changedAt":1789999500000},
           {"name":"done","host":"dev","state":"finished","label":"Finished",
            "hostId":"host-1","agentId":"s3","changedAt":1789999100000},
           {"name":"web","host":"dev","state":"working","label":"Working",
            "hostId":"host-1","agentId":"s4","changedAt":1789999900000},
           {"name":"old","host":"dev","state":"idle","label":"Idle","hostId":"host-1","agentId":"s5"}],
         "limits":[{"label":"5h","usedPct":42,"level":"normal","resetsAt":1790000600000},
                   {"label":"7d","usedPct":85,"level":"warning","resetsAt":1789000000000}]}
    """.trimIndent()

    private val tokens = mapOf("host-1/s1" to "aa11", "host-2/s2" to "bb22", "host-1/s4" to "dd44")

    private fun items(json: String = payload) =
        LauncherDetailsModel.items(AgentStatusSnapshot.parse(json), tokens, pkg, activity)

    @Test
    fun sortsUrgentFirstThenLatestChangeFirst() {
        // ops (blocked) changed after api (needsInput): both urgent, newest first.
        // old has no changedAt, so it takes the snapshot's time (the newest).
        assertEquals(listOf("ops", "api", "old", "web", "done"), items().map { it[1] })
    }

    @Test
    fun mapsEveryColumn() {
        val api = items().first { it[1] == "api" }
        assertEquals(LauncherDetailsModel.ITEM_COLUMNS.size, api.size)
        assertEquals("host-1/s1", api[0])
        assertEquals("api", api[1])
        assertEquals("dev · Needs input", api[2])
        assertEquals("needsInput", api[3])
        assertEquals(-1, api[4])
        assertEquals(1789999000000L, api[5])
        assertEquals(
            "intent:#Intent;action=com.gwitko.conduit.action.OPEN_AGENT_LINE;launchFlags=0x30000000;" +
                "component=com.outsmartis.conductore/com.gwitko.conduit.MainActivity;" +
                "S.com.gwitko.conduit.LAUNCH_TARGET=agent;S.com.gwitko.conduit.WIDGET_LINE_TOKEN=aa11;end",
            api[6],
        )
        // State values go out verbatim, as Dart names them.
        assertEquals(setOf("needsInput", "blocked", "finished", "working", "idle"), items().map { it[3] }.toSet())
        // No token issued: no deep link. No changedAt: the snapshot's time.
        val old = items().first { it[1] == "old" }
        assertNull(old[6])
        assertEquals(1790000000000L, old[5])
    }

    @Test
    fun anOldPayloadWithoutIdsHasNoDeepLinks() {
        val v2 = """
            {"version":2,"monitoring":true,"attentionCount":1,"updatedAt":5,
             "agents":[{"name":"api","host":"dev","state":"needsInput","label":"Needs input"}]}
        """.trimIndent()
        val row = items(v2).single()
        assertEquals("dev/api", row[0])
        assertEquals(5L, row[5])
        assertNull(row[6])
    }

    @Test
    fun noSnapshotMeansNoItemsAndNotMonitoring() {
        assertTrue(LauncherDetailsModel.items(null, tokens, pkg, activity).isEmpty())
        assertArrayEquals(arrayOf<Any?>(0, 0, 0L, -1, -1), LauncherDetailsModel.summary(null, 0L))
    }

    @Test
    fun summaryCarriesCountsAndLimits() {
        val snapshot = AgentStatusSnapshot.parse(payload)
        // 7d's window already reset at this time: 0, not the stale 85.
        assertArrayEquals(
            arrayOf<Any?>(1, 2, 1790000000000L, 42, 0),
            LauncherDetailsModel.summary(snapshot, 1790000000000L),
        )
        val noLimits = AgentStatusSnapshot.parse(payload.replace(""""limits":[""", """"x":["""))
        assertArrayEquals(arrayOf<Any?>(1, 2, 1790000000000L, -1, -1), LauncherDetailsModel.summary(noLimits, 0L))
    }

    @Test
    fun projectionPicksColumnsInItsOrder() {
        val (columns, rows) = LauncherDetailsModel.project(
            LauncherDetailsModel.ITEM_COLUMNS,
            items(),
            arrayOf("state", "id"),
        )
        assertArrayEquals(arrayOf("state", "id"), columns)
        assertArrayEquals(arrayOf<Any?>("blocked", "host-2/s2"), rows.first())
    }

    @Test(expected = IllegalArgumentException::class)
    fun anUnknownColumnIsRejected() {
        LauncherDetailsModel.project(LauncherDetailsModel.ITEM_COLUMNS, items(), arrayOf("secret"))
    }

    @Test
    fun agentsParseTheirIdsAndOpenTheSameTargetAsAWidgetLine() {
        val api = AgentStatusSnapshot.parse(payload)!!.agents.first()
        val line = api.asDashboardLine()
        assertEquals("host-1/s1", line.key)
        assertEquals(listOf("w1", "t1", "p1"), listOf(line.workspace, line.tab, line.pane))
        assertEquals(1789999000000L, api.changedAtMillis)
    }
}
