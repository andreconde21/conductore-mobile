package com.gwitko.conduit

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri

/**
 * The details sheet André's launcher (com.outsmartis.launcher) shows on a
 * long-press of Conductore. Contract: docs/launcher-details-provider.md.
 *
 * Authority `<applicationId>.launcherdetails`, announced by the
 * `com.outsmartis.launcher.DETAILS_AUTHORITY` meta-data. Reading needs
 * `com.outsmartis.permission.READ_LAUNCHER_DETAILS` (signature, or the
 * launcher's certificate via knownSigner on API 31+). Read-only.
 *
 * - `content://<authority>/items`: one row per agent, [LauncherDetailsModel.ITEM_COLUMNS].
 *   `deep_link` is an `intent:` URI for MainActivity carrying the agent's
 *   widget-line token (action [AgentStatusStore.ACTION_OPEN_AGENT_LINE],
 *   extras [AgentStatusStore.EXTRA_LAUNCH_TARGET] = `agent` and
 *   [AgentStatusStore.EXTRA_LINE_TOKEN]); start it with
 *   `Intent.parseUri(link, Intent.URI_INTENT_SCHEME)`. It opens that
 *   session the way an agent notification does; a stale token opens the
 *   agents dashboard.
 * - `content://<authority>/summary`: one row, [LauncherDetailsModel.SUMMARY_COLUMNS].
 *
 * Everything comes from the snapshot [AgentStatusStore] keeps for the
 * widget: no SSH, no Flutter engine. [AgentStatusStore.save] calls
 * [notifyChanged], and the cursors watch their URI.
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
            )
            PATH_SUMMARY -> LauncherDetailsModel.SUMMARY_COLUMNS to
                listOf(LauncherDetailsModel.summary(snapshot, System.currentTimeMillis()))
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
        else -> null
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("Read-only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int =
        throw UnsupportedOperationException("Read-only")

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?): Int =
        throw UnsupportedOperationException("Read-only")

    companion object {
        private const val PATH_ITEMS = "/items"
        private const val PATH_SUMMARY = "/summary"

        fun authority(context: Context): String = "${context.packageName}.launcherdetails"

        /** Tells the launcher (and any open cursor) that the snapshot changed. */
        fun notifyChanged(context: Context) {
            val resolver = context.contentResolver
            val base = "content://${authority(context)}"
            resolver.notifyChange(Uri.parse(base + PATH_ITEMS), null)
            resolver.notifyChange(Uri.parse(base + PATH_SUMMARY), null)
        }
    }
}
