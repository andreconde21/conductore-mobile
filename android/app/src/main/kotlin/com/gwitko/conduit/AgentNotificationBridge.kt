package com.gwitko.conduit

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
 * - `show(id, title, body)`: plain agent notification (tap opens the app).
 * - `showPermissionRequest(id, title, body, hostId, requestId)`: notification
 *   with Allow / Deny / Always actions for one pending permission request.
 * - `cancel(id)`: dismiss.
 * - `consumePermissionActions()` -> `List<Map>`: queued action taps, cleared.
 * - `consumeOpenAgent()` -> `Map?`: the agent a tapped notification points
 *   at (`hostId`, `agentId`, `workspaceId`, `tabId`, `paneId`), cleared.
 *
 * `show` and `showPermissionRequest` take the same optional `open*`
 * arguments; tapping the notification body then opens the app at that
 * agent (its Herdr workspace, tab and pane).
 *
 * Native -> Dart:
 * - `permissionActionAvailable()` -> `bool`: an action was tapped while the
 *   engine runs; Dart answers whether it is completing it now (false while
 *   the app is locked or not yet listening).
 * - `openAgentAvailable()`: a notification body was tapped while the engine
 *   runs; Dart calls `consumeOpenAgent`.
 *
 * Action taps go through [AgentPermissionActionReceiver], which queues the
 * tap durably and pings Dart when the engine is alive. When the engine goes
 * away gracefully the outstanding permission notifications are re-posted
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
        // Dart re-posts whatever is still pending once it polls; anything
        // remembered from an earlier engine is stale for re-posting purposes
        // (the notifications themselves stay in the shade and still work).
        AgentNotificationStore.clearOutstanding(flutterPluginBinding.applicationContext)
        active = this
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        if (active === this) active = null
        channel?.setMethodCallHandler(null)
        channel = null
        // Nobody is listening for broadcast actions any more: make the
        // outstanding requests launch the app instead.
        context?.let { AgentNotificationStore.repostForLaunch(it) }
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
            "showPermissionRequest" -> {
                val request = AgentNotificationStore.PermissionNotification(
                    id = call.argument<String>("id") ?: "",
                    title = call.argument<String>("title") ?: "",
                    body = call.argument<String>("body") ?: "",
                    hostId = call.argument<String>("hostId") ?: "",
                    requestId = call.argument<String>("requestId") ?: "",
                    open = AgentNotificationStore.OpenTarget.fromCall(call),
                )
                AgentNotificationStore.showPermissionRequest(ctx, request, launchApp = false)
                result.success(null)
            }
            "cancel" -> {
                AgentNotificationStore.cancel(ctx, call.argument<String>("id") ?: "")
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

    data class PermissionNotification(
        val id: String,
        val title: String,
        val body: String,
        val hostId: String,
        val requestId: String,
        val open: OpenTarget? = null,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("id", id)
            .put("title", title)
            .put("body", body)
            .put("hostId", hostId)
            .put("requestId", requestId)
            .apply { open?.let { put("open", it.toJson()) } }

        companion object {
            fun fromJson(json: JSONObject) = PermissionNotification(
                id = json.optString("id"),
                title = json.optString("title"),
                body = json.optString("body"),
                hostId = json.optString("hostId"),
                requestId = json.optString("requestId"),
                open = OpenTarget.fromJson(json.optJSONObject("open")),
            )
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
    )

    private const val PREFS = "conduit_agent_notifications"
    private const val KEY_ACTIONS = "actions"
    private const val KEY_OUTSTANDING = "outstanding"
    private const val KEY_TOKENS = "tokens"
    private const val CHANNEL_ID = "agent_attention"
    private const val TAG = "conduit_agent"

    const val ACTION_DECIDE = "com.gwitko.conduit.action.AGENT_PERMISSION_DECIDE"
    const val EXTRA_NOTIFICATION_ID = "com.gwitko.conduit.NOTIFICATION_ID"
    const val EXTRA_HOST_ID = "com.gwitko.conduit.HOST_ID"
    const val EXTRA_REQUEST_ID = "com.gwitko.conduit.REQUEST_ID"
    const val EXTRA_VERDICT = "com.gwitko.conduit.VERDICT"
    const val EXTRA_TITLE = "com.gwitko.conduit.TITLE"
    const val EXTRA_BODY = "com.gwitko.conduit.BODY"
    const val EXTRA_TOKEN = "com.gwitko.conduit.TOKEN"
    val ACTION_EXTRAS = listOf(
        EXTRA_NOTIFICATION_ID, EXTRA_HOST_ID, EXTRA_REQUEST_ID, EXTRA_VERDICT, EXTRA_TITLE, EXTRA_BODY,
        EXTRA_TOKEN,
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
    val VERDICTS = listOf("allow" to "Allow", "deny" to "Deny", "always" to "Always")

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
                description = "Alerts when a monitored coding agent needs input, " +
                    "asks for permission, or finishes."
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
     * Bodies carry the agent's last message and the permission summary: on a
     * secure lock screen show only the title (Dart keeps titles to labels).
     */
    private fun Notification.Builder.lockScreenSafe(context: Context, title: String): Notification.Builder {
        setVisibility(Notification.VISIBILITY_PRIVATE)
        setPublicVersion(
            builder(context)
                .setContentTitle(title)
                .setContentText("Open Conductore for details")
                .build(),
        )
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
        // A stable per-agent id: a new state for the same agent replaces the
        // old notification instead of stacking.
        manager.notify(TAG, id.hashCode(), notification)
    }

    /**
     * Posts a permission notification with three action buttons. While the
     * engine runs the buttons broadcast to [AgentPermissionActionReceiver];
     * with [launchApp], and always below Android 12, they open the app
     * carrying the action instead (see [PermissionActionGuard]). From
     * Android 12 on a button only fires once the device is unlocked.
     */
    fun showPermissionRequest(context: Context, request: PermissionNotification, launchApp: Boolean) {
        rememberOutstanding(context, request)
        val token = issueToken(context, request)
        val launch = PermissionActionGuard.buttonsLaunchApp(
            Build.VERSION.SDK_INT,
            engineListening = !launchApp,
        )
        val manager = manager(context) ?: return
        val builder = builder(context)
            .setContentTitle(request.title)
            .setContentText(request.body)
            .setStyle(Notification.BigTextStyle().bigText(request.body))
            .lockScreenSafe(context, request.title)
            .setContentIntent(contentIntent(context, request.id, request.open))
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            // Channels carry the importance from O on.
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_HIGH)
        }
        for ((verdict, label) in VERDICTS) {
            val requestCode = (request.id + verdict).hashCode()
            val fill: Intent.() -> Unit = {
                putExtra(EXTRA_NOTIFICATION_ID, request.id)
                putExtra(EXTRA_HOST_ID, request.hostId)
                putExtra(EXTRA_REQUEST_ID, request.requestId)
                putExtra(EXTRA_VERDICT, verdict)
                putExtra(EXTRA_TITLE, request.title)
                putExtra(EXTRA_BODY, request.body)
                putExtra(EXTRA_TOKEN, token)
            }
            val pending = if (launch) {
                launchIntent(context, requestCode, fill)
            } else {
                val intent = Intent(context, AgentPermissionActionReceiver::class.java).apply {
                    action = ACTION_DECIDE
                    // Distinct data per button so the system never merges the
                    // three PendingIntents.
                    data = Uri.parse("conductore://decide/${request.id}/$verdict")
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
            builder.addAction(button.build())
        }
        manager.notify(TAG, request.id.hashCode(), builder.build())
    }

    /** Replaces the actions with a "sending" line so a second tap cannot double-decide. */
    fun showSending(context: Context, action: PermissionAction) {
        forgetOutstanding(context, action.notificationId)
        val manager = manager(context) ?: return
        val label = VERDICTS.firstOrNull { it.first == action.verdict }?.second ?: action.verdict
        val notification = builder(context)
            .setContentTitle(action.title)
            .setContentText("Sending $label…")
            .setContentIntent(launchIntent(context, 0))
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .build()
        manager.notify(TAG, action.notificationId.hashCode(), notification)
    }

    /** The engine is gone: the queued tap completes once the app is opened. */
    fun showOpenToFinish(context: Context, action: PermissionAction) {
        forgetOutstanding(context, action.notificationId)
        val manager = manager(context) ?: return
        val label = VERDICTS.firstOrNull { it.first == action.verdict }?.second ?: action.verdict
        val notification = builder(context)
            .setContentTitle(action.title)
            .setContentText("Tap to open Conductore and finish: $label")
            .setContentIntent(launchIntent(context, action.notificationId.hashCode()))
            .setAutoCancel(true)
            .build()
        manager.notify(TAG, action.notificationId.hashCode(), notification)
    }

    fun cancel(context: Context, id: String) {
        forgetOutstanding(context, id)
        forgetToken(context, id)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(TAG, id.hashCode())
    }

    /** Re-posts the outstanding notification [id] with app-launching actions. */
    fun repostForLaunch(context: Context, id: String) {
        val request = outstanding(context).firstOrNull { it.id == id } ?: return
        showPermissionRequest(context, request, launchApp = true)
    }

    fun isDeviceLocked(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java) ?: return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            keyguard.isDeviceLocked
        } else {
            keyguard.isKeyguardLocked && keyguard.isKeyguardSecure
        }
    }

    /** Re-posts every outstanding permission notification with app-launching actions. */
    fun repostForLaunch(context: Context) {
        for (request in outstanding(context)) {
            showPermissionRequest(context, request, launchApp = true)
        }
    }

    fun actionFromIntent(intent: Intent?): PermissionAction? {
        val hostId = intent?.getStringExtra(EXTRA_HOST_ID) ?: return null
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return null
        val verdict = intent.getStringExtra(EXTRA_VERDICT) ?: return null
        return PermissionAction(
            notificationId = intent.getStringExtra(EXTRA_NOTIFICATION_ID) ?: "",
            hostId = hostId,
            requestId = requestId,
            verdict = verdict,
            title = intent.getStringExtra(EXTRA_TITLE) ?: "",
            body = intent.getStringExtra(EXTRA_BODY) ?: "",
            token = intent.getStringExtra(EXTRA_TOKEN) ?: "",
        )
    }

    /**
     * The random token the buttons of notification [request] carry: kept
     * while the same request is re-posted, new for every other one.
     */
    @Synchronized
    private fun issueToken(context: Context, request: PermissionNotification): String {
        val tokens = tokens(context)
        val current = tokens.optJSONObject(request.id)?.let(::issuedFrom)
        if (current != null && current.hostId == request.hostId && current.requestId == request.requestId) {
            return current.token
        }
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val token = bytes.joinToString("") { "%02x".format(it) }
        tokens.put(
            request.id,
            JSONObject()
                .put("token", token)
                .put("hostId", request.hostId)
                .put("requestId", request.requestId),
        )
        prefs(context).edit().putString(KEY_TOKENS, tokens.toString()).apply()
        return token
    }

    /**
     * Whether [action] came from a button of a notification the app posted
     * and still shows; the first tap uses the token up, so a replayed or
     * second tap decides nothing.
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
                .put("requestId", action.requestId)
                .put("verdict", action.verdict),
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
                    "requestId" to item.optString("requestId"),
                    "verdict" to item.optString("verdict"),
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

    @Synchronized
    private fun rememberOutstanding(context: Context, request: PermissionNotification) {
        val kept = outstanding(context).filter { it.id != request.id } + request
        saveOutstanding(context, kept)
    }

    @Synchronized
    private fun forgetOutstanding(context: Context, id: String) {
        saveOutstanding(context, outstanding(context).filter { it.id != id })
    }

    @Synchronized
    fun clearOutstanding(context: Context) {
        prefs(context).edit().remove(KEY_OUTSTANDING).apply()
    }

    private fun outstanding(context: Context): List<PermissionNotification> {
        val raw = prefs(context).getString(KEY_OUTSTANDING, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                array.optJSONObject(index)?.let(PermissionNotification::fromJson)
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun saveOutstanding(context: Context, requests: List<PermissionNotification>) {
        val array = JSONArray()
        for (request in requests) array.put(request.toJson())
        prefs(context).edit().putString(KEY_OUTSTANDING, array.toString()).apply()
    }
}
