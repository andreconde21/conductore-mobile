package com.gwitko.conduit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Receives ACTION_SEND / ACTION_SEND_MULTIPLE intents and hands them to Dart.
 *
 * Content URIs are only readable while the granting intent is alive, so each
 * stream is copied into `cacheDir/shared/<id>/<display name>` on a worker
 * thread and Dart receives plain file paths. Payloads queue natively until
 * Dart drains them with `takePending`, which covers both a cold start (the
 * engine is not listening yet) and a warm share into a running app (Dart is
 * nudged with `sharedContentAvailable`).
 *
 * Method channel (`conduit/share_target`):
 *  - `takePending` -> List<Map>, every queued payload (then cleared).
 * Dart-bound call:
 *  - `sharedContentAvailable` -> null, a new payload was queued.
 *
 * Payload map: {text: String?, subject: String?, files: [{path, name, size,
 * mimeType}]}.
 */
class ShareTargetBridge(private val context: Context) {
    private val pending = mutableListOf<Map<String, Any?>>()
    private var channel: MethodChannel? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePending" -> {
                val drained = pending.toList()
                pending.clear()
                result.success(drained)
            }
            else -> result.notImplemented()
        }
    }

    /** Returns true when the intent was a share and has been consumed. */
    fun consume(intent: Intent?): Boolean {
        if (intent == null) return false
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return false
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val uris = collectUris(intent, action)
        val mimeType = intent.type
        // Neutralise the intent so an activity re-creation does not replay it.
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.removeExtra(Intent.EXTRA_SUBJECT)
        intent.removeExtra(Intent.EXTRA_STREAM)
        if (text.isNullOrEmpty() && uris.isEmpty()) {
            return false
        }
        executor.execute {
            pruneStaleCopies()
            val files = uris.mapNotNull { copyToCache(it, mimeType) }
            val payload = mapOf(
                "text" to text,
                "subject" to subject,
                "files" to files,
            )
            mainHandler.post {
                pending.add(payload)
                channel?.invokeMethod("sharedContentAvailable", null)
            }
        }
        return true
    }

    fun dispose() {
        executor.shutdown()
    }

    @Suppress("DEPRECATION")
    private fun collectUris(intent: Intent, action: String): List<Uri> {
        val uris = if (action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?.filterNotNull()
                ?: emptyList()
        } else {
            listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }
        // No file:// and none of the app's own files (see SharedUriPolicy).
        return uris.filter { SharedUriPolicy.accepts(it.scheme, it.authority, context.packageName) }
    }

    private fun copyToCache(uri: Uri, intentMimeType: String?): Map<String, Any?>? {
        val resolver = context.contentResolver
        var displayName: String? = null
        try {
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && nameIndex >= 0) {
                    displayName = cursor.getString(nameIndex)
                }
            }
        } catch (_: RuntimeException) {
            // Some providers refuse metadata queries; fall back to the path.
        }
        val name = sanitizeName(displayName ?: uri.lastPathSegment ?: "shared")
        val mimeType = try {
            resolver.getType(uri)
        } catch (_: RuntimeException) {
            null
        } ?: intentMimeType
        val directory = File(File(context.cacheDir, CACHE_DIR), UUID.randomUUID().toString())
        if (!directory.mkdirs()) return null
        val target = File(directory, name)
        return try {
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "size" to target.length(),
                "mimeType" to mimeType,
            )
        } catch (_: Exception) {
            target.delete()
            directory.delete()
            null
        }
    }

    /** Keeps the file name a single path component with no control characters. */
    private fun sanitizeName(raw: String): String {
        val cleaned = raw
            .replace(Regex("[/\\\\\u0000-\u001f]"), "_")
            .trim()
            .trimStart('.')
        return if (cleaned.isEmpty()) "shared" else cleaned
    }

    /** Drops copies older than a day that Dart never cleaned up. */
    private fun pruneStaleCopies() {
        val root = File(context.cacheDir, CACHE_DIR)
        val cutoff = System.currentTimeMillis() - STALE_COPY_MS
        root.listFiles()?.forEach { directory ->
            if (directory.lastModified() < cutoff) {
                directory.deleteRecursively()
            }
        }
    }

    companion object {
        const val CHANNEL = "conduit/share_target"
        private const val CACHE_DIR = "shared"
        private const val STALE_COPY_MS = 24L * 60 * 60 * 1000
    }
}
