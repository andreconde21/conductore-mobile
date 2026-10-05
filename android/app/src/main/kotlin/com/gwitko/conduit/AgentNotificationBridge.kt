package com.gwitko.conduit

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/**
 * `conduit/agent_notifications` method channel.
 *
 * Dart -> native:
 * - `show(id, title, body)`: plain notification (the usage alert; tap opens
 *   the app). `cancel(id)` dismisses it.
 * - `showAgents(hostId, notifications)`: the agent notifications of one
 *   host, one per agent ([AgentNotificationModel.Spec]), posted or updated
 *   in place; the host's others are removed. The buttons answer each
 *   agent's first pending request.
 * - `showAgent(...)`: posts or updates one agent's notification.
 * - `cancelAgent(key)`: removes one agent's notification.
 * - `showStatus(status)`: the ongoing status notification listing every
 *   agent ([AgentOngoingNotification]); a null status removes it.
 * - `consumePermissionActions()` -> `List<Map>`: queued action taps, cleared.
 * - `consumeOpenAgent()` -> `Map?`: the agent a tapped notification points
 *   at (`hostId`, `agentId`, `workspaceId`, `tabId`, `paneId`), cleared.
 *
 * Plain and agent notifications take the same optional `open*` arguments;
 * tapping the notification body then opens the app at that agent (its
 * Herdr workspace, tab and pane). Agent notifications share one group
 * whose summary ("3 agents need you") opens the agents dashboard.
 *
 * Native -> Dart:
 * - `permissionActionAvailable()` -> `bool`: an action was tapped while the
 *   engine runs; Dart answers whether it is completing it now (false while
 *   the app is locked or not yet listening).
 * - `openAgentAvailable()`: a notification body was tapped while the engine
 *   runs; Dart calls `consumeOpenAgent`.
 * - `launcherAction(action)` -> `{ok, error}`: an answer from the launcher
 *   ([LauncherDetailsProvider.call]); null when Dart cannot take it now.
 *
 * Besides Allow / Deny / Always, an agent notification may carry answer
 * buttons (a single-choice question), a Reply with an inline text field
 * (typed into the agent) and an Open button (CON-074).
 *
 * Action taps go through [AgentPermissionActionReceiver], which queues the
 * tap durably and pings Dart when the engine is alive. When the engine goes
 * away gracefully the agent notifications with buttons are re-posted
 * with actions that launch the app instead (Android 12+ forbids starting an
 * activity from a notification's broadcast receiver), and Dart drains the
 * queue after the next start.
 */
class AgentNotificationBridge : FlutterPlugin, ActivityAware, PluginRegistry.NewIntentListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
        // Per-request notifications of an earlier build go; Dart re-posts
        // what is still pending, one per agent, once it polls.
        AgentNotificationStore.migrate(flutterPluginBinding.applicationContext)
        active = this
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        if (active === this) active = null
        channel?.setMethodCallHandler(null)
        channel = null
        // Nobody is listening for broadcast actions any more: make the
        // buttons launch the app instead.
        context?.let {
            AgentNotificationStore.repostForLaunch(it)
            // Nobody updates the status any more.
            AgentOngoingNotification.update(it, null)
        }
        context = null
    }

    override fun onAttachedToActivity(activityPluginBinding: ActivityPluginBinding) {
        binding = activityPluginBinding
        activityPluginBinding.addOnNewIntentListener(this)
        // A cold start from a re-posted action: queue it for Dart.
        stashLaunchAction(activityPluginBinding.activity.intent)
        // A cold start from a notification body tap: Dart consumes it once
        // its listener mounts (after the app lock).
        stashOpenAgent(activityPluginBinding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(activityPluginBinding: ActivityPluginBinding) {
        binding = activityPluginBinding
        activityPluginBinding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
        binding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        if (stashOpenAgent(intent)) {
            channel?.invokeMethod("openAgentAvailable", null)
        }
        if (!stashLaunchAction(intent)) return false
        channel?.invokeMethod("permissionActionAvailable", null)
        return true
    }

    /** Remembers the agent a notification body tap points at, if any. */
    private fun stashOpenAgent(intent: Intent?): Boolean {
        val target = AgentNotificationStore.openTargetFromIntent(intent) ?: return false
        pendingOpen = target
        for (key in AgentNotificationStore.OPEN_EXTRAS) intent?.removeExtra(key)
        return true
    }

    /** Queues the action an activity-launching notification button carried, if any. */
    private fun stashLaunchAction(intent: Intent?): Boolean {
        val ctx = context ?: return false
        val action = AgentNotificationStore.actionFromIntent(intent) ?: return false
        for (key in AgentNotificationStore.ACTION_EXTRAS) intent?.removeExtra(key)
        // MainActivity is exported: only the app's own buttons, carrying the
        // token of a notification it posted, may decide anything.
        if (!AgentNotificationStore.claimAction(ctx, action)) return false
        AgentNotificationStore.enqueueAction(ctx, action)
        AgentNotificationStore.showSending(ctx, action)
        return true
    }

    /**
     * Called by the receiver while the engine runs. When Dart cannot take the
     * tap now (app locked, listener not mounted yet) the notification asks
     * the user to open the app; the tap stays queued either way.
     */
    fun notifyActionAvailable(context: Context, action: AgentNotificationStore.PermissionAction) {
        val channel = channel
        if (channel == null) {
            AgentNotificationStore.showOpenToFinish(context, action)
            return
        }
        channel.invokeMethod(
            "permissionActionAvailable",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result != true) AgentNotificationStore.showOpenToFinish(context, action)
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    AgentNotificationStore.showOpenToFinish(context, action)
                }

                override fun notImplemented() {
                    AgentNotificationStore.showOpenToFinish(context, action)
                }
            },
        )
    }

    /**
     * Hands a launcher answer to Dart (main thread); [done] gets its
     * outcome, or null when Dart cannot take it (locked, not listening).
     */
    fun launcherAction(action: Map<String, String>, done: (LauncherActions.Outcome?) -> Unit) {
        val channel = channel ?: return done(null)
        channel.invokeMethod(
            "launcherAction",
            action,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val map = result as? Map<*, *> ?: return done(null)
                    done(LauncherActions.Outcome(ok = map["ok"] == true, error = map["error"] as? String))
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    done(LauncherActions.Outcome(ok = false, error = errorMessage ?: "Conductore could not send it"))
                }

                override fun notImplemented() = done(null)
            },
        )
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("detached", "Channel is not attached to an engine", null)
            return
        }
        when (call.method) {
            "show" -> {
                AgentNotificationStore.showPlain(
                    ctx,
                    call.argument<String>("id") ?: "",
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    AgentNotificationStore.OpenTarget.fromCall(call),
                )
                result.success(null)
            }
            "consumeOpenAgent" -> {
                val target = pendingOpen
                pendingOpen = null
                result.success(target?.toMap())
            }
            "showAgents" -> {
                val specs = (call.argument<List<*>>("notifications") ?: emptyList<Any>())
                    .mapNotNull { (it as? Map<*, *>)?.let(AgentNotificationModel.Spec::fromMap) }
                AgentNotificationStore.showAgents(ctx, call.argument<String>("hostId") ?: "", specs)
                result.success(null)
            }
            "showAgent" -> {
                val spec = (call.arguments as? Map<*, *>)?.let(AgentNotificationModel.Spec::fromMap)
                if (spec != null) AgentNotificationStore.showAgent(ctx, spec)
                result.success(null)
            }
            "cancelAgent" -> {
                AgentNotificationStore.cancelAgent(ctx, call.argument<String>("key") ?: "")
                result.success(null)
            }
            "cancel" -> {
                AgentNotificationStore.cancel(ctx, call.argument<String>("id") ?: "")
                result.success(null)
            }
            "showStatus" -> {
                val status = (call.argument<Map<*, *>>("status"))?.let(AgentOngoingNotification.Status::fromMap)
                AgentOngoingNotification.update(ctx, status)
                result.success(null)
            }
            "consumePermissionActions" -> result.success(AgentNotificationStore.consumeActions(ctx))
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "conduit/agent_notifications"

        /** The bridge attached to the running engine, if any. */
        @Volatile
        var active: AgentNotificationBridge? = null
            private set

        /** The last tapped notification's agent, until Dart consumes it. */
        @Volatile
        private var pendingOpen: AgentNotificationStore.OpenTarget? = null

        /**
         * Opens [target] the way a notification body tap does (the home-screen
         * widget's agent lines, which checked their token first): Dart
         * consumes it once its listener runs, after the app lock.
         */
        fun deliverOpen(target: AgentNotificationStore.OpenTarget) {
            pendingOpen = target
            active?.channel?.invokeMethod("openAgentAvailable", null)
        }
    }
}

/** Receives Allow / Deny / Always taps from permission notifications. */
class AgentPermissionActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = AgentNotificationStore.actionFromIntent(intent) ?: return
        if (!PermissionActionGuard.mayQueue(AgentNotificationStore.isDeviceLocked(context))) {
            // Nothing is decided from the lock screen: the buttons now open
            // the app, which the device unlock (and the app lock) guard.
            AgentNotificationStore.repostForLaunch(context, action.notificationId)
            return
        }
        if (!AgentNotificationStore.claimAction(context, action)) return
        AgentNotificationStore.enqueueAction(context, action)
        val bridge = AgentNotificationBridge.active
        if (bridge != null) {
            AgentNotificationStore.showSending(context, action)
            bridge.notifyActionAvailable(context.applicationContext, action)
        } else {
            // The engine is gone and a receiver may not start the activity
            // (notification trampoline rules): ask for one more tap.
            AgentNotificationStore.showOpenToFinish(context, action)
        }
    }
}

/** Notification building plus the durable queue of tapped actions. */
object AgentNotificationStore {
    /** Where a notification body tap should take the app. */
    data class OpenTarget(
        val hostId: String,
        val agentId: String,
        val workspaceId: String,
        val tabId: String,
        val paneId: String,
    ) {
        fun toMap(): Map<String, String> = mapOf(
            "hostId" to hostId,
            "agentId" to agentId,
            "workspaceId" to workspaceId,
            "tabId" to tabId,
            "paneId" to paneId,
        )

        fun toJson(): JSONObject = JSONObject(toMap())

        fun putInto(intent: Intent) {
            intent.putExtra(EXTRA_OPEN_HOST_ID, hostId)
            intent.putExtra(EXTRA_OPEN_AGENT_ID, agentId)
            intent.putExtra(EXTRA_OPEN_WORKSPACE_ID, workspaceId)
            intent.putExtra(EXTRA_OPEN_TAB_ID, tabId)
            intent.putExtra(EXTRA_OPEN_PANE_ID, paneId)
        }

        companion object {
            fun fromCall(call: MethodCall): OpenTarget? {
                val hostId = call.argument<String>("openHostId")
                if (hostId.isNullOrEmpty()) return null
                return OpenTarget(
                    hostId = hostId,
                    agentId = call.argument<String>("openAgentId") ?: "",
                    workspaceId = call.argument<String>("openWorkspaceId") ?: "",
                    tabId = call.argument<String>("openTabId") ?: "",
                    paneId = call.argument<String>("openPaneId") ?: "",
                )
            }

            fun fromJson(json: JSONObject?): OpenTarget? {
                if (json == null) return null
                val hostId = json.optString("hostId")
                if (hostId.isEmpty()) return null
                return OpenTarget(
                    hostId = hostId,
                    agentId = json.optString("agentId"),
                    workspaceId = json.optString("workspaceId"),
                    tabId = json.optString("tabId"),
                    paneId = json.optString("paneId"),
                )
            }
        }
    }

    data class PermissionAction(
        val notificationId: String,
        val hostId: String,
        val requestId: String,
        val verdict: String,
        val title: String,
        val body: String,
        val token: String = "",
        val agentId: String = "",
        /** The answer's option label, or the Reply's text. */
        val text: String = "",
        /** The question an answer button answers. */
        val question: String = "",
    )

    private const val PREFS = "conduit_agent_notifications"
    private const val KEY_ACTIONS = "actions"
    private const val KEY_AGENTS = "agents_v2"
    private const val KEY_TOKENS = "tokens"
    private const val KEY_SCHEMA = "schema"

    /** Per-request notifications of builds before schema 2. */
    private const val KEY_LEGACY_OUTSTANDING = "outstanding"
    private const val CHANNEL_ID = "agent_attention"
    private const val TAG = AgentNotificationModel.TAG

    const val ACTION_DECIDE = "com.gwitko.conduit.action.AGENT_PERMISSION_DECIDE"
    const val EXTRA_NOTIFICATION_ID = "com.gwitko.conduit.NOTIFICATION_ID"
    const val EXTRA_HOST_ID = "com.gwitko.conduit.HOST_ID"
    const val EXTRA_AGENT_ID = "com.gwitko.conduit.AGENT_ID"
    const val EXTRA_REQUEST_ID = "com.gwitko.conduit.REQUEST_ID"
    const val EXTRA_VERDICT = "com.gwitko.conduit.VERDICT"
    const val EXTRA_TITLE = "com.gwitko.conduit.TITLE"
    const val EXTRA_BODY = "com.gwitko.conduit.BODY"
    const val EXTRA_TOKEN = "com.gwitko.conduit.TOKEN"
    const val EXTRA_TEXT = "com.gwitko.conduit.TEXT"
    const val EXTRA_QUESTION = "com.gwitko.conduit.QUESTION"

    /** The Reply button's inline text field. */
    const val KEY_REPLY = "com.gwitko.conduit.REPLY_TEXT"
    val ACTION_EXTRAS = listOf(
        EXTRA_NOTIFICATION_ID, EXTRA_HOST_ID, EXTRA_AGENT_ID, EXTRA_REQUEST_ID, EXTRA_VERDICT, EXTRA_TITLE,
        EXTRA_BODY, EXTRA_TOKEN, EXTRA_TEXT, EXTRA_QUESTION,
    )
    const val EXTRA_OPEN_HOST_ID = "com.gwitko.conduit.OPEN_HOST_ID"
    const val EXTRA_OPEN_AGENT_ID = "com.gwitko.conduit.OPEN_AGENT_ID"
    const val EXTRA_OPEN_WORKSPACE_ID = "com.gwitko.conduit.OPEN_WORKSPACE_ID"
    const val EXTRA_OPEN_TAB_ID = "com.gwitko.conduit.OPEN_TAB_ID"
    const val EXTRA_OPEN_PANE_ID = "com.gwitko.conduit.OPEN_PANE_ID"
    val OPEN_EXTRAS = listOf(
        EXTRA_OPEN_HOST_ID, EXTRA_OPEN_AGENT_ID, EXTRA_OPEN_WORKSPACE_ID, EXTRA_OPEN_TAB_ID,
        EXTRA_OPEN_PANE_ID,
    )
    private val VERDICT_LABELS = mapOf("allow" to "Allow", "deny" to "Deny", "always" to "Always")

    /** The label of the button that only opens the agent, like the body. */
    private const val OPEN_LABEL = "Open"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun manager(context: Context): NotificationManager? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Agent attention",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "One notification per coding agent: what it needs now, " +
                    "or that it finished."
            }
            manager.createNotificationChannel(channel)
        }
        return manager
    }

    private fun builder(context: Context): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder.setSmallIcon(R.mipmap.ic_launcher)
    }

    /**
     * Texts carry request summaries and the agent's message: on a secure
     * lock screen show only [publicTitle] (the agent's label at most).
     */
    private fun Notification.Builder.lockScreenSafe(context: Context, publicTitle: String): Notification.Builder {
        setVisibility(Notification.VISIBILITY_PRIVATE)
        setPublicVersion(
            builder(context)
                .setContentTitle(publicTitle)
                .setContentText("Open Conductore for details")
                .build(),
        )
        return this
    }

    /** Sound and vibration only for [alert]; any other post is silent. */
    private fun Notification.Builder.inAgentGroup(alert: Boolean): Notification.Builder {
        setGroup(AgentNotificationModel.GROUP_KEY)
        setOnlyAlertOnce(!alert)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // A group child with the SUMMARY behaviour never alerts.
            setGroupAlertBehavior(
                if (alert) Notification.GROUP_ALERT_CHILDREN else Notification.GROUP_ALERT_SUMMARY,
            )
        }
        return this
    }

    private fun launchIntent(context: Context, requestCode: Int, extras: Intent.() -> Unit = {}): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            extras()
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * The body tap: opens the app, at [open]'s agent when given. Each
     * notification gets its own request code so their extras never merge.
     */
    private fun contentIntent(context: Context, id: String, open: OpenTarget?): PendingIntent {
        if (open == null) return launchIntent(context, 0)
        return launchIntent(context, ("open:" + id).hashCode()) { open.putInto(this) }
    }

    fun openTargetFromIntent(intent: Intent?): OpenTarget? {
        if (intent == null) return null
        val hostId = intent.getStringExtra(EXTRA_OPEN_HOST_ID)
        if (hostId.isNullOrEmpty()) return null
        return OpenTarget(
            hostId = hostId,
            agentId = intent.getStringExtra(EXTRA_OPEN_AGENT_ID) ?: "",
            workspaceId = intent.getStringExtra(EXTRA_OPEN_WORKSPACE_ID) ?: "",
            tabId = intent.getStringExtra(EXTRA_OPEN_TAB_ID) ?: "",
            paneId = intent.getStringExtra(EXTRA_OPEN_PANE_ID) ?: "",
        )
    }

    fun showPlain(context: Context, id: String, title: String, body: String, open: OpenTarget? = null) {
        val manager = manager(context) ?: return
        val notification = builder(context)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .lockScreenSafe(context, title)
            .setContentIntent(contentIntent(context, id, open))
            .setAutoCancel(true)
            .build()
        manager.notify(AgentNotificationModel.PLAIN_TAG, id.hashCode(), notification)
    }

    fun cancel(context: Context, id: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(AgentNotificationModel.PLAIN_TAG, id.hashCode())
        // A queued tap of an older build names its per-request notification.
        manager.cancel(AgentNotificationModel.LEGACY_TAG, id.hashCode())
    }

    /** Makes [specs] the agent notifications of [hostId]. */
    @Synchronized
    fun showAgents(context: Context, hostId: String, specs: List<AgentNotificationModel.Spec>) {
        val stored = agents(context)
        val (kept, removed) = AgentNotificationModel.sync(stored, hostId, specs)
        val manager = context.getSystemService(NotificationManager::class.java)
        for (key in removed) {
            manager?.cancel(TAG, AgentNotificationModel.notificationId(key))
            forgetToken(context, key)
        }
        val posted = kept.toMutableMap()
        val shown = HashSet<String>()
        for (spec in specs) {
            val result = post(context, spec, stored[spec.key], launchApp = false) ?: continue
            posted[spec.key] = result
            shown.add(spec.key)
        }
        saveAgents(context, posted)
        refreshSummary(context, shown = shown, removed = removed.toSet())
    }

    /** Posts or updates one agent's notification. */
    @Synchronized
    fun showAgent(context: Context, spec: AgentNotificationModel.Spec) {
        val stored = agents(context).toMutableMap()
        val result = post(context, spec, stored[spec.key], launchApp = false)
        stored[spec.key] = result ?: spec
        saveAgents(context, stored)
        refreshSummary(context, shown = if (result != null) setOf(spec.key) else emptySet())
    }

    @Synchronized
    fun cancelAgent(context: Context, key: String) {
        val stored = agents(context).toMutableMap()
        stored.remove(key)
        saveAgents(context, stored)
        forgetToken(context, key)
        context.getSystemService(NotificationManager::class.java)
            ?.cancel(TAG, AgentNotificationModel.notificationId(key))
        refreshSummary(context, removed = setOf(key))
    }

    /**
     * Posts [spec] unless [AgentNotificationModel.post] skips it; returns it
     * as stored (with its shade position), or null when not posted. While
     * the engine runs the buttons broadcast to [AgentPermissionActionReceiver];
     * with [launchApp], and always below Android 12, they open the app
     * carrying the action instead (see [PermissionActionGuard]). From
     * Android 12 on a button only fires once the device is unlocked.
     */
    private fun post(
        context: Context,
        spec: AgentNotificationModel.Spec,
        previous: AgentNotificationModel.Spec?,
        launchApp: Boolean,
    ): AgentNotificationModel.Spec? {
        val manager = manager(context) ?: return null
        val id = AgentNotificationModel.notificationId(spec.key)
        val decision = AgentNotificationModel.post(spec, previous, isShowing(manager, id))
        if (decision == AgentNotificationModel.Post.SKIP) return null
        val alert = decision == AgentNotificationModel.Post.ALERT
        val postedAt = AgentNotificationModel.postedAt(decision, previous, System.currentTimeMillis())
        val style = Notification.InboxStyle().setBigContentTitle(spec.title)
        for (line in spec.lines) style.addLine(line)
        val builder = builder(context)
            .setContentTitle(spec.title)
            .setContentText(spec.text)
            .setStyle(style)
            .lockScreenSafe(context, spec.publicTitle)
            .setContentIntent(contentIntent(context, spec.key, spec.open))
            .setAutoCancel(spec.action == null)
            .setWhen(postedAt)
            .setShowWhen(true)
            .inAgentGroup(alert)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O && spec.needsYou) {
            // Channels carry the importance from O on.
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_HIGH)
        }
        val verdicts = AgentNotificationModel.verdicts(spec)
        val answers = AgentNotificationModel.answerPayloads(spec)
        val launch = PermissionActionGuard.buttonsLaunchApp(
            Build.VERSION.SDK_INT,
            engineListening = !launchApp,
        )
        // A Reply needs the running app to send it: once the engine is gone
        // the body (and Open) open the agent instead.
        val reply = if (launch) null else AgentNotificationModel.replyPayload(spec)
        if (verdicts.isEmpty() && answers.isEmpty() && reply == null) {
            forgetToken(context, spec.key)
        } else {
            val token = issueToken(context, spec)
            for ((verdict, label) in verdicts) {
                val payload = AgentNotificationModel.buttonPayload(spec, verdict) ?: continue
                builder.addAction(button(context, spec, payload, label, token, launch))
            }
            for ((index, payload) in answers.withIndex()) {
                builder.addAction(button(context, spec, payload, payload.text, token, launch, index))
            }
            if (reply != null) builder.addAction(replyButton(context, spec, reply, token))
        }
        if (spec.reviewAll || spec.openButton) {
            // Opens the agent, like the body: nothing is decided.
            @Suppress("DEPRECATION")
            val open = Notification.Action.Builder(
                0,
                if (spec.reviewAll) "Review all" else OPEN_LABEL,
                launchIntent(context, (spec.key + ":review").hashCode()) { spec.open?.putInto(this) },
            )
            builder.addAction(open.build())
        }
        manager.notify(TAG, id, builder.build())
        return spec.copy(postedAt = postedAt)
    }

    private fun button(
        context: Context,
        spec: AgentNotificationModel.Spec,
        payload: AgentNotificationModel.ButtonPayload,
        label: String,
        token: String,
        launch: Boolean,
        index: Int = 0,
    ): Notification.Action {
        val requestCode = (payload.notificationId + payload.verdict + index).hashCode()
        val fill = fillAction(spec, payload, token)
        val pending = if (launch) {
            launchIntent(context, requestCode, fill)
        } else {
            val intent = Intent(context, AgentPermissionActionReceiver::class.java).apply {
                action = ACTION_DECIDE
                // Distinct data per button so the system never merges the
                // PendingIntents.
                data = Uri.parse(
                    "conductore://decide/${Uri.encode(payload.notificationId)}/${payload.verdict}/$index",
                )
                fill()
            }
            PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        // The int-icon builder is deprecated but the only one below API 23;
        // notification actions show no icon on modern Android anyway.
        @Suppress("DEPRECATION")
        val button = Notification.Action.Builder(0, label, pending)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Allow / Deny / Always decide for the host (Always for good):
            // never from a locked phone.
            button.setAuthenticationRequired(true)
        }
        return button.build()
    }

    private fun fillAction(
        spec: AgentNotificationModel.Spec,
        payload: AgentNotificationModel.ButtonPayload,
        token: String,
    ): Intent.() -> Unit = {
        putExtra(EXTRA_NOTIFICATION_ID, payload.notificationId)
        putExtra(EXTRA_HOST_ID, payload.hostId)
        putExtra(EXTRA_AGENT_ID, payload.agentId)
        putExtra(EXTRA_REQUEST_ID, payload.requestId)
        putExtra(EXTRA_VERDICT, payload.verdict)
        putExtra(EXTRA_TITLE, spec.title)
        putExtra(EXTRA_BODY, spec.text)
        putExtra(EXTRA_TOKEN, token)
        putExtra(EXTRA_TEXT, payload.text)
        putExtra(EXTRA_QUESTION, payload.question)
    }

    /**
     * Reply: an inline text field whose text the receiver queues for Dart,
     * which types it into the agent. Android fills the field's result into
     * the intent, so its PendingIntent must be mutable.
     */
    private fun replyButton(
        context: Context,
        spec: AgentNotificationModel.Spec,
        payload: AgentNotificationModel.ButtonPayload,
        token: String,
    ): Notification.Action {
        val fill = fillAction(spec, payload, token)
        val intent = Intent(context, AgentPermissionActionReceiver::class.java).apply {
            action = ACTION_DECIDE
            data = Uri.parse("conductore://reply/${Uri.encode(payload.notificationId)}")
            fill()
        }
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pending = PendingIntent.getBroadcast(
            context,
            (payload.notificationId + payload.verdict).hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or mutable,
        )
        val input = RemoteInput.Builder(KEY_REPLY).setLabel("Message to the agent").build()
        @Suppress("DEPRECATION")
        val button = Notification.Action.Builder(0, "Reply", pending).addRemoteInput(input)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Typed into the agent: never from a locked phone.
            button.setAuthenticationRequired(true)
        }
        return button.build()
    }

    /** Whether notification [id] is in the shade; null when Android cannot tell. */
    private fun isShowing(manager: NotificationManager, id: Int): Boolean? {
        val ids = showingIds(manager) ?: return null
        return id in ids
    }

    private fun showingIds(manager: NotificationManager): Set<Int>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return try {
            manager.activeNotifications.filter { it.tag == TAG }.map { it.id }.toSet()
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Posts or removes the group summary over the agent notifications in
     * the shade ([shown] were just posted, [removed] just cancelled: the
     * system may not list those changes yet). Tapping it opens the agents
     * dashboard.
     */
    private fun refreshSummary(context: Context, shown: Set<String> = emptySet(), removed: Set<String> = emptySet()) {
        val manager = manager(context) ?: return
        val showingIds = showingIds(manager)
        val showing = agents(context).values.filter {
            it.key !in removed &&
                (it.key in shown || showingIds == null || AgentNotificationModel.notificationId(it.key) in showingIds)
        }
        val summary = AgentNotificationModel.summary(showing)
        if (summary == null) {
            manager.cancel(TAG, AgentNotificationModel.summaryId)
            return
        }
        val style = Notification.InboxStyle().setBigContentTitle(summary.title)
        for (line in summary.lines.take(6)) style.addLine(line)
        val dashboard = launchIntent(context, AgentNotificationModel.summaryId) {
            putExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET, AgentStatusStore.LAUNCH_TARGET_DASHBOARD)
        }
        val builder = builder(context)
            .setContentTitle(summary.title)
            .setContentText(summary.lines.joinToString(", "))
            .setStyle(style)
            .setNumber(summary.count)
            .lockScreenSafe(context, summary.publicTitle)
            .setContentIntent(dashboard)
            .setAutoCancel(false)
            .setGroup(AgentNotificationModel.GROUP_KEY)
            .setGroupSummary(true)
            .setOnlyAlertOnce(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // The children alert; the summary never does.
            builder.setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
        }
        manager.notify(TAG, AgentNotificationModel.summaryId, builder.build())
    }

    /** Replaces the buttons with a "sending" line so a second tap cannot double-decide. */
    fun showSending(context: Context, action: PermissionAction) {
        showStatus(context, action, "Sending ${label(action)}…", launchOnTap = false)
    }

    /** The engine is gone: the queued tap completes once the app is opened. */
    fun showOpenToFinish(context: Context, action: PermissionAction) {
        showStatus(context, action, "Tap to open Conductore and finish: ${label(action)}", launchOnTap = true)
    }

    private fun label(action: PermissionAction) = when (action.verdict) {
        AgentNotificationModel.ANSWER -> "“${action.text}”"
        AgentNotificationModel.REPLY -> "your reply"
        else -> VERDICT_LABELS[action.verdict] ?: action.verdict
    }

    /** The agent's notification without buttons, saying where its tap stands. */
    @Synchronized
    private fun showStatus(context: Context, action: PermissionAction, text: String, launchOnTap: Boolean) {
        val stored = agents(context).toMutableMap()
        val spec = stored[action.notificationId]
        if (spec != null) {
            // Answered: a re-post (the engine going away) must not bring
            // the buttons back.
            stored[spec.key] = spec.copy(
                action = null,
                reviewAll = false,
                answers = emptyList(),
                reply = false,
                openButton = false,
            )
            saveAgents(context, stored)
        }
        val manager = manager(context) ?: return
        val title = spec?.title ?: action.title
        val builder = builder(context)
            .setContentTitle(title)
            .setContentText(text)
            .lockScreenSafe(context, spec?.publicTitle ?: "Conductore")
            .setContentIntent(
                if (launchOnTap) launchIntent(context, action.notificationId.hashCode()) else launchIntent(context, 0),
            )
            .setAutoCancel(launchOnTap)
            .inAgentGroup(alert = false)
        if (spec != null && spec.postedAt != 0L) builder.setWhen(spec.postedAt)
        // A tap queued by an older build names its per-request notification.
        val tag = if (spec != null || action.agentId.isNotEmpty()) TAG else AgentNotificationModel.LEGACY_TAG
        manager.notify(tag, action.notificationId.hashCode(), builder.build())
    }

    /** Re-posts agent notification [key] with app-launching buttons. */
    @Synchronized
    fun repostForLaunch(context: Context, key: String) {
        val spec = agents(context)[key] ?: return
        post(context, spec.copy(alert = false), spec, launchApp = true)
    }

    /** Re-posts every agent notification with buttons, with app-launching ones. */
    @Synchronized
    fun repostForLaunch(context: Context) {
        for (spec in agents(context).values) {
            if (spec.action != null || spec.reply) post(context, spec.copy(alert = false), spec, launchApp = true)
        }
    }

    fun isDeviceLocked(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java) ?: return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            keyguard.isDeviceLocked
        } else {
            keyguard.isKeyguardLocked && keyguard.isKeyguardSecure
        }
    }

    fun actionFromIntent(intent: Intent?): PermissionAction? {
        val hostId = intent?.getStringExtra(EXTRA_HOST_ID) ?: return null
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return null
        val verdict = intent.getStringExtra(EXTRA_VERDICT) ?: return null
        val text = if (verdict == AgentNotificationModel.REPLY) {
            RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_REPLY)?.toString()
                ?: intent.getStringExtra(EXTRA_TEXT)
        } else {
            intent.getStringExtra(EXTRA_TEXT)
        }
        return PermissionAction(
            notificationId = intent.getStringExtra(EXTRA_NOTIFICATION_ID) ?: "",
            hostId = hostId,
            requestId = requestId,
            verdict = verdict,
            title = intent.getStringExtra(EXTRA_TITLE) ?: "",
            body = intent.getStringExtra(EXTRA_BODY) ?: "",
            token = intent.getStringExtra(EXTRA_TOKEN) ?: "",
            agentId = intent.getStringExtra(EXTRA_AGENT_ID) ?: "",
            text = text ?: "",
            question = intent.getStringExtra(EXTRA_QUESTION) ?: "",
        )
    }

    /**
     * Cancels the per-request notifications of builds before schema 2 once:
     * everything still showing under the old tag, and the ids the old build
     * remembered. Their buttons' tokens go too, so none of them decides
     * anything any more.
     */
    @Synchronized
    fun migrate(context: Context) {
        val prefs = prefs(context)
        if (!AgentNotificationModel.needsMigration(prefs.getInt(KEY_SCHEMA, 1))) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager != null) {
            val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    manager.activeNotifications.map { it.tag to it.id }
                } catch (_: Exception) {
                    emptyList()
                }
            } else {
                emptyList()
            }
            for (id in AgentNotificationModel.legacyCancellations(active, legacyIds(context))) {
                manager.cancel(AgentNotificationModel.LEGACY_TAG, id)
            }
        }
        prefs.edit()
            .remove(KEY_LEGACY_OUTSTANDING)
            .remove(KEY_TOKENS)
            .putInt(KEY_SCHEMA, AgentNotificationModel.SCHEMA)
            .apply()
    }

    /** The notification ids an older build remembered (outstanding requests and tokens). */
    private fun legacyIds(context: Context): List<String> {
        val ids = ArrayList<String>()
        try {
            val outstanding = JSONArray(prefs(context).getString(KEY_LEGACY_OUTSTANDING, null) ?: "[]")
            for (i in 0 until outstanding.length()) {
                outstanding.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() }?.let(ids::add)
            }
        } catch (_: Exception) {
            // Unreadable: the active list still covers what shows.
        }
        ids.addAll(tokens(context).keys().asSequence().toList())
        return ids
    }

    /**
     * The random token the buttons of [spec] carry: kept while its first
     * request stays the same, new for every other one (so a button of an
     * earlier version of the notification decides nothing).
     */
    @Synchronized
    private fun issueToken(context: Context, spec: AgentNotificationModel.Spec): String {
        val requestId = AgentNotificationModel.tokenRequestId(spec) ?: return ""
        val tokens = tokens(context)
        val current = tokens.optJSONObject(spec.key)?.let(::issuedFrom)
        if (current != null && current.hostId == spec.hostId && current.requestId == requestId) {
            return current.token
        }
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val token = bytes.joinToString("") { "%02x".format(it) }
        tokens.put(
            spec.key,
            JSONObject()
                .put("token", token)
                .put("hostId", spec.hostId)
                .put("requestId", requestId),
        )
        prefs(context).edit().putString(KEY_TOKENS, tokens.toString()).apply()
        return token
    }

    /**
     * Whether [action] came from a button of a notification the app posted
     * and still shows for that request; the first tap uses the token up, so
     * a replayed or second tap decides nothing.
     */
    @Synchronized
    fun claimAction(context: Context, action: PermissionAction): Boolean {
        val tokens = tokens(context)
        val issued = tokens.optJSONObject(action.notificationId)?.let(::issuedFrom)
        if (!PermissionActionGuard.accepts(issued, action.hostId, action.requestId, action.token)) {
            return false
        }
        tokens.remove(action.notificationId)
        prefs(context).edit().putString(KEY_TOKENS, tokens.toString()).apply()
        return true
    }

    @Synchronized
    private fun forgetToken(context: Context, id: String) {
        val tokens = tokens(context)
        if (tokens.remove(id) != null) {
            prefs(context).edit().putString(KEY_TOKENS, tokens.toString()).apply()
        }
    }

    private fun issuedFrom(json: JSONObject) = PermissionActionGuard.Issued(
        token = json.optString("token"),
        hostId = json.optString("hostId"),
        requestId = json.optString("requestId"),
    )

    private fun tokens(context: Context): JSONObject {
        val raw = prefs(context).getString(KEY_TOKENS, null) ?: return JSONObject()
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    @Synchronized
    fun enqueueAction(context: Context, action: PermissionAction) {
        val queue = actionQueue(context)
        queue.put(
            JSONObject()
                .put("notificationId", action.notificationId)
                .put("hostId", action.hostId)
                .put("agentId", action.agentId)
                .put("requestId", action.requestId)
                .put("verdict", action.verdict)
                .put("text", action.text)
                .put("question", action.question),
        )
        prefs(context).edit().putString(KEY_ACTIONS, queue.toString()).apply()
    }

    @Synchronized
    fun consumeActions(context: Context): List<Map<String, String>> {
        val queue = actionQueue(context)
        prefs(context).edit().remove(KEY_ACTIONS).apply()
        val actions = ArrayList<Map<String, String>>()
        for (i in 0 until queue.length()) {
            val item = queue.optJSONObject(i) ?: continue
            actions.add(
                mapOf(
                    "notificationId" to item.optString("notificationId"),
                    "hostId" to item.optString("hostId"),
                    "agentId" to item.optString("agentId"),
                    "requestId" to item.optString("requestId"),
                    "verdict" to item.optString("verdict"),
                    "text" to item.optString("text"),
                    "question" to item.optString("question"),
                ),
            )
        }
        return actions
    }

    private fun actionQueue(context: Context): JSONArray {
        val raw = prefs(context).getString(KEY_ACTIONS, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    /** The agent notifications posted (or held back as silent), by key. */
    private fun agents(context: Context): Map<String, AgentNotificationModel.Spec> {
        val raw = prefs(context).getString(KEY_AGENTS, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            json.keys().asSequence().mapNotNull { key ->
                json.optJSONObject(key)?.let(AgentNotificationModel.Spec::fromJson)?.let { key to it }
            }.toMap()
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun saveAgents(context: Context, agents: Map<String, AgentNotificationModel.Spec>) {
        val json = JSONObject()
        for ((key, spec) in agents) json.put(key, spec.toJson())
        prefs(context).edit().putString(KEY_AGENTS, json.toString()).apply()
    }
}
