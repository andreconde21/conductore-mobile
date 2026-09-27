package com.gwitko.conduit

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.view.KeyEvent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `conduit/guide_wake`: "Wake with headset button" for the voice guide.
 *
 * Dart -> native: `setHeadsetWake(bool)`.
 * Native -> Dart: `wake()` on a long press of the headset's media button.
 *
 * Two routes, both on only while the setting is on:
 * - a media session that answers a long press (about 0.6 s) of play/pause
 *   or the headset hook. Android gives media buttons to the app that
 *   played media last, so this works when no music app has played since;
 *   short presses are left alone.
 * - the `GuideVoiceCommand` activity alias, which offers Conductore for
 *   the headset's voice-assistant button (Android asks once which app to
 *   use). The launch reaches Dart as the "guide" launch target.
 */
class GuideWakeBridge : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var session: MediaSession? = null
    private var downAt = 0L
    private var fired = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        release()
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setHeadsetWake" -> {
                val enabled = call.arguments as? Boolean ?: false
                val ctx = context
                if (ctx == null) {
                    result.success(false)
                    return
                }
                setVoiceCommandAlias(ctx, enabled)
                if (enabled) acquire(ctx) else release()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun acquire(ctx: Context) {
        if (session != null) return
        session = MediaSession(ctx, "ConductoreGuide").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    val event = keyEvent(mediaButtonIntent) ?: return false
                    if (event.keyCode != KeyEvent.KEYCODE_HEADSETHOOK &&
                        event.keyCode != KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE &&
                        event.keyCode != KeyEvent.KEYCODE_MEDIA_PLAY
                    ) {
                        return false
                    }
                    when (event.action) {
                        KeyEvent.ACTION_DOWN -> {
                            if (event.repeatCount == 0) {
                                downAt = event.eventTime
                                fired = false
                            } else if (!fired && event.eventTime - downAt >= LONG_PRESS_MS) {
                                fired = true
                                wake()
                            }
                        }
                        KeyEvent.ACTION_UP -> {
                            if (!fired && event.eventTime - downAt >= LONG_PRESS_MS) {
                                fired = true
                                wake()
                            }
                        }
                    }
                    return true
                }
            })
            setPlaybackState(
                PlaybackState.Builder()
                    .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY)
                    .setState(PlaybackState.STATE_PAUSED, 0, 0f)
                    .build(),
            )
            isActive = true
        }
    }

    private fun release() {
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
    }

    private fun wake() {
        channel?.invokeMethod("wake", null)
    }

    private fun keyEvent(intent: Intent): KeyEvent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        }

    companion object {
        const val CHANNEL = "conduit/guide_wake"
        private const val LONG_PRESS_MS = 600L
        private const val ALIAS = "com.gwitko.conduit.GuideVoiceCommand"

        private fun setVoiceCommandAlias(ctx: Context, enabled: Boolean) {
            try {
                ctx.packageManager.setComponentEnabledSetting(
                    ComponentName(ctx.packageName, ALIAS),
                    if (enabled) {
                        PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                    } else {
                        PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                    },
                    PackageManager.DONT_KILL_APP,
                )
            } catch (_: Exception) {
                // Not fatal: the media-button route still works.
            }
        }

        /**
         * A voice-command launch (the headset's assistant button, through
         * the alias) becomes the "guide" launch target, which the app reads
         * once it is unlocked.
         */
        fun markVoiceCommand(intent: Intent?) {
            if (intent?.action == Intent.ACTION_VOICE_COMMAND) {
                intent.putExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET, GuideTileService.LAUNCH_TARGET_GUIDE)
            }
        }
    }
}
