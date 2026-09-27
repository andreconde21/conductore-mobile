package com.gwitko.conduit

/**
 * The widget's colours: the app theme's, pushed by Dart (payload 3), or
 * Everforest, the app's default, for older payloads. ARGB.
 */
data class WidgetTheme(
    val dark: Boolean,
    val surface: Int,
    val onSurface: Int,
    val muted: Int,
    val border: Int,
    val accent: Int,
    val onAccent: Int,
    val warning: Int,
    val urgent: Int,
) {
    /** A limit ring's colour at [level] (normal, warning, critical). */
    fun ringColor(level: String): Int = when (level) {
        "critical" -> urgent
        "warning" -> warning
        else -> accent
    }

    companion object {
        /** Omarchy Everforest, as `values/agent_widget.xml` has it. */
        val EVERFOREST = WidgetTheme(
            dark = true,
            surface = 0xFF2D353B.toInt(),
            onSurface = 0xFFD3C6AA.toInt(),
            muted = 0xFFA19B89.toInt(),
            border = 0xFF475258.toInt(),
            accent = 0xFF7FBBB3.toInt(),
            onAccent = 0xFF2D353B.toInt(),
            warning = 0xFFDBBC7F.toInt(),
            urgent = 0xFFE67E80.toInt(),
        )
    }
}

/**
 * One "needs you" or "stuck" line: agent · machine · reason, and the agent
 * a tap opens. Mirrors `AgentStatusLine` on the Dart side. [hostId] is
 * empty for lines built from an old payload: those open the dashboard.
 */
data class DashboardLine(
    val stuck: Boolean,
    val name: String,
    val host: String,
    val reason: String,
    val hostId: String = "",
    val agentId: String = "",
    val workspace: String = "",
    val tab: String = "",
    val pane: String = "",
) {
    /** What the line's token stands for. */
    val key: String get() = "$hostId/$agentId"

    val tappable: Boolean get() = hostId.isNotEmpty()

    fun text(): String = listOf(name, host, reason).filter { it.isNotEmpty() }.joinToString(" · ")
}

/**
 * The agents dashboard's counts. Mirrors `AgentStatusDashboard` on the
 * Dart side; a count is null when unknown (stuck and done before the
 * dashboard cached a digest, and everything but needs-you in old
 * payloads). [factsAtMillis] is the "as of" of stuck and done, 0 unknown.
 */
data class WidgetDashboard(
    val needsYou: Int,
    val working: Int?,
    val stuck: Int?,
    val done: Int?,
    val factsAtMillis: Long = 0L,
    val lines: List<DashboardLine> = emptyList(),
) {
    /** Whether the tile has something to say ("2 need you · 1 stuck"). */
    val hasNews: Boolean get() = needsYou > 0 || (stuck ?: 0) > 0

    companion object {
        const val MAX_LINES = 3

        /**
         * The dashboard of a payload before version 3: the attention count,
         * and its agents needing input as lines (not tappable: an old
         * payload carries no host ids).
         */
        fun legacy(attentionCount: Int, agents: List<AgentStatusLine>) = WidgetDashboard(
            needsYou = attentionCount,
            working = null,
            stuck = null,
            done = null,
            lines = agents.filter { it.urgent }.take(MAX_LINES).map {
                DashboardLine(stuck = false, name = it.name, host = it.host, reason = it.label.lowercase())
            },
        )
    }
}

/** Which layout a widget of a given size gets, and how much it shows. */
data class WidgetSpec(val small: Boolean, val lines: Int, val weekRing: Boolean) {
    companion object {
        /** Below this height (dp): the 2x1 form, the needs-you count and the 5-hour ring. */
        const val SMALL_MAX_HEIGHT_DP = 100

        /** Below this width (dp) only the 5-hour ring fits. */
        const val NARROW_MAX_WIDTH_DP = 180

        /** Heights (dp) from which the 4x2 form fits two and three lines. */
        const val TWO_LINES_HEIGHT_DP = 124
        const val THREE_LINES_HEIGHT_DP = 141

        /**
         * The spec for a widget [widthDp] by [heightDp]; 0 means unknown (a
         * launcher that reports no size), taken as the 4x2 default.
         */
        fun select(widthDp: Int, heightDp: Int): WidgetSpec {
            val narrow = widthDp in 1 until NARROW_MAX_WIDTH_DP
            if (heightDp in 1 until SMALL_MAX_HEIGHT_DP) {
                return WidgetSpec(small = true, lines = 0, weekRing = false)
            }
            val lines = when {
                heightDp <= 0 || heightDp >= THREE_LINES_HEIGHT_DP -> 3
                heightDp >= TWO_LINES_HEIGHT_DP -> 2
                else -> 1
            }
            return WidgetSpec(small = false, lines = lines, weekRing = !narrow)
        }
    }
}

/**
 * Keeps the widget's agent lines from being forged: the exported
 * MainActivity accepts intents from any app, so a line's tap carries only a
 * random token, and the agent it opens comes from the app's own stored
 * snapshot. Plain Kotlin for the JVM tests.
 */
object WidgetLineGuard {
    /**
     * Tokens for the lines [keys]: a line still shown keeps its token (a
     * widget not yet redrawn stays tappable), every new one gets [newToken].
     */
    fun reissue(previous: Map<String, String>, keys: List<String>, newToken: () -> String): Map<String, String> =
        keys.distinct().associateWith { key -> previous[key] ?: newToken() }

    /** The line key [token] was issued for, or null for a forged or stale one. */
    fun resolve(issued: Map<String, String>, token: String?): String? {
        if (token.isNullOrEmpty()) return null
        var found: String? = null
        for ((key, value) in issued) {
            if (constantTimeEquals(value, token)) found = key
        }
        return found
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].code xor b[i].code)
        return diff == 0
    }
}
