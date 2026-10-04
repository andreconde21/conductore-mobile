package com.gwitko.conduit

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/**
 * One agent line as rendered by the widget and tile. Mirrors
 * `AgentStatusEntry` on the Dart side. The ids (where a tap goes, as in
 * [DashboardLine]) and [changedAtMillis] (0 unknown) are empty in payloads
 * written before the launcher details provider (CON-075).
 */
data class AgentStatusLine(
    val name: String,
    val host: String,
    val state: String,
    val label: String,
    val hostId: String = "",
    val agentId: String = "",
    val workspace: String = "",
    val tab: String = "",
    val pane: String = "",
    val changedAtMillis: Long = 0L,
) {
    /** Needs input or blocked: the states a human should act on. */
    val urgent: Boolean get() = state == "needsInput" || state == "blocked"

    /** The same target a dashboard line for this agent has. */
    fun asDashboardLine(): DashboardLine = DashboardLine(
        stuck = false,
        name = name,
        host = host,
        reason = label,
        hostId = hostId,
        agentId = agentId,
        workspace = workspace,
        tab = tab,
        pane = pane,
    )
}

/**
 * One account limit window (Claude's `5h` or `7d`) as a ring. Mirrors
 * `AgentStatusLimit` on the Dart side; `level` is normal, warning (80 %+)
 * or critical (95 %+).
 */
data class AgentStatusLimitRing(val label: String, val usedPct: Int, val level: String, val resetsAtMillis: Long) {
    /** What to draw at [nowMillis]: 0 once the window has reset. */
    fun percentAt(nowMillis: Long): Int =
        if (resetsAtMillis in 1..nowMillis) 0 else usedPct.coerceIn(0, 100)

    fun levelAt(nowMillis: Long): String = if (percentAt(nowMillis) == 0) "normal" else level

    fun toJson(): JSONObject = JSONObject()
        .put("label", label)
        .put("usedPct", usedPct)
        .put("level", level)
        .apply { if (resetsAtMillis > 0) put("resetsAt", resetsAtMillis) }
}

/**
 * Mirrors `AgentStatusSnapshot` on the Dart side. [dashboard] is always
 * set: from payload 3 as Dart derived it, from older ones the attention
 * count alone ([WidgetDashboard.legacy]). [theme] is null before payload 3.
 */
data class AgentStatusSnapshot(
    val monitoring: Boolean,
    val attentionCount: Int,
    val agents: List<AgentStatusLine>,
    val updatedAtMillis: Long,
    val limits: List<AgentStatusLimitRing> = emptyList(),
    val version: Int = 3,
    val dashboard: WidgetDashboard = WidgetDashboard.legacy(attentionCount, agents),
    val theme: WidgetTheme? = null,
    val pcTheme: LauncherPcTheme? = null,
) {
    fun limit(label: String): AgentStatusLimitRing? = limits.firstOrNull { it.label == label }

    companion object {
        /** Reads every payload version; null for something that is not one. */
        fun parse(json: String): AgentStatusSnapshot? = try {
            val root = JSONObject(json)
            val version = root.optInt("version", 1)
            val agentsJson = root.optJSONArray("agents") ?: JSONArray()
            val limits = root.optJSONArray("limits") ?: JSONArray()
            val attentionCount = root.optInt("attentionCount", 0)
            val agents = (0 until agentsJson.length()).map { index ->
                val agent = agentsJson.getJSONObject(index)
                AgentStatusLine(
                    name = agent.optString("name"),
                    host = agent.optString("host"),
                    state = agent.optString("state"),
                    label = agent.optString("label"),
                    hostId = agent.optString("hostId"),
                    agentId = agent.optString("agentId"),
                    workspace = agent.optString("workspace"),
                    tab = agent.optString("tab"),
                    pane = agent.optString("pane"),
                    changedAtMillis = agent.optLong("changedAt", 0L),
                )
            }
            AgentStatusSnapshot(
                monitoring = root.optBoolean("monitoring", false),
                attentionCount = attentionCount,
                agents = agents,
                updatedAtMillis = root.optLong("updatedAt", 0L),
                limits = (0 until limits.length()).map { index ->
                    val limit = limits.getJSONObject(index)
                    AgentStatusLimitRing(
                        label = limit.optString("label"),
                        usedPct = limit.optInt("usedPct", 0),
                        level = limit.optString("level", "normal"),
                        resetsAtMillis = limit.optLong("resetsAt", 0L),
                    )
                },
                version = version,
                dashboard = (if (version >= 3) parseDashboard(root.optJSONObject("dashboard")) else null)
                    ?: WidgetDashboard.legacy(attentionCount, agents),
                theme = if (version >= 3) parseTheme(root.optJSONObject("theme")) else null,
                pcTheme = LauncherPcTheme.parse(root.optJSONObject("pcTheme")),
            )
        } catch (_: Exception) {
            null
        }

        private fun JSONObject.optCount(key: String): Int? = if (has(key) && !isNull(key)) optInt(key) else null

        private fun parseDashboard(json: JSONObject?): WidgetDashboard? {
            if (json == null) return null
            val lines = json.optJSONArray("lines") ?: JSONArray()
            return WidgetDashboard(
                needsYou = json.optInt("needsYou", 0),
                working = json.optCount("working"),
                stuck = json.optCount("stuck"),
                done = json.optCount("done"),
                factsAtMillis = json.optLong("factsAt", 0L),
                lines = (0 until lines.length()).mapNotNull { index ->
                    val line = lines.optJSONObject(index) ?: return@mapNotNull null
                    DashboardLine(
                        stuck = line.optString("kind") == "stuck",
                        name = line.optString("name"),
                        host = line.optString("host"),
                        reason = line.optString("reason"),
                        hostId = line.optString("hostId"),
                        agentId = line.optString("agentId"),
                        workspace = line.optString("workspace"),
                        tab = line.optString("tab"),
                        pane = line.optString("pane"),
                    )
                }.take(WidgetDashboard.MAX_LINES),
            )
        }

        private fun parseTheme(json: JSONObject?): WidgetTheme? {
            if (json == null) return null
            val keys = listOf("surface", "onSurface", "muted", "border", "accent", "onAccent", "warning", "urgent")
            if (keys.any { !json.has(it) }) return null
            // Dart writes ARGB as an unsigned 32-bit number.
            fun color(key: String): Int = json.optLong(key).toInt()
            return WidgetTheme(
                dark = json.optBoolean("dark", true),
                surface = color("surface"),
                onSurface = color("onSurface"),
                muted = color("muted"),
                border = color("border"),
                accent = color("accent"),
                onAccent = color("onAccent"),
                warning = color("warning"),
                urgent = color("urgent"),
            )
        }

        /**
         * [json] as it is stored once the engine went away: not monitoring,
         * no agents or dashboard (they no longer reflect a live session).
         * The version, the limit rings (per account, 0 once their window
         * resets), the theme and the PC theme stay. Null when [json] is not a payload.
         */
        fun notMonitoring(json: String): String? = try {
            val root = JSONObject(json)
            root.put("monitoring", false)
                .put("attentionCount", 0)
                .put("agents", JSONArray())
                .remove("dashboard")
            root.toString()
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Persists the last snapshot Dart pushed so the widget and tile can render
 * without the Flutter engine running, and the launch target the widget or
 * tile asked for until Dart consumes it.
 */
object AgentStatusStore {
    private const val PREFS = "agent_status_widget"
    private const val KEY_SNAPSHOT = "snapshot"
    private const val KEY_LAUNCH_TARGET = "launch_target"
    private const val KEY_LINE_TOKENS = "line_tokens"

    /** Intent extra carrying the launch target. */
    const val EXTRA_LAUNCH_TARGET = "com.gwitko.conduit.LAUNCH_TARGET"

    /** Intent extra carrying an agent line's token ([WidgetLineGuard]). */
    const val EXTRA_LINE_TOKEN = "com.gwitko.conduit.WIDGET_LINE_TOKEN"

    /** The agent attention sheet (widgets drawn before the dashboard counts). */
    const val LAUNCH_TARGET_AGENTS = "agents"
    const val LAUNCH_TARGET_DASHBOARD = "dashboard"
    const val LAUNCH_TARGET_USAGE = "usage"

    /** An agent line: resolved here, never handed to Dart as such. */
    const val LAUNCH_TARGET_AGENT = "agent"

    /** The targets Dart is told about; anything else in an intent is dropped. */
    val DART_LAUNCH_TARGETS = setOf(
        LAUNCH_TARGET_AGENTS,
        LAUNCH_TARGET_DASHBOARD,
        LAUNCH_TARGET_USAGE,
        GuideTileService.LAUNCH_TARGET_GUIDE,
    )

    /** Distinct actions so the widget/tile PendingIntents never collide with the notification ones. */
    const val ACTION_OPEN_AGENTS = "com.gwitko.conduit.action.OPEN_AGENTS"
    const val ACTION_OPEN_USAGE = "com.gwitko.conduit.action.OPEN_USAGE"
    const val ACTION_OPEN_AGENT_LINE = "com.gwitko.conduit.action.OPEN_AGENT_LINE"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Stores [json] and the tokens of its agent lines (the dashboard's and
     * every agent's, for the launcher's deep links), then tells the
     * launcher details provider's observers.
     */
    @Synchronized
    fun save(context: Context, json: String) {
        val previousPcTheme = load(context)?.pcTheme
        val snapshot = AgentStatusSnapshot.parse(json)
        val lines = snapshot?.tappableLines().orEmpty()
        val tokens = WidgetLineGuard.reissue(lineTokens(context), lines.map { it.key }, ::newToken)
        prefs(context).edit()
            .putString(KEY_SNAPSHOT, json)
            .putString(KEY_LINE_TOKENS, JSONObject(tokens).toString())
            .apply()
        // apply() updates the in-memory prefs at once, so the provider
        // (same process) already reads the new snapshot.
        LauncherDetailsProvider.notifyChanged(context, pcThemeChanged = snapshot?.pcTheme != previousPcTheme)
    }

    /** Every line a token may open: the dashboard's, then each agent's. */
    private fun AgentStatusSnapshot.tappableLines(): List<DashboardLine> =
        (dashboard.lines + agents.map { it.asDashboardLine() }).filter { it.tappable }

    fun load(context: Context): AgentStatusSnapshot? =
        prefs(context).getString(KEY_SNAPSHOT, null)?.let(AgentStatusSnapshot::parse)

    /** The token a tap on [line] carries; null when it has none (not tappable). */
    fun lineToken(context: Context, line: DashboardLine): String? =
        if (line.tappable) lineTokens(context)[line.key] else null

    /**
     * The line of the stored snapshot [token] was issued for; null for a
     * forged intent or a line no longer shown.
     */
    fun lineForToken(context: Context, token: String?): DashboardLine? {
        val key = WidgetLineGuard.resolve(lineTokens(context), token) ?: return null
        return load(context)?.tappableLines()?.firstOrNull { it.key == key }
    }

    /** Every issued token by line key ([DashboardLine.key]). */
    fun lineTokens(context: Context): Map<String, String> {
        val raw = prefs(context).getString(KEY_LINE_TOKENS, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            json.keys().asSequence().associateWith { json.optString(it) }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun newToken(): String {
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /**
     * Marks the snapshot as no longer live (the engine went away); see
     * [AgentStatusSnapshot.notMonitoring].
     */
    fun markNotMonitoring(context: Context) {
        val raw = prefs(context).getString(KEY_SNAPSHOT, null) ?: return
        if (load(context)?.monitoring != true) return
        AgentStatusSnapshot.notMonitoring(raw)?.let { save(context, it) }
    }

    fun setLaunchTarget(context: Context, target: String?) {
        prefs(context).edit().apply {
            if (target == null) remove(KEY_LAUNCH_TARGET) else putString(KEY_LAUNCH_TARGET, target)
        }.apply()
    }

    fun consumeLaunchTarget(context: Context): String? {
        val target = prefs(context).getString(KEY_LAUNCH_TARGET, null)
        if (target != null) setLaunchTarget(context, null)
        return target
    }

    /** Refreshes every home-screen widget and the quick-settings tile. */
    fun refreshSurfaces(context: Context) {
        AgentStatusWidgetProvider.updateAll(context)
        AgentStatusTileService.refresh()
    }
}
