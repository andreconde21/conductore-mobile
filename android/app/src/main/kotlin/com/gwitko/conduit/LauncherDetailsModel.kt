package com.gwitko.conduit

/**
 * The rows [LauncherDetailsProvider] serves, from the stored
 * [AgentStatusSnapshot]. Plain Kotlin so the mapping and the order are
 * unit-tested on the JVM; the provider only wraps them in a cursor.
 */
object LauncherDetailsModel {
    val ITEM_COLUMNS = arrayOf("id", "title", "subtitle", "state", "progress", "updated_at", "deep_link")
    val SUMMARY_COLUMNS = arrayOf("monitoring", "attention_count", "updated_at", "limit_5h_pct", "limit_7d_pct")

    /** No source reports an agent's progress yet. */
    const val PROGRESS_UNKNOWN = -1

    const val LIMIT_UNKNOWN = -1

    /**
     * One row per agent of [snapshot] (none when there is none), urgent
     * first (needs input or blocked), then the latest state change first;
     * ties keep the snapshot's order. [tokens] are the store's line tokens
     * by [DashboardLine.key]: an agent without one has no deep link.
     */
    fun items(
        snapshot: AgentStatusSnapshot?,
        tokens: Map<String, String>,
        packageName: String,
        activityClass: String,
    ): List<Array<Any?>> {
        if (snapshot == null) return emptyList()
        return snapshot.agents
            .map { it to updatedAt(it, snapshot) }
            .sortedWith(compareBy<Pair<AgentStatusLine, Long>> { if (it.first.urgent) 0 else 1 }.thenByDescending { it.second })
            .map { (agent, updatedAt) ->
                val line = agent.asDashboardLine()
                val token = if (line.tappable) tokens[line.key] else null
                arrayOf(
                    if (line.tappable) line.key else "${agent.host}/${agent.name}",
                    agent.name,
                    listOf(agent.host, agent.label).filter { it.isNotEmpty() }.joinToString(" · "),
                    agent.state,
                    PROGRESS_UNKNOWN,
                    updatedAt,
                    token?.let { deepLink(packageName, activityClass, it) },
                )
            }
    }

    /** The single summary row; a missing snapshot is "not monitoring". */
    fun summary(snapshot: AgentStatusSnapshot?, nowMillis: Long): Array<Any?> {
        fun limit(label: String): Int = snapshot?.limit(label)?.percentAt(nowMillis) ?: LIMIT_UNKNOWN
        return arrayOf(
            if (snapshot?.monitoring == true) 1 else 0,
            snapshot?.attentionCount ?: 0,
            snapshot?.updatedAtMillis ?: 0L,
            limit("5h"),
            limit("7d"),
        )
    }

    /**
     * An `intent:` URI (what `Intent.toUri(Intent.URI_INTENT_SCHEME)` writes)
     * for the widget's own agent-line launch: MainActivity with the line
     * [token]. The token stands for the agent; MainActivity resolves it
     * against the stored snapshot, so the URI cannot be edited to open any
     * other session. Open it with `Intent.parseUri(link, URI_INTENT_SCHEME)`.
     */
    fun deepLink(packageName: String, activityClass: String, token: String): String =
        "intent:#Intent;action=${AgentStatusStore.ACTION_OPEN_AGENT_LINE};" +
            "launchFlags=0x$LAUNCH_FLAGS_HEX;" +
            "component=$packageName/$activityClass;" +
            "S.${AgentStatusStore.EXTRA_LAUNCH_TARGET}=${AgentStatusStore.LAUNCH_TARGET_AGENT};" +
            "S.${AgentStatusStore.EXTRA_LINE_TOKEN}=$token;end"

    /** [rows] cut down to [projection] (all columns when null). */
    fun project(columns: Array<String>, rows: List<Array<Any?>>, projection: Array<String>?): Pair<Array<String>, List<Array<Any?>>> {
        if (projection == null) return columns to rows
        val indexes = projection.map { name ->
            columns.indexOf(name).also { require(it >= 0) { "Unknown column $name" } }
        }
        return projection to rows.map { row -> Array(indexes.size) { row[indexes[it]] } }
    }

    private fun updatedAt(agent: AgentStatusLine, snapshot: AgentStatusSnapshot): Long =
        if (agent.changedAtMillis > 0) agent.changedAtMillis else snapshot.updatedAtMillis

    /** FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_SINGLE_TOP, as the widget's taps. */
    private const val LAUNCH_FLAGS_HEX = "30000000"
}
