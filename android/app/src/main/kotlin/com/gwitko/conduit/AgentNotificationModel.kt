package com.gwitko.conduit

import org.json.JSONArray
import org.json.JSONObject

/**
 * The rules behind agent notifications, as plain Kotlin so JVM unit tests
 * cover them: one notification per agent (host id plus session id), the
 * buttons of its first pending request, the group summary across agents,
 * when a post alerts, and the migration from the per-request
 * notifications of earlier builds.
 */
object AgentNotificationModel {
    /** Tag of every per-agent notification and of the group summary. */
    const val TAG = "conduit_agent_v2"

    /** Tag of the per-request (and plain) notifications before [SCHEMA] 2. */
    const val LEGACY_TAG = "conduit_agent"

    /** Tag of plain notifications (the usage alert). */
    const val PLAIN_TAG = "conduit_plain"

    const val GROUP_KEY = "com.gwitko.conduit.AGENTS"
    const val SCHEMA = 2
    private const val SUMMARY_KEY = "agent-summary"

    /** The notification key of [agentId] on [hostId] (Dart builds the same). */
    fun key(hostId: String, agentId: String): String = "agent:$hostId:$agentId"

    /** The platform id of the notification [key]. */
    fun notificationId(key: String): Int = key.hashCode()

    /** The group summary's platform id. */
    val summaryId: Int = SUMMARY_KEY.hashCode()

    /** The request the buttons answer, and whether "Always" is offered. */
    data class FirstAction(val requestId: String, val allowAlways: Boolean)

    /** One agent's notification as Dart describes it. */
    data class Spec(
        val hostId: String,
        val agentId: String,
        val needsYou: Boolean,
        val title: String,
        val text: String,
        val lines: List<String>,
        val publicTitle: String,
        val alert: Boolean,
        val alertKey: String,
        val action: FirstAction?,
        val reviewAll: Boolean,
        val open: AgentNotificationStore.OpenTarget?,
        /** When it was first posted for its current need (shade order). */
        val postedAt: Long = 0,
    ) {
        val key: String get() = key(hostId, agentId)

        fun toJson(): JSONObject = JSONObject()
            .put("hostId", hostId)
            .put("agentId", agentId)
            .put("needsYou", needsYou)
            .put("title", title)
            .put("text", text)
            .put("lines", JSONArray(lines))
            .put("publicTitle", publicTitle)
            .put("alert", alert)
            .put("alertKey", alertKey)
            .put("reviewAll", reviewAll)
            .put("postedAt", postedAt)
            .apply {
                action?.let {
                    put("requestId", it.requestId)
                    put("allowAlways", it.allowAlways)
                }
                open?.let { put("open", it.toJson()) }
            }

        companion object {
            /** From the channel's argument map; null without a host or agent. */
            fun fromMap(map: Map<*, *>): Spec? {
                fun string(name: String) = map[name] as? String ?: ""
                val hostId = string("hostId")
                val agentId = string("agentId")
                if (hostId.isEmpty() || agentId.isEmpty()) return null
                val requestId = string("requestId")
                val openHostId = string("openHostId")
                return Spec(
                    hostId = hostId,
                    agentId = agentId,
                    needsYou = map["needsYou"] as? Boolean ?: true,
                    title = string("title"),
                    text = string("text"),
                    lines = (map["lines"] as? List<*>)?.filterIsInstance<String>() ?: emptyList(),
                    publicTitle = string("publicTitle"),
                    alert = map["alert"] as? Boolean ?: false,
                    alertKey = string("alertKey"),
                    action = if (requestId.isEmpty()) null else FirstAction(
                        requestId,
                        map["allowAlways"] as? Boolean ?: false,
                    ),
                    reviewAll = map["reviewAll"] as? Boolean ?: false,
                    open = if (openHostId.isEmpty()) null else AgentNotificationStore.OpenTarget(
                        hostId = openHostId,
                        agentId = string("openAgentId"),
                        workspaceId = string("openWorkspaceId"),
                        tabId = string("openTabId"),
                        paneId = string("openPaneId"),
                    ),
                )
            }

            fun fromJson(json: JSONObject): Spec? {
                val hostId = json.optString("hostId")
                val agentId = json.optString("agentId")
                if (hostId.isEmpty() || agentId.isEmpty()) return null
                val lines = json.optJSONArray("lines")
                val requestId = json.optString("requestId")
                return Spec(
                    hostId = hostId,
                    agentId = agentId,
                    needsYou = json.optBoolean("needsYou", true),
                    title = json.optString("title"),
                    text = json.optString("text"),
                    lines = if (lines == null) emptyList() else (0 until lines.length()).map { lines.optString(it) },
                    publicTitle = json.optString("publicTitle"),
                    alert = json.optBoolean("alert"),
                    alertKey = json.optString("alertKey"),
                    action = if (requestId.isEmpty()) null else FirstAction(
                        requestId,
                        json.optBoolean("allowAlways"),
                    ),
                    reviewAll = json.optBoolean("reviewAll"),
                    open = AgentNotificationStore.OpenTarget.fromJson(json.optJSONObject("open")),
                    postedAt = json.optLong("postedAt"),
                )
            }
        }
    }

    /** The buttons of [spec]: Allow / Deny, and Always when allowed. */
    fun verdicts(spec: Spec): List<Pair<String, String>> {
        val action = spec.action ?: return emptyList()
        return listOf("allow" to "Allow", "deny" to "Deny") +
            if (action.allowAlways) listOf("always" to "Always") else emptyList()
    }

    /** What one button of [spec] carries: always its first request. */
    data class ButtonPayload(
        val notificationId: String,
        val hostId: String,
        val agentId: String,
        val requestId: String,
        val verdict: String,
    )

    fun buttonPayload(spec: Spec, verdict: String): ButtonPayload? {
        val action = spec.action ?: return null
        return ButtonPayload(
            notificationId = spec.key,
            hostId = spec.hostId,
            agentId = spec.agentId,
            requestId = action.requestId,
            verdict = verdict,
        )
    }

    /** What a token of [spec]'s buttons is issued for. */
    fun issued(spec: Spec, token: String): PermissionActionGuard.Issued? {
        val action = spec.action ?: return null
        return PermissionActionGuard.Issued(token = token, hostId = spec.hostId, requestId = action.requestId)
    }

    /** How a post goes out. */
    enum class Post { ALERT, SILENT, SKIP }

    /**
     * A post alerts only when Dart says the agent newly needs the user and
     * the same need is not already showing (an app restart re-sends it). A
     * silent update of a notification that is not showing (dismissed, or
     * carried over from an earlier run and gone since) is not posted.
     * [showing] is null when the platform cannot tell (Android 5).
     */
    fun post(spec: Spec, previous: Spec?, showing: Boolean?): Post {
        val visible = showing ?: (previous != null)
        return when {
            spec.alert && !(visible && previous?.alertKey == spec.alertKey) -> Post.ALERT
            visible -> Post.SILENT
            else -> Post.SKIP
        }
    }

    /** The shade order: a new need moves up, an update keeps its place. */
    fun postedAt(post: Post, previous: Spec?, now: Long): Long =
        if (post == Post.ALERT || previous == null || previous.postedAt == 0L) now else previous.postedAt

    /**
     * Makes [incoming] the notifications of [hostId] in [stored]: returns
     * the new store and the keys of the host's notifications to remove.
     */
    fun sync(stored: Map<String, Spec>, hostId: String, incoming: List<Spec>): Pair<Map<String, Spec>, List<String>> {
        val keys = incoming.map { it.key }.toSet()
        val removed = stored.values.filter { it.hostId == hostId && it.key !in keys }.map { it.key }
        val kept = stored.filterKeys { it !in removed }.toMutableMap()
        for (spec in incoming) kept[spec.key] = spec
        return kept to removed
    }

    /** The group summary: "3 agents need you". */
    data class Summary(val title: String, val publicTitle: String, val lines: List<String>, val count: Int)

    /**
     * The summary over the notifications [showing]; null below two (a
     * single notification needs no stack).
     */
    fun summary(showing: Collection<Spec>): Summary? {
        if (showing.size < 2) return null
        val needing = showing.count { it.needsYou }
        val finished = showing.size - needing
        val title = when {
            needing == 0 -> "$finished agents finished"
            finished == 0 -> "${agents(needing)} ${if (needing == 1) "needs" else "need"} you"
            else -> "${agents(needing)} ${if (needing == 1) "needs" else "need"} you · $finished finished"
        }
        return Summary(
            title = title,
            publicTitle = "Conductore: $title",
            lines = showing.sortedByDescending { it.needsYou }.map { it.title },
            count = showing.size,
        )
    }

    private fun agents(count: Int) = if (count == 1) "1 agent" else "$count agents"

    /** Whether the stored [schema] predates per-agent notifications. */
    fun needsMigration(schema: Int): Boolean = schema < SCHEMA

    /**
     * The legacy ids to cancel on upgrade: every notification still showing
     * under [LEGACY_TAG] ([active] as tag and id pairs), plus the ids the old
     * build remembered ([storedIds], for systems that cannot list them).
     */
    fun legacyCancellations(active: List<Pair<String?, Int>>, storedIds: Collection<String>): Set<Int> =
        active.filter { it.first == LEGACY_TAG }.map { it.second }.toSet() +
            storedIds.map { it.hashCode() }
}
