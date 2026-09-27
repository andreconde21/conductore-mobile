package com.gwitko.conduit

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Reads an image from the system clipboard for the Chat composer's
 * "Paste image" (Flutter's Clipboard API is text-only).
 *
 * The clip's content URI is only readable while it is on the clipboard, so
 * the stream is copied into `cacheDir/prompt-images/<id>/clipboard.<ext>`
 * on a worker thread and Dart receives the plain file path.
 *
 * Method channel (`conduit/clipboard_image`):
 *  - `readImage` -> {path, name, size, mimeType} or null when the clipboard
 *    holds no image; an `unreadable` error when it holds one that cannot be
 *    read (so Dart does not claim the clipboard is empty).
 *  - `hasImage` -> whether it holds one, without copying anything (for
 *    offering "Paste image").
 *
 * Android 10+ only lets the focused app read the clipboard: a check made
 * while the app is coming back to the front reads nothing, so Dart asks
 * again when the paste menu opens. The clip's description is read first:
 * it is enough for a plain image clip and, unlike the clip itself, does
 * not raise Android 12's "pasted from your clipboard" notice. Samsung's
 * clipboard can list an HTML or text item before the image's URI, and some
 * providers report no type (or refuse `getType`), so every item's URI is
 * checked, falling back to the clip's types and the file extension.
 */
class ClipboardImageBridge(private val context: Context) {
    companion object {
        const val CHANNEL = "conduit/clipboard_image"
        private const val MAX_BYTES = 50L * 1024 * 1024
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readImage" -> readImage(result)
            "hasImage" -> result.success(hasImage())
            else -> result.notImplemented()
        }
    }

    private fun readImage(result: MethodChannel.Result) {
        val found = try {
            imageUri()
        } catch (_: Exception) {
            null
        }
        if (found == null) {
            result.success(null)
            return
        }
        executor.execute {
            val copied = try {
                copyToCache(found.first, found.second)
            } catch (_: Exception) {
                null
            }
            mainHandler.post {
                if (copied != null) {
                    result.success(copied)
                } else {
                    result.error(
                        "unreadable",
                        "The image on the clipboard could not be read.",
                        null,
                    )
                }
            }
        }
    }

    private fun clipboard(): ClipboardManager? =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

    private fun hasImage(): Boolean = try {
        val description = clipboard()?.primaryClipDescription
        when {
            description == null -> false
            description.hasMimeType("image/*") -> true
            // Only text: no URI to look at, and reading the clip would
            // show the clipboard notice for nothing.
            isTextOnly(description) -> false
            else -> imageUri() != null
        }
    } catch (_: Exception) {
        false
    }

    private fun isTextOnly(description: ClipDescription): Boolean {
        for (index in 0 until description.mimeTypeCount) {
            val type = description.getMimeType(index)
            if (type != ClipDescription.MIMETYPE_TEXT_PLAIN &&
                type != ClipDescription.MIMETYPE_TEXT_HTML
            ) {
                return false
            }
        }
        return true
    }

    /** The clip's first image URI and its MIME type. */
    private fun imageUri(): Pair<Uri, String>? {
        val clip = clipboard()?.primaryClip ?: return null
        val description = clip.description
        val clipImageType = (0 until description.mimeTypeCount)
            .map { description.getMimeType(it) }
            .firstOrNull { it.startsWith("image/") }
        for (index in 0 until clip.itemCount) {
            val uri = clip.getItemAt(index).uri ?: continue
            val type = typeOf(uri)
            when {
                type != null && type.startsWith("image/") -> return uri to type
                clipImageType != null && (type == null || type == "application/octet-stream") ->
                    return uri to (if (clipImageType == "image/*") "image/png" else clipImageType)
                type == null -> typeFromExtension(uri)?.let { return uri to it }
            }
        }
        return null
    }

    private fun typeOf(uri: Uri): String? = try {
        context.contentResolver.getType(uri)
    } catch (_: Exception) {
        null
    }

    private fun typeFromExtension(uri: Uri): String? {
        val extension = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        return MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extension)
            ?.takeIf { it.startsWith("image/") }
    }

    private fun copyToCache(uri: Uri, mimeType: String): Map<String, Any?>? {
        val extension = MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(mimeType) ?: "png"
        val dir = File(File(context.cacheDir, "prompt-images"), UUID.randomUUID().toString())
        dir.mkdirs()
        val target = File(dir, "clipboard.$extension")
        var copied = 0L
        context.contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    copied += read
                    if (copied > MAX_BYTES) {
                        throw IllegalStateException("clipboard image too large")
                    }
                    output.write(buffer, 0, read)
                }
            }
        } ?: return null
        return mapOf(
            "path" to target.absolutePath,
            "name" to target.name,
            "size" to copied,
            "mimeType" to mimeType,
        )
    }
}
