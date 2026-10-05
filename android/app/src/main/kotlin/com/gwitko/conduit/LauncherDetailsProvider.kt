package com.gwitko.conduit

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process

/**
 * The details sheet André's launcher Yoke (com.outsmartis.yoke) shows on a
 * long-press of Conductore. Contract: docs/launcher-details-provider.md.
 *
 * Authority `<applicationId>.launcherdetails`, announced by the
 * `com.outsmartis.launcher.DETAILS_AUTHORITY` meta-data. Reading needs
 * `com.outsmartis.permission.READ_LAUNCHER_DETAILS` (signature, or the
 * launcher's certificate via knownSigner on API 31+). No insert, update
 * or delete; [call] answers an agent (`reply`, `choose`, contract 2).
 *
 * - `content://<authority>/items`: one row per agent, [LauncherDetailsModel.ITEM_COLUMNS];
 *   an agent needing the user also has its question and options from
 *   [LauncherPromptStore] (not lock-screen safe: nothing else reads it).
 *   `deep_link` is an `intent:` URI for MainActivity carrying the agent's
 *   widget-line token (action [AgentStatusStore.ACTION_OPEN_AGENT_LINE],
 *   extras [AgentStatusStore.EXTRA_LAUNCH_TARGET] = `agent` and
 *   [AgentStatusStore.EXTRA_LINE_TOKEN]); start it with
 *   `Intent.parseUri(link, Intent.URI_INTENT_SCHEME)`. It opens that
 *   session the way an agent notification does; a stale token opens the
 *   agents dashboard.
 * - `content://<authority>/summary`: one row, [LauncherDetailsModel.SUMMARY_COLUMNS].
 * - `content://<authority>/themes`: one row per theme the app offers, in
 *   the theme picker's order ([LauncherDetailsModel.THEMES_COLUMNS]), from
 *   res/raw/launcher_themes.json. Changes only with an app update.
 * - `content://<authority>/pc_theme`: one row, the followed Omarchy
 *   machine's theme ([LauncherDetailsModel.PC_THEME_COLUMNS]), never the
 *   one picked in the app.
 *
 * Everything comes from the snapshot [AgentStatusStore] keeps for the
 * widget, the prompts [LauncherPromptStore] keeps (and a raw resource): no
 * SSH, no Flutter engine. [AgentStatusStore.save] calls [notifyChanged],
 * and the cursors watch their URI.
 *
 * [call] (`reply`, `choose`) checks the caller's permission itself (the
 * manifest's read and write permissions do not cover it), refuses while
 * the device or the app lock is locked, and hands the answer to the running app
 * ([LauncherActions]); it never opens SSH or starts an engine.
 */
class LauncherDetailsProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?,
    ): Cursor? {
        val ctx = context ?: return null
        val snapshot = AgentStatusStore.load(ctx)
        val (columns, rows) = when (uri.path) {
            PATH_ITEMS -> LauncherDetailsModel.ITEM_COLUMNS to LauncherDetailsModel.items(
                snapshot,
                AgentStatusStore.lineTokens(ctx),
                ctx.packageName,
                MainActivity::class.java.name,
                LauncherPromptStore.load(ctx),
            )
            PATH_SUMMARY -> LauncherDetailsModel.SUMMARY_COLUMNS to
                listOf(LauncherDetailsModel.summary(snapshot, System.currentTimeMillis()))
            PATH_THEMES -> LauncherDetailsModel.THEMES_COLUMNS to LauncherDetailsModel.themes(catalog(ctx))
            PATH_PC_THEME -> LauncherDetailsModel.PC_THEME_COLUMNS to listOf(LauncherDetailsModel.pcTheme(snapshot))
            else -> throw IllegalArgumentException("Unknown URI $uri")
        }
        val (shown, shownRows) = LauncherDetailsModel.project(columns, rows, projection)
        return MatrixCursor(shown, shownRows.size).apply {
            shownRows.forEach(::addRow)
            setNotificationUri(ctx.contentResolver, uri)
        }
    }

    override fun getType(uri: Uri): String? = when (uri.path) {
        PATH_ITEMS -> "vnd.android.cursor.dir/vnd.com.outsmartis.launcherdetails.item"
        PATH_SUMMARY -> "vnd.android.cursor.item/vnd.com.outsmartis.launcherdetails.summary"
        PATH_THEMES -> "vnd.android.cursor.dir/vnd.com.outsmartis.launcherdetails.theme"
        PATH_PC_THEME -> "vnd.android.cursor.item/vnd.com.outsmartis.launcherdetails.pc_theme"
        else -> null
    }

    /**
     * `reply` (extras `text`) or `choose` (extras `index`, an Int) on the
     * item [arg]: a Bundle with `ok`, `error` and, when the app is still
     * sending it after [LauncherActions.WAIT_MILLIS], `queued`.
     */
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val ctx = context ?: throw IllegalStateException("Not attached")
        val index = if (extras?.containsKey(LauncherActions.EXTRA_INDEX) == true) {
            extras.getInt(LauncherActions.EXTRA_INDEX, -1)
        } else {
            null
        }
        // A call on the main thread (this app's own) must not block it.
        val wait = if (Looper.myLooper() == Looper.getMainLooper()) 0L else LauncherActions.WAIT_MILLIS
        val outcome = actions(ctx).perform(
            method,
            arg,
            extras?.getString(LauncherActions.EXTRA_TEXT),
            index,
            wait,
        )
        return Bundle().apply {
            putBoolean(LauncherActions.RESULT_OK, outcome.ok)
            putString(LauncherActions.RESULT_ERROR, outcome.error)
            if (outcome.queued) putBoolean(LauncherActions.RESULT_QUEUED, true)
        }
    }

    @Volatile
    private var launcherActions: LauncherActions? = null

    private fun actions(ctx: Context): LauncherActions = launcherActions ?: synchronized(this) {
        launcherActions ?: LauncherActions(AppEnv(ctx.applicationContext)).also { launcherActions = it }
    }

    /** [LauncherActions.Env] on Android and the running engine. */
    private class AppEnv(private val ctx: Context) : LauncherActions.Env {
        override fun callerPermitted(): Boolean {
            val uid = Binder.getCallingUid()
            return uid == Process.myUid() ||
                ctx.checkPermission(PERMISSION, Binder.getCallingPid(), uid) == PackageManager.PERMISSION_GRANTED
        }

        override fun deviceLocked(): Boolean = AgentNotificationStore.isDeviceLocked(ctx)

        override fun appListening(): Boolean =
            AgentNotificationBridge.active != null && AgentStatusStore.load(ctx)?.monitoring == true

        override fun appLocked(): Boolean = AppLockGuard.appLockedNow()

        override fun prompt(itemId: String): LauncherPrompt? {
            val waiting = AgentStatusStore.load(ctx)?.agents?.any {
                it.urgent && it.asDashboardLine().let { line -> line.tappable && line.key == itemId }
            } ?: false
            return if (waiting) LauncherPromptStore.load(ctx)[itemId] else null
        }

        override fun dispatch(action: Map<String, String>, done: (LauncherActions.Outcome?) -> Unit) {
            Handler(Looper.getMainLooper()).post {
                val bridge = AgentNotificationBridge.active
                if (bridge == null) done(null) else bridge.launcherAction(action, done)
            }
        }

        override fun itemsChanged() = notifyItemsChanged(ctx)
    }

    @Volatile
    private var catalogJson: String? = null

    /** The bundled catalog, read once per process. */
    private fun catalog(ctx: Context): String = catalogJson
        ?: ctx.resources.openRawResource(R.raw.launcher_themes).bufferedReader().use { it.readText() }
            .also { catalogJson = it }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("Read-only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int =
        throw UnsupportedOperationException("Read-only")

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?): Int =
        throw UnsupportedOperationException("Read-only")

    companion object {
        private const val PATH_ITEMS = "/items"
        private const val PATH_SUMMARY = "/summary"
        private const val PATH_THEMES = "/themes"
        private const val PATH_PC_THEME = "/pc_theme"

        /** Guards the queries and [call]. */
        const val PERMISSION = "com.outsmartis.permission.READ_LAUNCHER_DETAILS"

        fun authority(context: Context): String = "${context.packageName}.launcherdetails"

        /**
         * Tells the launcher (and any open cursor) that the snapshot changed;
         * `/pc_theme` only when [pcThemeChanged]. `/themes` never changes
         * while the app is installed.
         */
        fun notifyChanged(context: Context, pcThemeChanged: Boolean) {
            val resolver = context.contentResolver
            val base = "content://${authority(context)}"
            resolver.notifyChange(Uri.parse(base + PATH_ITEMS), null)
            resolver.notifyChange(Uri.parse(base + PATH_SUMMARY), null)
            if (pcThemeChanged) resolver.notifyChange(Uri.parse(base + PATH_PC_THEME), null)
        }

        /** `/items` alone changed (the prompts, or after an answer). */
        fun notifyItemsChanged(context: Context) {
            context.contentResolver.notifyChange(Uri.parse("content://${authority(context)}$PATH_ITEMS"), null)
        }
    }
}
