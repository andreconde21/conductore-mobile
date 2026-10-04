package com.gwitko.conduit

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * The one ongoing, silent status notification of the "Ongoing + urgent"
 * mode (CON-074): every agent on one line, updated in place.
 *
 * It shares its id and channel with [BackgroundConnectionService]'s
 * notification: while the service runs (live sessions in the background)
 * the status is the service's notification, so there is only ever one.
 * Without the service it is posted as a plain ongoing notification, and
 * when the service stops it is detached and kept. Tapping it opens the
 * agents dashboard. Without a status the service shows its session count.
 */
object AgentOngoingNotification {
    const val NOTIFICATION_ID = 1001
    const val CHANNEL_ID = "ssh_sessions"

    /**
     * A status nobody refreshed goes after this long (Dart re-sends an
     * unchanged one every ten minutes), so a killed app leaves no stale
     * list behind. Not applied to the service's notification.
     */
    private const val TIMEOUT_MS = 30L * 60 * 1000

    /** What Dart sent ([AgentOngoingStatus] in agent_urgent_notifications.dart). */
    data class Status(
        val title: String,
        val text: String,
        val lines: List<String>,
        val publicTitle: String,
    ) {
        companion object {
            fun fromMap(map: Map<*, *>): Status? {
                val title = map["title"] as? String ?: return null
                return Status(
                    title = title,
                    text = map["text"] as? String ?: "",
                    lines = (map["lines"] as? List<*>)?.filterIsInstance<String>() ?: emptyList(),
                    publicTitle = map["publicTitle"] as? String ?: "Conductore",
                )
            }
        }
    }

    @Volatile
    var status: Status? = null
        private set

    /** The service's session count while it runs; null otherwise. */
    @Volatile
    var serviceSessions: Int? = null

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Status",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "One silent notification: your agents' progress and the sessions " +
                "kept running in the background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /** Makes [status] the status notification (null removes it, or leaves the service's). */
    @Synchronized
    fun update(context: Context, status: Status?) {
        this.status = status
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val sessions = serviceSessions
        if (status == null && sessions == null) {
            manager.cancel(NOTIFICATION_ID)
            return
        }
        if (!mayPost(context)) return
        ensureChannel(context)
        manager.notify(NOTIFICATION_ID, build(context, sessions))
    }

    /**
     * The notification for the current status; [sessions] is the service's
     * count while it runs (it is then the service's notification).
     */
    fun build(context: Context, sessions: Int?): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder.setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
        val status = status
        val sessionLine = sessions?.let { "$it active ${if (it == 1) "session" else "sessions"}" }
        if (status == null) {
            return builder
                .setContentTitle("Conductore")
                .setContentText(sessionLine ?: "")
                .setContentIntent(launch(context, dashboard = false))
                .build()
        }
        val style = Notification.InboxStyle().setBigContentTitle(status.title)
        for (line in status.lines) style.addLine(line)
        sessionLine?.let { style.setSummaryText(it) }
        builder
            .setContentTitle(status.title)
            .setContentText(status.text)
            .setStyle(style)
            .setContentIntent(launch(context, dashboard = true))
            // Project names, tools and message lines: only counts on a
            // secure lock screen.
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(
                (
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Notification.Builder(context, CHANNEL_ID)
                    } else {
                        @Suppress("DEPRECATION")
                        Notification.Builder(context)
                    }
                    )
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(status.publicTitle)
                    .setContentText("Open Conductore for details")
                    .build(),
            )
        if (sessions == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(TIMEOUT_MS)
        }
        return builder.build()
    }

    private fun launch(context: Context, dashboard: Boolean): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (dashboard) {
                putExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET, AgentStatusStore.LAUNCH_TARGET_DASHBOARD)
            }
        }
        return PendingIntent.getActivity(
            context,
            if (dashboard) NOTIFICATION_ID else 0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun mayPost(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
}
