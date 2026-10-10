package com.gwitko.conduit

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * One launcher answer held while Conductore cannot send it (contract 3,
 * CON-119): its app lock is up, or its engine is not running. [action] is
 * what [LauncherActions] would have handed to Dart; [title] and [host]
 * name the agent for the in-app outcome, [sinceMillis] is when the agent
 * entered its state (0 unknown), so a reply is not typed into a later wait.
 */
data class QueuedLauncherAnswer(
    val itemId: String,
    val action: Map<String, String>,
    val title: String,
    val host: String,
    val sinceMillis: Long,
    val queuedAtMillis: Long,
) {
    /** Names this answer when Dart resolves or releases it; a newer answer to the item has another. */
    val key: String get() = "$itemId@$queuedAtMillis"

    fun expired(nowMillis: Long): Boolean = nowMillis - queuedAtMillis >= LauncherAnswerQueue.EXPIRY_MILLIS

    fun toJson(): JSONObject = JSONObject()
        .put("itemId", itemId)
        .put("action", JSONObject(action))
        .put("title", title)
        .put("host", host)
        .put("since", sinceMillis)
        .put("queuedAt", queuedAtMillis)

    /** What Dart's `consumeLauncherAnswers` gets. */
    fun toMap(): Map<String, Any> = action + mapOf(
        "key" to key,
        "title" to title,
        "host" to host,
        "since" to sinceMillis,
        "queuedAt" to queuedAtMillis,
    )

    companion object {
        fun parse(json: JSONObject?): QueuedLauncherAnswer? {
            if (json == null) return null
            val action = json.optJSONObject("action") ?: return null
            val itemId = json.optString("itemId")
            if (itemId.isEmpty()) return null
            return QueuedLauncherAnswer(
                itemId = itemId,
                action = action.keys().asSequence().associateWith { action.optString(it) },
                title = json.optString("title"),
                host = json.optString("host"),
                sinceMillis = json.optLong("since", 0L),
                queuedAtMillis = json.optLong("queuedAt", 0L),
            )
        }
    }
}

/**
 * The held answers as plain Kotlin (unit-tested on the JVM): at most one
 * per item (a newer answer replaces the older), dropped after
 * [EXPIRY_MILLIS], the companion's permission wait.
 */
object LauncherAnswerQueue {
    /** How long an answer waits for the unlock: the companion's permission wait. */
    const val EXPIRY_MILLIS = 15 * 60_000L

    /** Most answers held at once. */
    const val MAX_ANSWERS = 20

    /** The queue the store reads; empty for anything unreadable. */
    fun decode(json: String?): List<QueuedLauncherAnswer> {
        if (json == null) return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull { QueuedLauncherAnswer.parse(array.optJSONObject(it)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun encode(queue: List<QueuedLauncherAnswer>): String = JSONArray(queue.map { it.toJson() }).toString()

    /** [queue] with [answer] last, its item's older answer and the expired ones gone. */
    fun add(queue: List<QueuedLauncherAnswer>, answer: QueuedLauncherAnswer, nowMillis: Long): List<QueuedLauncherAnswer> =
        (live(queue, nowMillis).filter { it.itemId != answer.itemId } + answer).takeLast(MAX_ANSWERS)

    fun live(queue: List<QueuedLauncherAnswer>, nowMillis: Long): List<QueuedLauncherAnswer> =
        queue.filterNot { it.expired(nowMillis) }

    /** What Dart may take now: every answer (expired ones too) not already in flight. */
    fun takeable(queue: List<QueuedLauncherAnswer>, inFlight: Set<String>): List<QueuedLauncherAnswer> =
        queue.filter { it.key !in inFlight }

    /** [queue] without the answer [key] names (sent, or dropped on purpose). */
    fun remove(queue: List<QueuedLauncherAnswer>, key: String): List<QueuedLauncherAnswer> =
        queue.filter { it.key != key }

    /**
     * The held answer for [action] on [prompt]'s item, named after [agent]
     * (the snapshot's line for it, if any).
     */
    fun answerOf(
        prompt: LauncherPrompt,
        action: Map<String, String>,
        agent: AgentStatusLine?,
        nowMillis: Long,
    ) = QueuedLauncherAnswer(
        itemId = prompt.id,
        action = action,
        title = agent?.name.orEmpty(),
        host = agent?.host.orEmpty(),
        sinceMillis = agent?.changedAtMillis ?: 0L,
        queuedAtMillis = nowMillis,
    )

    /** The waiting notification's text (lock-screen safe: no agent text). */
    fun waitingText(count: Int): String =
        if (count == 1) "1 answer waits for you to unlock Conductore" else "$count answers wait for you to unlock Conductore"

    /** When the last of [queue] expires: the notification goes then. */
    fun expiresAt(queue: List<QueuedLauncherAnswer>): Long =
        queue.maxOfOrNull { it.queuedAtMillis + EXPIRY_MILLIS } ?: 0L
}

/**
 * AES-256-GCM sealing of the queue: a random 12-byte IV, then the
 * ciphertext and its tag. [key] is an Android Keystore key on the device
 * (it never leaves the keystore); plain JVM keys in unit tests.
 */
class AnswerSealer(private val key: () -> SecretKey) {
    fun seal(plain: String): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        return iv + cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
    }

    /** Null when [sealed] is not ours (another key, tampered, truncated). */
    fun open(sealed: ByteArray): String? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES))
        String(cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES), Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    companion object {
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128
        private const val IV_BYTES = 12
    }
}

/**
 * The held launcher answers, encrypted with a key in the Android Keystore
 * ([AnswerSealer]) in their own preferences file: they carry the typed
 * text. They survive process death and are dropped after
 * [LauncherAnswerQueue.EXPIRY_MILLIS]. While any wait, a notification
 * says so (no answer text in it).
 *
 * Dart [take]s them after the next unlock: taking only marks them in
 * flight (in memory). Each stays stored until Dart [resolve]s it (sent,
 * or dropped on purpose: expired, stale); one Dart [release]s (locked
 * again, the machine not monitored yet) or never resolves because the
 * engine or the process went away is taken again later.
 */
object LauncherAnswerStore {
    private const val PREFS = "launcher_answers"
    private const val KEY_QUEUE = "queue"
    private const val KEY_ALIAS = "conductore_launcher_answers"
    private const val NOTIFICATION_ID = "launcher-answers"
    private const val KEYSTORE = "AndroidKeyStore"

    private val sealer = AnswerSealer(::keystoreKey)

    /** Keys Dart has taken and not resolved or released; gone with the process. */
    private val inFlight = mutableSetOf<String>()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun keystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun read(context: Context): List<QueuedLauncherAnswer> {
        val raw = prefs(context).getString(KEY_QUEUE, null) ?: return emptyList()
        val sealed = try {
            Base64.decode(raw, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return emptyList()
        }
        return LauncherAnswerQueue.decode(sealer.open(sealed))
    }

    /** False when nothing could be stored (no keystore): nothing is held then. */
    private fun write(context: Context, queue: List<QueuedLauncherAnswer>): Boolean {
        val editor = prefs(context).edit()
        if (queue.isEmpty()) {
            editor.remove(KEY_QUEUE)
        } else {
            val sealed = try {
                sealer.seal(LauncherAnswerQueue.encode(queue))
            } catch (_: Exception) {
                return false
            }
            editor.putString(KEY_QUEUE, Base64.encodeToString(sealed, Base64.NO_WRAP))
        }
        // commit: the answer must be on disk before the launcher hears "queued".
        return editor.commit()
    }

    /** Holds [answer]; false when it could not be stored. */
    @Synchronized
    fun hold(context: Context, answer: QueuedLauncherAnswer, nowMillis: Long = System.currentTimeMillis()): Boolean {
        val queue = LauncherAnswerQueue.add(read(context), answer, nowMillis)
        if (!write(context, queue)) return false
        showWaiting(context, queue, nowMillis)
        return true
    }

    /**
     * Every held answer not in flight (expired ones too, so the app can
     * say so), now in flight. They stay stored.
     */
    @Synchronized
    fun take(context: Context): List<QueuedLauncherAnswer> {
        val taken = LauncherAnswerQueue.takeable(read(context), inFlight)
        inFlight.addAll(taken.map { it.key })
        return taken
    }

    /** The answer [key] was sent or dropped on purpose: no longer stored. */
    @Synchronized
    fun resolve(context: Context, key: String, nowMillis: Long = System.currentTimeMillis()) {
        inFlight.remove(key)
        val queue = LauncherAnswerQueue.remove(read(context), key)
        write(context, queue)
        showWaiting(context, queue, nowMillis)
    }

    /** [keys] were taken but not sent: taken again next time. */
    @Synchronized
    fun release(keys: Collection<String>) {
        inFlight.removeAll(keys.toSet())
    }

    /** The engine went away: whatever it had taken is takeable again. */
    @Synchronized
    fun releaseAll() {
        inFlight.clear()
    }

    private fun showWaiting(context: Context, queue: List<QueuedLauncherAnswer>, nowMillis: Long) {
        val live = LauncherAnswerQueue.live(queue, nowMillis)
        if (live.isEmpty()) {
            AgentNotificationStore.cancel(context, NOTIFICATION_ID)
            return
        }
        AgentNotificationStore.showPlain(
            context,
            NOTIFICATION_ID,
            LauncherAnswerQueue.waitingText(live.size),
            "Nothing is sent until you unlock it. Answers wait up to 15 minutes.",
            timeoutAfterMillis = LauncherAnswerQueue.expiresAt(live) - nowMillis,
        )
    }
}
