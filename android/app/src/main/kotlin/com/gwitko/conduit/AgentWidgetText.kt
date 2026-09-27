package com.gwitko.conduit

import android.content.res.Resources

/** The widget's and tile's wording of the dashboard counts. */
object AgentWidgetText {
    /** "2 need you · 1 stuck": the parts that are not zero. */
    fun newsLine(resources: Resources, dashboard: WidgetDashboard): String {
        val stuck = dashboard.stuck ?: 0
        return listOfNotNull(
            if (dashboard.needsYou > 0) {
                resources.getQuantityString(R.plurals.agent_widget_n_need_you, dashboard.needsYou, dashboard.needsYou)
            } else {
                null
            },
            if (stuck > 0) resources.getString(R.string.agent_widget_n_stuck, stuck) else null,
        ).joinToString(" · ")
    }

    /** A count, or a dash while it is unknown. */
    fun count(value: Int?): String = value?.toString() ?: "–"
}
