package com.gwitko.conduit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

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
        assertArrayEquals(arrayOf<Any?>(0, 0, 0L, -1, -1, 2), LauncherDetailsModel.summary(null, 0L))
    }

    @Test
    fun summaryCarriesCountsAndLimits() {
        val snapshot = AgentStatusSnapshot.parse(payload)
        // 7d's window already reset at this time: 0, not the stale 85.
        assertArrayEquals(
            arrayOf<Any?>(1, 2, 1790000000000L, 42, 0, 3),
            LauncherDetailsModel.summary(snapshot, 1790000000000L),
        )
        val noLimits = AgentStatusSnapshot.parse(payload.replace(""""limits":[""", """"x":["""))
        assertArrayEquals(arrayOf<Any?>(1, 2, 1790000000000L, -1, -1, 3), LauncherDetailsModel.summary(noLimits, 0L))
    }

    // As Dart's LauncherPrompt.encodeAll writes them (CON-082).
    private val prompts = LauncherPrompt.parseAll(
        """
        [{"id":"host-1/s1","hostId":"host-1","agentId":"s1","requestId":"r1",
          "question":"Approve Bash: npm test · Medium risk",
          "options":[{"label":"Allow","verdict":"allow"},{"label":"Always allow","verdict":"always"},
                     {"label":"Deny","verdict":"deny"}],
          "replyVerdict":null,"answers":"","note":null},
         {"id":"host-2/s2","hostId":"host-2","agentId":"s2","requestId":"r2",
          "question":"Approve Bash: git push --force · High risk","options":null,
          "replyVerdict":null,"answers":"","note":"High-risk request: open it in Conductore"},
         {"id":"host-1/s4","hostId":"host-1","agentId":"s4","requestId":"reply","question":"Old question",
          "options":null,"replyVerdict":"reply","answers":"","note":null}]
        """.trimIndent(),
    )

    private fun column(row: Array<Any?>, name: String) = row[LauncherDetailsModel.ITEM_COLUMNS.indexOf(name)]

    @Test
    fun anAgentNeedingYouCarriesItsQuestionAndOptions() {
        val rows = LauncherDetailsModel.items(AgentStatusSnapshot.parse(payload), tokens, pkg, activity, prompts)
        val api = rows.first { it[1] == "api" }
        assertEquals(LauncherDetailsModel.ITEM_COLUMNS.size, api.size)
        assertEquals("Approve Bash: npm test · Medium risk", column(api, "question"))
        assertEquals("""["Allow","Always allow","Deny"]""", column(api, "options"))
        assertEquals(1, column(api, "answerable"))
        assertNull(column(api, "answer_note"))
        // High risk: shown, never answerable from the launcher.
        val ops = rows.first { it[1] == "ops" }
        assertEquals("Approve Bash: git push --force · High risk", column(ops, "question"))
        assertNull(column(ops, "options"))
        assertEquals(0, column(ops, "answerable"))
        assertEquals("High-risk request: open it in Conductore", column(ops, "answer_note"))
    }

    @Test
    fun agentsNotNeedingYouHaveNoQuestionEvenWithAStalePrompt() {
        val rows = LauncherDetailsModel.items(AgentStatusSnapshot.parse(payload), tokens, pkg, activity, prompts)
        // web (working) still has a prompt from before: never served.
        for (name in listOf("web", "done", "old")) {
            val row = rows.first { it[1] == name }
            for (col in listOf("question", "options", "answerable", "answer_note")) assertNull(column(row, col))
        }
    }

    @Test
    fun anAgentNeedingYouWithoutAPromptIsNotAnswerable() {
        val row = items().first { it[1] == "api" }
        assertNull(column(row, "question"))
        assertNull(column(row, "options"))
        assertEquals(0, column(row, "answerable"))
        assertEquals("Open it in Conductore to answer", column(row, "answer_note"))
    }

    @Test
    fun promptsParseOptionsAndReplies() {
        assertEquals(
            listOf(LauncherOption("Allow", "allow"), LauncherOption("Always allow", "always"), LauncherOption("Deny", "deny")),
            prompts.getValue("host-1/s1").options,
        )
        val reply = prompts.getValue("host-1/s4")
        assertNull(reply.options)
        assertEquals("reply", reply.replyVerdict)
        assertTrue(reply.answerable)
        assertTrue(!prompts.getValue("host-2/s2").answerable)
        assertTrue(LauncherPrompt.parseAll("not json").isEmpty())
        assertTrue(LauncherPrompt.parseAll(null).isEmpty())
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

    // The catalog the app ships (Gradle runs unit tests in android/app).
    private val catalog = File("src/main/res/raw/launcher_themes.json").readText()

    @Test
    fun themesListTheShippedCatalogInItsOrderWithEveryRole() {
        val rows = LauncherDetailsModel.themes(catalog)
        assertEquals(22, rows.size)
        assertEquals("catppuccin", rows.first()[0])
        // Dark ones first, then light ones, as the theme picker shows them.
        val modes = rows.map { it[2] }
        assertEquals(modes.sortedBy { if (it == "dark") 0 else 1 }, modes)
        assertTrue(modes.contains("light"))
        val catppuccin = rows.first()
        assertArrayEquals(
            arrayOf<Any?>(
                "catppuccin", "Catppuccin", "dark",
                "#89B4FA", "#1E1E2E", "#CDD6F4", "#585B70", "#45475A", "#313244",
                "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#F6B6AB",
            ),
            catppuccin,
        )
        assertEquals(LauncherDetailsModel.THEMES_COLUMNS.size, catppuccin.size)
        assertTrue(rows.all { row -> row.drop(3).all { (it as String).matches(Regex("#[0-9A-F]{6}")) } })
    }

    @Test
    fun pcThemeIsTheSyncedMachineThemeOrNulls() {
        assertArrayEquals(
            (listOf<Any?>(null, null, 0L, null, null) + LauncherDetailsModel.THEME_ROLES.map { null }).toTypedArray(),
            LauncherDetailsModel.pcTheme(AgentStatusSnapshot.parse(payload)),
        )
        val withPc = payload.replaceFirst(
            "{",
            """{"pcTheme":{"name":"tokyo-night","label":"Tokyo Night","mode":"dark","machine":"omarchy-pc",
               "updatedAt":1789990000000,"colors":{"accent":"#7AA2F7","background":"#1A1B26"}},""",
        )
        val row = LauncherDetailsModel.pcTheme(AgentStatusSnapshot.parse(withPc))
        assertEquals(LauncherDetailsModel.PC_THEME_COLUMNS.size, row.size)
        assertEquals(listOf("tokyo-night", "omarchy-pc", 1789990000000L, "Tokyo Night", "dark"), row.take(5))
        assertEquals("#7AA2F7", row[5])
        assertEquals("#1A1B26", row[6])
        // A role the payload lacks is null, not an empty string.
        assertNull(row[7])
        // A snapshot without a machine name keeps the theme.
        val noMachine = AgentStatusSnapshot.parse(withPc.replace(""""machine":"omarchy-pc",""", ""))
        assertNull(LauncherDetailsModel.pcTheme(noMachine)[1])
    }

    @Test
    fun notMonitoringKeepsThePcTheme() {
        val withPc = payload.replaceFirst(
            "{",
            """{"pcTheme":{"name":"nord","mode":"dark","updatedAt":1,"colors":{}},""",
        )
        val stored = AgentStatusSnapshot.parse(AgentStatusSnapshot.notMonitoring(withPc)!!)!!
        assertEquals("nord", stored.pcTheme!!.name)
        assertTrue(stored.agents.isEmpty())
    }

    // Contract 3 (CON-119): project and active.

    private val hour = 3_600_000L

    @Test
    fun projectIsTheGroupNameOrNullForOther() {
        val withProjects = payload
            .replace(""""pane":"p1",""", """"pane":"p1","project":"Conductore",""")
            .replace(""""agentId":"s2",""", """"agentId":"s2","project":null,""")
        val rows = LauncherDetailsModel.items(AgentStatusSnapshot.parse(withProjects), tokens, pkg, activity, nowMillis = 1790000000000L)
        assertEquals("Conductore", column(rows.first { it[1] == "api" }, "project"))
        assertNull(column(rows.first { it[1] == "ops" }, "project"))
        // An older payload, or no project: null (Other).
        assertNull(column(rows.first { it[1] == "web" }, "project"))
        assertEquals(LauncherDetailsModel.ITEM_COLUMNS.size, rows.first().size)
    }

    @Test
    fun activeKeepsBusyAgentsAndRecentChangesWithinTheViewsWindow() {
        val now = 1789999900000L + 30 * hour
        val rows = LauncherDetailsModel.items(AgentStatusSnapshot.parse(payload), tokens, pkg, activity, nowMillis = now)
        fun active(name: String) = column(rows.first { it[1] == name }, "active")
        // Needing the user, working or finished: always (the view's busy dots).
        assertEquals(1, active("api"))
        assertEquals(1, active("ops"))
        assertEquals(1, active("web"))
        assertEquals(1, active("done"))
        // Idle with no known change: not active.
        assertEquals(0, active("old"))
        val idle = payload.replace(
            """"state":"idle","label":"Idle","hostId":"host-1","agentId":"s5"""",
            """"state":"idle","label":"Idle","hostId":"host-1","agentId":"s5","changedAt":${now - 23 * hour}""",
        )
        val snapshot = AgentStatusSnapshot.parse(idle)!!
        val agent = snapshot.agents.first { it.name == "old" }
        // The default window is 24 hours; the payload's own wins.
        assertEquals(24, snapshot.recentHours)
        assertEquals(1, LauncherDetailsModel.active(agent, snapshot.recentHours, now))
        assertEquals(0, LauncherDetailsModel.active(agent, snapshot.recentHours, now + hour))
        val narrow = AgentStatusSnapshot.parse(idle.replaceFirst("{", """{"recentHours":4,"""))!!
        assertEquals(0, LauncherDetailsModel.active(agent, narrow.recentHours, now))
    }

    @Test
    fun dartsBusyFlagWinsOverTheState() {
        // With "Sync with sheprd", sheprd's active view decides: a working
        // agent taken out of it is not busy, a kept idle one is.
        val synced = payload
            .replace(""""state":"working","label":"Working",""", """"state":"working","label":"Working","busy":false,""")
            .replace(""""state":"idle","label":"Idle",""", """"state":"idle","label":"Idle","busy":true,""")
        val rows = LauncherDetailsModel.items(AgentStatusSnapshot.parse(synced), tokens, pkg, activity, nowMillis = 1789999900000L + 30 * hour)
        assertEquals(0, column(rows.first { it[1] == "web" }, "active"))
        assertEquals(1, column(rows.first { it[1] == "old" }, "active"))
    }
}
