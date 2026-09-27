package com.gwitko.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentNotificationModelTest {
    private fun spec(
        agentId: String = "s-1",
        hostId: String = "h",
        requestId: String? = "r1",
        allowAlways: Boolean = true,
        needsYou: Boolean = true,
        alert: Boolean = true,
        alertKey: String = "approval:r1",
        title: String = "api · VTM needs you",
    ) = AgentNotificationModel.Spec(
        hostId = hostId,
        agentId = agentId,
        needsYou = needsYou,
        title = title,
        text = "Approve Bash: npm test · +1 more",
        lines = listOf("Approve Bash: npm test", "Approve Bash: git push"),
        publicTitle = "Conductore: api needs you",
        alert = alert,
        alertKey = alertKey,
        action = requestId?.let { AgentNotificationModel.FirstAction(it, allowAlways) },
        reviewAll = true,
        open = AgentNotificationStore.OpenTarget("h", agentId, "", "", ""),
    )

    @Test
    fun oneNotificationPerAgentKeyedByHostAndSession() {
        val first = spec(requestId = "r1")
        val next = spec(requestId = "r2", alertKey = "approval:r2")
        assertEquals("agent:h:s-1", first.key)
        // Another request for the same agent: the same notification.
        assertEquals(
            AgentNotificationModel.notificationId(first.key),
            AgentNotificationModel.notificationId(next.key),
        )
        assertNotEquals(
            AgentNotificationModel.notificationId(first.key),
            AgentNotificationModel.notificationId(spec(agentId = "s-2").key),
        )
        assertNotEquals(
            AgentNotificationModel.notificationId(first.key),
            AgentNotificationModel.notificationId(spec(hostId = "other").key),
        )
        assertNotEquals(AgentNotificationModel.summaryId, AgentNotificationModel.notificationId(first.key))
        assertNotEquals(AgentNotificationModel.TAG, AgentNotificationModel.LEGACY_TAG)
    }

    @Test
    fun theChannelArgumentsBecomeASpec() {
        val parsed = AgentNotificationModel.Spec.fromMap(
            mapOf(
                "hostId" to "h", "agentId" to "s-1", "needsYou" to true, "title" to "api · VTM needs you",
                "text" to "Approve Bash: npm test", "lines" to listOf("a", "b"), "publicTitle" to "Conductore: api",
                "alert" to true, "alertKey" to "approval:r1", "requestId" to "r1", "allowAlways" to false,
                "reviewAll" to false, "openHostId" to "h", "openAgentId" to "s-1",
            ),
        )!!
        assertEquals("agent:h:s-1", parsed.key)
        assertEquals(AgentNotificationModel.FirstAction("r1", allowAlways = false), parsed.action)
        assertEquals(listOf("a", "b"), parsed.lines)
        assertEquals("s-1", parsed.open?.agentId)
        assertNull(AgentNotificationModel.Spec.fromMap(mapOf("hostId" to "h")))
        // Without a request: no buttons.
        assertNull(AgentNotificationModel.Spec.fromMap(mapOf("hostId" to "h", "agentId" to "a"))!!.action)
    }

    @Test
    fun aSpecSurvivesTheStore() {
        val stored = spec().copy(postedAt = 42)
        assertEquals(stored, AgentNotificationModel.Spec.fromJson(stored.toJson()))
        val plain = spec(requestId = null)
        assertEquals(plain, AgentNotificationModel.Spec.fromJson(plain.toJson()))
    }

    @Test
    fun buttonsActOnTheFirstPendingItemOnly() {
        val two = spec(requestId = "r1")
        assertEquals(listOf("allow", "deny", "always"), AgentNotificationModel.verdicts(two).map { it.first })
        for ((verdict, _) in AgentNotificationModel.verdicts(two)) {
            val payload = AgentNotificationModel.buttonPayload(two, verdict)!!
            assertEquals("r1", payload.requestId)
            assertEquals("agent:h:s-1", payload.notificationId)
            assertEquals("s-1", payload.agentId)
            assertEquals("h", payload.hostId)
        }
        // Always only when allowed (not for a high-risk request).
        assertEquals(
            listOf("allow", "deny"),
            AgentNotificationModel.verdicts(spec(allowAlways = false)).map { it.first },
        )
        // Summary only or nothing to approve: no buttons.
        assertTrue(AgentNotificationModel.verdicts(spec(requestId = null)).isEmpty())
        assertNull(AgentNotificationModel.buttonPayload(spec(requestId = null), "allow"))
    }

    @Test
    fun tokensStillGuardTheButtons() {
        val token = "0123456789abcdef0123456789abcdef"
        val issued = AgentNotificationModel.issued(spec(requestId = "r1"), token)
        val payload = AgentNotificationModel.buttonPayload(spec(requestId = "r1"), "allow")!!
        assertTrue(PermissionActionGuard.accepts(issued, payload.hostId, payload.requestId, token))
        // A forged or missing token decides nothing.
        assertFalse(PermissionActionGuard.accepts(issued, payload.hostId, payload.requestId, "f".repeat(32)))
        assertFalse(PermissionActionGuard.accepts(issued, payload.hostId, payload.requestId, null))
        // A button of the notification's earlier version (its first item
        // was r0) cannot answer the request it shows now.
        assertFalse(PermissionActionGuard.accepts(issued, payload.hostId, "r0", token))
        assertNull(AgentNotificationModel.issued(spec(requestId = null), token))
    }

    @Test
    fun onlyANewNeedAlerts() {
        val showing = spec(alertKey = "approval:r1")
        // A new need, not showing yet: alert.
        assertEquals(AgentNotificationModel.Post.ALERT, AgentNotificationModel.post(showing, null, showing = false))
        // An update Dart marks silent: silent while showing ...
        assertEquals(
            AgentNotificationModel.Post.SILENT,
            AgentNotificationModel.post(spec(alert = false), showing, showing = true),
        )
        // ... and not posted at all once the user dismissed it.
        assertEquals(
            AgentNotificationModel.Post.SKIP,
            AgentNotificationModel.post(spec(alert = false), showing, showing = false),
        )
        // An app restart re-sends the same need: no second alert.
        assertEquals(AgentNotificationModel.Post.SILENT, AgentNotificationModel.post(showing, showing, showing = true))
        // A new request after the last was answered: alert.
        assertEquals(
            AgentNotificationModel.Post.ALERT,
            AgentNotificationModel.post(spec(alertKey = "approval:r2"), showing, showing = true),
        )
        // Android 5 cannot list the shade: the stored spec stands in.
        assertEquals(AgentNotificationModel.Post.SILENT, AgentNotificationModel.post(spec(alert = false), showing, null))
        assertEquals(AgentNotificationModel.Post.SKIP, AgentNotificationModel.post(spec(alert = false), null, null))
    }

    @Test
    fun silentUpdatesKeepTheirPlaceInTheShade() {
        val previous = spec().copy(postedAt = 100)
        assertEquals(100, AgentNotificationModel.postedAt(AgentNotificationModel.Post.SILENT, previous, 500))
        assertEquals(500, AgentNotificationModel.postedAt(AgentNotificationModel.Post.ALERT, previous, 500))
        assertEquals(500, AgentNotificationModel.postedAt(AgentNotificationModel.Post.SILENT, null, 500))
    }

    @Test
    fun aHostSyncRemovesThatHostsOtherAgentsOnly() {
        val stored = listOf(spec(agentId = "a"), spec(agentId = "b"), spec(hostId = "other", agentId = "a"))
            .associateBy { it.key }
        val (kept, removed) = AgentNotificationModel.sync(stored, "h", listOf(spec(agentId = "a", alert = false)))
        assertEquals(listOf("agent:h:b"), removed)
        assertEquals(setOf("agent:h:a", "agent:other:a"), kept.keys)
        assertFalse(kept.getValue("agent:h:a").alert)
        // Nothing left for the host: all of its notifications go.
        assertEquals(
            setOf("agent:h:a", "agent:h:b"),
            AgentNotificationModel.sync(stored, "h", emptyList()).second.toSet(),
        )
    }

    @Test
    fun theGroupSummaryCountsAgents() {
        assertNull(AgentNotificationModel.summary(listOf(spec())))
        val three = listOf(
            spec(agentId = "a", title = "api · VTM needs you"),
            spec(agentId = "b", title = "web · VTM is waiting for you"),
            spec(agentId = "c", title = "ops · prod needs you"),
        )
        val summary = AgentNotificationModel.summary(three)!!
        assertEquals("3 agents need you", summary.title)
        assertEquals("Conductore: 3 agents need you", summary.publicTitle)
        assertEquals(3, summary.count)
        assertEquals(three.map { it.title }, summary.lines)

        val mixed = AgentNotificationModel.summary(
            listOf(
                spec(agentId = "a", needsYou = false, title = "api · VTM finished"),
                spec(agentId = "b", title = "web · VTM needs you"),
            ),
        )!!
        assertEquals("1 agent needs you · 1 finished", mixed.title)
        // Agents that need you come first.
        assertEquals(listOf("web · VTM needs you", "api · VTM finished"), mixed.lines)

        val done = AgentNotificationModel.summary(
            listOf(spec(agentId = "a", needsYou = false), spec(agentId = "b", needsYou = false)),
        )!!
        assertEquals("2 agents finished", done.title)
    }

    @Test
    fun anUpgradeCancelsThePerRequestNotificationsOnce() {
        assertTrue(AgentNotificationModel.needsMigration(1))
        assertFalse(AgentNotificationModel.needsMigration(AgentNotificationModel.SCHEMA))
        val cancelled = AgentNotificationModel.legacyCancellations(
            active = listOf(
                AgentNotificationModel.LEGACY_TAG to "h:perm:req-1".hashCode(),
                AgentNotificationModel.LEGACY_TAG to "h:s-1".hashCode(),
                AgentNotificationModel.TAG to 7,
                null to 8,
            ),
            storedIds = listOf("h:perm:req-2"),
        )
        assertEquals(
            setOf("h:perm:req-1".hashCode(), "h:s-1".hashCode(), "h:perm:req-2".hashCode()),
            cancelled,
        )
    }
}
