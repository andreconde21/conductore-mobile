package com.gwitko.conduit

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * `conduit/agent_status_widget` method channel.
 *
 * Dart -> native:
 * - `push(String json)`: store the snapshot and refresh the widget and tile.
 * - `pushLauncherPrompts(String json)`: store the launcher's prompts
 *   ([LauncherPromptStore], apart from the snapshot; CON-082).
 * - `consumeLaunchTarget()` -> `String?`: the pending launch target, cleared.
 * - `requestAddTile()` -> `String`: added | alreadyAdded | declined | unsupported | failed.
 *
 * Native -> Dart:
 * - `launchTargetAvailable()`: the running app received a widget/tile intent.
 *
 * Registered as a plugin (not inline in MainActivity) so it can observe new
 * intents through [PluginRegistry.NewIntentListener] without touching the
 * activity's own overrides.
 */
class AgentStatusWidgetChannel : FlutterPlugin, ActivityAware, PluginRegistry.NewIntentListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var binding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        // Nothing will push again until the engine is back: stop showing rows
        // that no longer reflect a live session.
        context?.let {
            AgentStatusStore.markNotMonitoring(it)
            LauncherPromptStore.clear(it)
            AgentStatusStore.refreshSurfaces(it)
        }
        context = null
    }

    override fun onAttachedToActivity(activityPluginBinding: ActivityPluginBinding) {
        binding = activityPluginBinding
        activityPluginBinding.addOnNewIntentListener(this)
        // A cold start from the widget or tile: Dart reads the target once
        // its UI is ready via consumeLaunchTarget.
        stashLaunchTarget(activityPluginBinding.activity.intent)
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
        if (!stashLaunchTarget(intent)) return false
        channel?.invokeMethod("launchTargetAvailable", null)
        return true
    }

    /**
     * Stores the intent's launch target, if it carries one, and clears it
     * from the intent. MainActivity is exported, so nothing in the intent is
     * trusted: an unknown target is dropped, and an agent line opens only
     * when its token was issued for a line of the stored snapshot; the agent
     * then comes from that snapshot and goes to Dart through the
     * notification tap's deep link. A stale or forged line token opens the
     * dashboard, which only navigates.
     */
    private fun stashLaunchTarget(intent: Intent?): Boolean {
        val target = intent?.getStringExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET) ?: return false
        val token = intent.getStringExtra(AgentStatusStore.EXTRA_LINE_TOKEN)
        // Never re-deliver on a configuration change or a task resume.
        intent.removeExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET)
        intent.removeExtra(AgentStatusStore.EXTRA_LINE_TOKEN)
        val ctx = context ?: return false
        if (target == AgentStatusStore.LAUNCH_TARGET_AGENT) {
            val line = AgentStatusStore.lineForToken(ctx, token)
            if (line != null) {
                AgentNotificationBridge.deliverOpen(
                    AgentNotificationStore.OpenTarget(
                        hostId = line.hostId,
                        agentId = line.agentId,
                        workspaceId = line.workspace,
                        tabId = line.tab,
                        paneId = line.pane,
                    ),
                )
                return false
            }
            AgentStatusStore.setLaunchTarget(ctx, AgentStatusStore.LAUNCH_TARGET_DASHBOARD)
            return true
        }
        if (target !in AgentStatusStore.DART_LAUNCH_TARGETS) return false
        AgentStatusStore.setLaunchTarget(ctx, target)
        return true
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("detached", "Channel is not attached to an engine", null)
            return
        }
        when (call.method) {
            "push" -> {
                val json = call.arguments as? String
                if (json == null) {
                    result.error("bad_args", "push expects a JSON string", null)
                    return
                }
                AgentStatusStore.save(ctx, json)
                AgentStatusStore.refreshSurfaces(ctx)
                result.success(null)
            }
            "pushLauncherPrompts" -> {
                val json = call.arguments as? String
                if (json == null) {
                    result.error("bad_args", "pushLauncherPrompts expects a JSON string", null)
                    return
                }
                LauncherPromptStore.save(ctx, json)
                result.success(null)
            }
            "consumeLaunchTarget" -> result.success(AgentStatusStore.consumeLaunchTarget(ctx))
            "requestAddTile" -> requestAddTile(ctx, result)
            else -> result.notImplemented()
        }
    }

    private fun requestAddTile(ctx: Context, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("unsupported")
            return
        }
        val manager = ctx.getSystemService(StatusBarManager::class.java)
        if (manager == null) {
            result.success("failed")
            return
        }
        try {
            manager.requestAddTileService(
                ComponentName(ctx, AgentStatusTileService::class.java),
                ctx.getString(R.string.agent_tile_label),
                Icon.createWithResource(ctx, R.drawable.ic_agent_tile),
                ctx.mainExecutor,
            ) { code ->
                result.success(
                    when (code) {
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "alreadyAdded"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "declined"
                        else -> "failed"
                    },
                )
            }
        } catch (_: Exception) {
            // The system UI may refuse (e.g. app not in the foreground).
            result.success("failed")
        }
    }

    companion object {
        const val CHANNEL = "conduit/agent_status_widget"
    }
}
