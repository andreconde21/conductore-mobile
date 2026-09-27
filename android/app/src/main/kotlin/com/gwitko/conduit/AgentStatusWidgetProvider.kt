package com.gwitko.conduit

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import java.util.Date

/**
 * Home-screen widget: the agents dashboard at a glance, in the app theme's
 * colours.
 *
 * - 2x1: how many agents need you, big, and the 5-hour limit ring.
 * - 4x2: the counts (needs you, stuck, working, done; stuck and done "as
 *   of" the dashboard's last answer), the top lines needing you or stuck,
 *   and both limit rings.
 *
 * [WidgetSpec.select] picks the form from the widget's size. Tapping the
 * widget opens the dashboard, a line opens that agent, the rings open
 * usage.
 */
class AgentStatusWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val snapshot = AgentStatusStore.load(context)
        for (id in ids) {
            manager.updateAppWidget(id, build(context, snapshot, manager.getAppWidgetOptions(id)))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle,
    ) {
        manager.updateAppWidget(id, build(context, AgentStatusStore.load(context), options))
    }

    companion object {
        private val lineIds = intArrayOf(R.id.widget_line_1, R.id.widget_line_2, R.id.widget_line_3)

        /** A limit ring: its frame, bitmap and percentage. */
        private class Ring(val label: String, val frame: Int, val image: Int, val text: Int)

        private val rings = listOf(
            Ring("5h", R.id.widget_ring_5h, R.id.widget_ring_5h_image, R.id.widget_ring_5h_text),
            Ring("7d", R.id.widget_ring_7d, R.id.widget_ring_7d_image, R.id.widget_ring_7d_text),
        )

        /** One count of the 4x2 row: its cell, number and caption. */
        private class Count(val cell: Int, val number: Int, val caption: Int, val captionText: Int)

        private val needsCount = Count(
            R.id.widget_cell_needs, R.id.widget_count_needs, R.id.widget_caption_needs,
            R.string.agent_widget_caption_need_you,
        )
        private val stuckCount = Count(
            R.id.widget_cell_stuck, R.id.widget_count_stuck, R.id.widget_caption_stuck,
            R.string.agent_widget_caption_stuck,
        )
        private val workingCount = Count(
            R.id.widget_cell_working, R.id.widget_count_working, R.id.widget_caption_working,
            R.string.agent_widget_caption_working,
        )
        private val doneCount = Count(
            R.id.widget_cell_done, R.id.widget_count_done, R.id.widget_caption_done,
            R.string.agent_widget_caption_done,
        )

        private const val RING_SIZE_DP = 36f

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, AgentStatusWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val snapshot = AgentStatusStore.load(context)
            for (id in ids) {
                manager.updateAppWidget(id, build(context, snapshot, manager.getAppWidgetOptions(id)))
            }
        }

        /**
         * The widget's size in dp: in portrait the cell is as wide as the
         * minimum and as tall as the maximum the launcher reports, in
         * landscape the other way round. 0 when the launcher reports nothing.
         */
        private fun sizeDp(context: Context, options: Bundle?): Pair<Int, Int> {
            if (options == null) return 0 to 0
            val portrait = context.resources.configuration.orientation != Configuration.ORIENTATION_LANDSCAPE
            val width = options.getInt(
                if (portrait) AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH else AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH,
                0,
            )
            val height = options.getInt(
                if (portrait) AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT else AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,
                0,
            )
            return width to height
        }

        private fun build(context: Context, snapshot: AgentStatusSnapshot?, options: Bundle?): RemoteViews {
            val (width, height) = sizeDp(context, options)
            val spec = WidgetSpec.select(width, height)
            val theme = snapshot?.theme ?: WidgetTheme.EVERFOREST
            val views = RemoteViews(
                context.packageName,
                if (spec.small) R.layout.widget_agent_small else R.layout.widget_agent_large,
            )
            views.setOnClickPendingIntent(R.id.widget_root, openDashboardIntent(context))
            views.setInt(R.id.widget_surface, "setColorFilter", theme.surface)
            views.setInt(R.id.widget_border, "setColorFilter", theme.border)
            bindRings(context, views, snapshot, theme, small = spec.small, weekRing = spec.weekRing)
            if (spec.small) {
                bindSmall(context, views, snapshot, theme)
            } else {
                bindLarge(context, views, snapshot, theme, spec.lines)
            }
            return views
        }

        /** 2x1: the needs-you count, big, and its label. */
        private fun bindSmall(context: Context, views: RemoteViews, snapshot: AgentStatusSnapshot?, theme: WidgetTheme) {
            val live = snapshot != null && snapshot.monitoring
            val needs = snapshot?.dashboard?.needsYou ?: 0
            views.setViewVisibility(R.id.widget_needs_count, if (live) View.VISIBLE else View.GONE)
            views.setTextViewText(R.id.widget_needs_count, needs.toString())
            views.setTextColor(R.id.widget_needs_count, if (needs > 0) theme.urgent else theme.accent)
            val label = when {
                !live -> context.getString(R.string.agent_widget_empty)
                needs == 0 -> context.getString(R.string.agent_widget_all_clear)
                else -> context.resources.getQuantityString(R.plurals.agent_widget_need_you_label, needs)
            }
            views.setTextViewText(R.id.widget_needs_label, label)
            views.setTextColor(R.id.widget_needs_label, if (live) theme.onSurface else theme.muted)
            views.setContentDescription(
                R.id.widget_needs_count,
                context.resources.getQuantityString(R.plurals.agent_widget_n_need_you, needs, needs),
            )
        }

        /** 4x2: the counts row, the "as of", the top lines. */
        private fun bindLarge(
            context: Context,
            views: RemoteViews,
            snapshot: AgentStatusSnapshot?,
            theme: WidgetTheme,
            lineCount: Int,
        ) {
            views.setTextColor(R.id.widget_title, theme.onSurface)
            views.setTextColor(R.id.widget_as_of, theme.muted)
            views.setTextColor(R.id.widget_empty, theme.muted)
            val dashboard = snapshot?.dashboard
            if (snapshot == null || !snapshot.monitoring || dashboard == null) {
                views.setViewVisibility(R.id.widget_counts, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                views.setTextViewText(R.id.widget_as_of, "")
                for (id in lineIds) views.setViewVisibility(id, View.GONE)
                return
            }
            views.setViewVisibility(R.id.widget_counts, View.VISIBLE)
            views.setViewVisibility(R.id.widget_empty, View.GONE)

            val needs = dashboard.needsYou
            bindCount(
                context, views, needsCount, needs, if (needs > 0) theme.urgent else theme.onSurface, theme,
                context.resources.getQuantityString(R.plurals.agent_widget_n_need_you, needs, needs),
            )
            bindCount(
                context, views, stuckCount, dashboard.stuck,
                if ((dashboard.stuck ?: 0) > 0) theme.warning else theme.onSurface, theme,
                dashboard.stuck?.let { context.getString(R.string.agent_widget_n_stuck, it) },
            )
            bindCount(
                context, views, workingCount, dashboard.working,
                if ((dashboard.working ?: 0) > 0) theme.accent else theme.onSurface, theme,
                dashboard.working?.let { context.getString(R.string.agent_widget_n_working, it) },
            )
            bindCount(
                context, views, doneCount, dashboard.done, theme.onSurface, theme,
                dashboard.done?.let { context.getString(R.string.agent_widget_n_done, it) },
            )

            // Stuck and done come from the dashboard's last answer: say when.
            views.setTextViewText(
                R.id.widget_as_of,
                if (dashboard.factsAtMillis > 0L) {
                    context.getString(
                        R.string.agent_widget_as_of,
                        DateFormat.getTimeFormat(context).format(Date(dashboard.factsAtMillis)),
                    )
                } else {
                    ""
                },
            )

            lineIds.forEachIndexed { index, id ->
                val line = dashboard.lines.getOrNull(index)
                if (index >= lineCount || line == null) {
                    views.setViewVisibility(id, View.GONE)
                    return@forEachIndexed
                }
                views.setViewVisibility(id, View.VISIBLE)
                views.setTextViewText(id, line.text())
                views.setTextColor(id, if (line.stuck) theme.warning else theme.onSurface)
                views.setContentDescription(
                    id,
                    context.getString(
                        if (line.stuck) {
                            R.string.agent_widget_line_stuck_description
                        } else {
                            R.string.agent_widget_line_needs_description
                        },
                        line.text(),
                    ),
                )
                val token = AgentStatusStore.lineToken(context, line)
                views.setOnClickPendingIntent(
                    id,
                    if (token != null) openLineIntent(context, index, token) else openDashboardIntent(context),
                )
            }
        }

        /** One count, or a dash (read out as "not known yet") while it is unknown. */
        private fun bindCount(
            context: Context,
            views: RemoteViews,
            count: Count,
            value: Int?,
            color: Int,
            theme: WidgetTheme,
            description: String?,
        ) {
            views.setTextViewText(count.number, AgentWidgetText.count(value))
            views.setTextColor(count.number, if (value == null) theme.muted else color)
            views.setTextColor(count.caption, theme.muted)
            views.setContentDescription(
                count.cell,
                description ?: context.getString(
                    R.string.agent_widget_count_unknown_description,
                    context.getString(count.captionText),
                ),
            )
        }

        /**
         * Claude's 5-hour and weekly limits as rings, coloured by level
         * (accent, warning from 80 %, urgent from 95 %); tapping them opens
         * usage. Hidden when the app has no limits to show. The 2x1 layout
         * has only the 5-hour ring (RemoteViews fail on a missing view).
         */
        private fun bindRings(
            context: Context,
            views: RemoteViews,
            snapshot: AgentStatusSnapshot?,
            theme: WidgetTheme,
            small: Boolean,
            weekRing: Boolean,
        ) {
            val now = System.currentTimeMillis()
            val sizePx = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                RING_SIZE_DP,
                context.resources.displayMetrics,
            ).toInt()
            for (ring in rings) {
                if (small && ring.label != "5h") continue
                val limit = snapshot?.limit(ring.label)
                val shown = limit != null && (weekRing || ring.label == "5h")
                views.setViewVisibility(ring.frame, if (shown) View.VISIBLE else View.GONE)
                if (!shown || limit == null) continue
                val percent = limit.percentAt(now)
                views.setImageViewBitmap(
                    ring.image,
                    RingBitmap.create(percent, theme.border, theme.ringColor(limit.levelAt(now)), sizePx),
                )
                views.setTextViewText(ring.text, percent.toString())
                views.setTextColor(ring.text, theme.onSurface)
                val caption = context.getString(
                    if (ring.label == "5h") R.string.agent_widget_limit_5h else R.string.agent_widget_limit_7d,
                )
                views.setContentDescription(
                    ring.frame,
                    context.getString(R.string.agent_widget_limit_description, caption, percent),
                )
                views.setOnClickPendingIntent(ring.frame, openUsageIntent(context))
            }
        }

        /** The activity intent that opens the app on [target]. */
        private fun launchIntent(context: Context, action: String, target: String): Intent =
            Intent(context, MainActivity::class.java).apply {
                this.action = action
                putExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET, target)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }

        /** Launches (or brings back) the app on the agents dashboard. */
        fun dashboardIntent(context: Context): Intent =
            launchIntent(context, AgentStatusStore.ACTION_OPEN_AGENTS, AgentStatusStore.LAUNCH_TARGET_DASHBOARD)

        fun openDashboardIntent(context: Context): PendingIntent =
            pending(context, REQUEST_OPEN_DASHBOARD, dashboardIntent(context))

        private fun openUsageIntent(context: Context): PendingIntent = pending(
            context,
            REQUEST_OPEN_USAGE,
            launchIntent(context, AgentStatusStore.ACTION_OPEN_USAGE, AgentStatusStore.LAUNCH_TARGET_USAGE),
        )

        /**
         * A line's tap: only its token, never the agent itself (see
         * [WidgetLineGuard]). One request code per slot so the extras of
         * different lines never merge.
         */
        private fun openLineIntent(context: Context, index: Int, token: String): PendingIntent = pending(
            context,
            REQUEST_OPEN_LINE + index,
            launchIntent(context, AgentStatusStore.ACTION_OPEN_AGENT_LINE, AgentStatusStore.LAUNCH_TARGET_AGENT)
                .putExtra(AgentStatusStore.EXTRA_LINE_TOKEN, token),
        )

        private fun pending(context: Context, requestCode: Int, intent: Intent): PendingIntent =
            PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private const val REQUEST_OPEN_DASHBOARD = 3001
        private const val REQUEST_OPEN_USAGE = 3002
        private const val REQUEST_OPEN_LINE = 3010
    }
}
