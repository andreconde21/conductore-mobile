package com.gwitko.conduit

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick-settings tile "Voice guide": opens the app and starts the guide
 * listening, so it can be reached from the lock screen's shade without
 * finding the app. The app's own lock still applies (the guide says to
 * unlock first).
 */
class GuideTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.label = getString(R.string.guide_tile_label)
        tile.state = Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = getString(R.string.guide_tile_subtitle)
        }
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(pendingIntent(this))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent(this))
        }
    }

    companion object {
        private const val REQUEST_GUIDE = 7301

        fun intent(context: Context) = Intent(context, MainActivity::class.java).apply {
            action = ACTION_GUIDE
            putExtra(AgentStatusStore.EXTRA_LAUNCH_TARGET, LAUNCH_TARGET_GUIDE)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }

        fun pendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            REQUEST_GUIDE,
            intent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        /** Launch target Dart maps to AgentStatusLaunchTarget.guide. */
        const val LAUNCH_TARGET_GUIDE = "guide"

        private const val ACTION_GUIDE = "com.gwitko.conduit.action.GUIDE"
    }
}
