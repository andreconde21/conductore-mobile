package com.gwitko.conduit

import org.json.JSONArray
import org.json.JSONObject

/**
 * The followed Omarchy machine's theme as Dart stored it in the snapshot
 * (`pcTheme`): never the theme picked in the app. [colors] are
 * [LauncherDetailsModel.THEME_ROLES] as `#RRGGBB`.
 */
data class LauncherPcTheme(
    val name: String,
    val label: String,
    val mode: String,
    val colors: Map<String, String>,
    val machine: String?,
    val updatedAtMillis: Long,
) {
    companion object {
        fun parse(json: JSONObject?): LauncherPcTheme? {
            if (json == null || !json.has("name") || !json.has("updatedAt")) return null
            val colors = json.optJSONObject("colors") ?: return null
            return LauncherPcTheme(
                name = json.optString("name"),
                label = json.optString("label"),
                mode = if (json.optString("mode") == "light") "light" else "dark",
                colors = colors.keys().asSequence().associateWith { colors.optString(it) },
                machine = if (json.isNull("machine")) null else json.optString("machine"),
                updatedAtMillis = json.optLong("updatedAt", 0L),
            )
        }
    }
}

/**
 * The rows [LauncherDetailsProvider] serves, from the stored
 * [AgentStatusSnapshot]. Plain Kotlin so the mapping and the order are
 * unit-tested on the JVM; the provider only wraps them in a cursor.
 */
object LauncherDetailsModel {
    val ITEM_COLUMNS = arrayOf(
        "id", "title", "subtitle", "state", "progress", "updated_at", "deep_link",
        // Contract 2 (CON-082): only for agents needing the user.
        "question", "options", "answerable", "answer_note",
        // Contract 3 (CON-119): the project view's grouping and filter.
        "project", "active",
    )
    val SUMMARY_COLUMNS = arrayOf(
        "monitoring", "attention_count", "updated_at", "limit_5h_pct", "limit_7d_pct", "contract_version",
    )

    /** The contract version `/summary` reports (docs/launcher-details-provider.md). */
    const val CONTRACT_VERSION = 3

    /** States the project view's "active" filter always keeps (busy dots). */
    private val ACTIVE_STATES = setOf("working", "needsInput", "blocked", "finished")

    /** The Omarchy roles of a theme row, each `#RRGGBB`. */
    val THEME_ROLES = listOf(
        "accent", "background", "foreground", "muted", "selection", "lighter_background",
        "red", "green", "yellow", "blue", "magenta", "cyan", "orange",
    )
    val THEMES_COLUMNS = (listOf("name", "label", "mode") + THEME_ROLES).toTypedArray()
    val PC_THEME_COLUMNS = (listOf("name", "machine", "updated_at", "label", "mode") + THEME_ROLES).toTypedArray()

    /** No source reports an agent's progress yet. */
    const val PROGRESS_UNKNOWN = -1

    const val LIMIT_UNKNOWN = -1

    /**
     * One row per agent of [snapshot] (none when there is none), urgent
     * first (needs input or blocked), then the latest state change first;
     * ties keep the snapshot's order. [tokens] are the store's line tokens
     * by [DashboardLine.key]: an agent without one has no deep link.
     *
     * [prompts] (by item id) fill `question`, `options`, `answerable` and
     * `answer_note` of an agent needing the user; every other agent has
     * them null. One needing the user without a prompt (an older payload,
     * or an agent the prompts have not caught up with) is not answerable.
     *
     * `project` is the agent's project as Conductore's project view groups
     * it (null: Other); `active` ([active]) is judged at [nowMillis].
     */
    fun items(
        snapshot: AgentStatusSnapshot?,
        tokens: Map<String, String>,
        packageName: String,
        activityClass: String,
        prompts: Map<String, LauncherPrompt> = emptyMap(),
        nowMillis: Long = System.currentTimeMillis(),
    ): List<Array<Any?>> {
        if (snapshot == null) return emptyList()
        return snapshot.agents
            .map { it to updatedAt(it, snapshot) }
            .sortedWith(compareBy<Pair<AgentStatusLine, Long>> { if (it.first.urgent) 0 else 1 }.thenByDescending { it.second })
            .map { (agent, updatedAt) ->
                val line = agent.asDashboardLine()
                val token = if (line.tappable) tokens[line.key] else null
                val prompt = if (agent.urgent && line.tappable) prompts[line.key] else null
                arrayOf<Any?>(
                    if (line.tappable) line.key else "${agent.host}/${agent.name}",
                    agent.name,
                    listOf(agent.host, agent.label).filter { it.isNotEmpty() }.joinToString(" · "),
                    agent.state,
                    PROGRESS_UNKNOWN,
                    updatedAt,
                    token?.let { deepLink(packageName, activityClass, it) },
                ).plus(elements = answerColumns(agent, prompt))
                    .plus(elements = arrayOf<Any?>(agent.project, active(agent, snapshot.recentHours, nowMillis)))
            }
    }

    /**
     * 1 when Conductore's project view keeps [agent] under its "active"
     * filter at [nowMillis], else 0: busy (working, needing the user or
     * finished; with "Sync with sheprd", what sheprd's active view says,
     * as Dart wrote it in `busy`), or a state change within the view's
     * [recentHours].
     */
    fun active(agent: AgentStatusLine, recentHours: Int, nowMillis: Long): Int {
        val busy = agent.busy ?: (agent.state in ACTIVE_STATES)
        val recent = agent.changedAtMillis > 0 && nowMillis - agent.changedAtMillis < recentHours * 3_600_000L
        return if (busy || recent) 1 else 0
    }

    /** `question`, `options`, `answerable` and `answer_note` of one agent. */
    private fun answerColumns(agent: AgentStatusLine, prompt: LauncherPrompt?): Array<Any?> = when {
        !agent.urgent -> arrayOf(null, null, null, null)
        prompt == null -> arrayOf(null, null, 0, LauncherActions.OPEN_TO_ANSWER)
        else -> arrayOf(
            prompt.question.ifEmpty { null },
            prompt.options?.let { options -> JSONArray(options.map { it.label }).toString() },
            if (prompt.answerable) 1 else 0,
            if (prompt.answerable) null else prompt.note ?: LauncherActions.OPEN_TO_ANSWER,
        )
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
            CONTRACT_VERSION,
        )
    }

    /**
     * One row per theme of [catalogJson] (res/raw/launcher_themes.json,
     * which Dart generates from the theme picker), in its order.
     */
    fun themes(catalogJson: String): List<Array<Any?>> {
        val catalog = JSONArray(catalogJson)
        return (0 until catalog.length()).map { index ->
            val theme = catalog.getJSONObject(index)
            val colors = theme.optJSONObject("colors") ?: JSONObject()
            (
                listOf<Any?>(theme.optString("name"), theme.optString("label"), theme.optString("mode")) +
                    THEME_ROLES.map { role -> if (colors.has(role)) colors.optString(role) else null }
            ).toTypedArray()
        }
    }

    /** The single pc_theme row: all null but updated_at (0) when unknown. */
    fun pcTheme(snapshot: AgentStatusSnapshot?): Array<Any?> {
        val theme = snapshot?.pcTheme
            ?: return (listOf<Any?>(null, null, 0L, null, null) + THEME_ROLES.map { null }).toTypedArray()
        return (
            listOf<Any?>(theme.name, theme.machine, theme.updatedAtMillis, theme.label, theme.mode) +
                THEME_ROLES.map { theme.colors[it] }
        ).toTypedArray()
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
