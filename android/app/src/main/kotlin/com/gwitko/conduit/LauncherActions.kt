package com.gwitko.conduit

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One choice of a [LauncherPrompt]: its label and the verdict it decides. */
data class LauncherOption(val label: String, val verdict: String)

/**
 * What the launcher's details sheet may show and answer for one agent that
 * needs the user (CON-082), as Dart derived it (`LauncherPrompt` there).
 * Not lock-screen safe: [LauncherPromptStore] keeps it apart from the
 * widget snapshot and only [LauncherDetailsProvider] reads it.
 */
data class LauncherPrompt(
    /** The provider's item id: `<hostId>/<agentId>`. */
    val id: String,
    val hostId: String,
    val agentId: String,
    /** The request [options] decide, or `reply`. */
    val requestId: String,
    val question: String,
    /** Null: no choices (a reply box, or nothing to answer). */
    val options: List<LauncherOption>?,
    /** `reply` (typed into the agent) or `answer` (a free-text answer); null: no reply. */
    val replyVerdict: String?,
    val note: String?,
) {
    val answerable: Boolean get() = options != null || replyVerdict != null

    companion object {
        /** Dart's payload, by [id]; empty for anything unreadable. */
        fun parseAll(json: String?): Map<String, LauncherPrompt> {
            if (json == null) return emptyMap()
            return try {
                val array = JSONArray(json)
                (0 until array.length()).mapNotNull { parse(array.optJSONObject(it)) }.associateBy { it.id }
            } catch (_: Exception) {
                emptyMap()
            }
        }

        private fun parse(json: JSONObject?): LauncherPrompt? {
            if (json == null) return null
            val hostId = json.optString("hostId")
            val agentId = json.optString("agentId")
            if (hostId.isEmpty() || agentId.isEmpty()) return null
            fun nullable(key: String): String? = if (json.isNull(key)) null else json.optString(key)
            val options = json.optJSONArray("options")?.let { array ->
                (0 until array.length()).mapNotNull { index ->
                    val option = array.optJSONObject(index) ?: return@mapNotNull null
                    LauncherOption(option.optString("label"), option.optString("verdict"))
                }
            }
            return LauncherPrompt(
                id = "$hostId/$agentId",
                hostId = hostId,
                agentId = agentId,
                requestId = json.optString("requestId"),
                question = json.optString("question"),
                options = options,
                replyVerdict = nullable("replyVerdict"),
                note = nullable("note"),
            )
        }
    }
}

/**
 * The launcher prompts Dart pushed last, in their own preferences file:
 * the widget, the tile and the lock-screen notifications never read it.
 */
object LauncherPromptStore {
    private const val PREFS = "launcher_prompts"
    private const val KEY_PROMPTS = "prompts"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun save(context: Context, json: String) {
        prefs(context).edit().putString(KEY_PROMPTS, json).apply()
        LauncherDetailsProvider.notifyItemsChanged(context)
    }

    fun load(context: Context): Map<String, LauncherPrompt> =
        LauncherPrompt.parseAll(prefs(context).getString(KEY_PROMPTS, null))

    /** Nothing answers them once the engine is gone. */
    fun clear(context: Context) {
        prefs(context).edit().remove(KEY_PROMPTS).apply()
    }
}

/**
 * `reply` and `choose` from the launcher (CON-082), as plain Kotlin so the
 * checks are unit-tested on the JVM; [LauncherDetailsProvider.call] only
 * wires [Env] to Android and the running app.
 *
 * The action runs in the app: [Env.dispatch] hands it to Dart, which
 * answers it the way a notification's button does, and the call waits up
 * to its timeout for the outcome. One action per item at a time.
 */
class LauncherActions(private val env: Env, private val clock: () -> Long = System::currentTimeMillis) {
    interface Env {
        /** The caller holds the launcher permission (or is this app). */
        fun callerPermitted(): Boolean

        fun deviceLocked(): Boolean

        /** The engine runs and monitors at least one machine. */
        fun appListening(): Boolean

        /** [itemId]'s prompt, only while the snapshot lists it as needing the user. */
        fun prompt(itemId: String): LauncherPrompt?

        /**
         * Hands [action] to Dart; [done] gets the outcome, or null when
         * nobody can take it now (the app is locked or still starting).
         */
        fun dispatch(action: Map<String, String>, done: (Outcome?) -> Unit)

        /** `notifyChange` on `/items`. */
        fun itemsChanged()
    }

    /** What the call returns: `ok`, `error` and, when still running, `queued`. */
    data class Outcome(val ok: Boolean, val error: String?, val queued: Boolean = false)

    private val inFlight = ConcurrentHashMap<String, Long>()

    /**
     * Runs [method] on [itemId]: `reply` with [text], or `choose` with
     * [index]. Throws [SecurityException] for a caller without the
     * permission. Waits up to [waitMillis] for Dart; a slower action is
     * reported `ok` and `queued` (it still completes).
     */
    fun perform(method: String, itemId: String?, text: String?, index: Int?, waitMillis: Long): Outcome {
        if (!env.callerPermitted()) {
            throw SecurityException("Needs ${LauncherDetailsProvider.PERMISSION}")
        }
        if (method != METHOD_REPLY && method != METHOD_CHOOSE) return fail("Unknown method $method")
        if (env.deviceLocked()) return fail(UNLOCK_FIRST)
        if (!env.appListening()) return fail(OPEN_FIRST)
        val prompt = itemId?.let(env::prompt) ?: return fail(STALE)
        val action = when (method) {
            METHOD_REPLY -> {
                val verdict = prompt.replyVerdict
                    ?: return fail(if (prompt.options != null) PICK_AN_OPTION else prompt.note ?: OPEN_TO_ANSWER)
                if (text.isNullOrBlank()) return fail("Type a message first")
                if (text.length > MAX_TEXT) return fail("Too long: at most $MAX_TEXT characters")
                actionOf(prompt, verdict, text)
            }
            else -> {
                val options = prompt.options
                    ?: return fail(if (prompt.replyVerdict != null) REPLY_INSTEAD else prompt.note ?: OPEN_TO_ANSWER)
                if (index == null) return fail("Missing the option index")
                val option = options.getOrNull(index)
                    ?: return fail("No option $index: it has ${options.size} (0 to ${options.size - 1})")
                actionOf(prompt, option.verdict, if (option.verdict == ANSWER) option.label else "")
            }
        }
        val now = clock()
        val started = inFlight.putIfAbsent(prompt.id, now)
        if (started != null) {
            if (now - started < IN_FLIGHT_EXPIRY_MILLIS) return fail("Already sending an answer to that agent")
            inFlight[prompt.id] = now
        }
        val latch = CountDownLatch(1)
        var result: Outcome? = null
        var answered = false
        env.dispatch(action) { outcome ->
            inFlight.remove(prompt.id, now)
            if (outcome?.ok == true) env.itemsChanged()
            synchronized(latch) {
                result = outcome
                answered = true
            }
            latch.countDown()
        }
        if (waitMillis > 0) latch.await(waitMillis, TimeUnit.MILLISECONDS)
        synchronized(latch) {
            if (!answered) return Outcome(ok = true, error = null, queued = true)
            return result ?: fail(OPEN_FIRST)
        }
    }

    private fun actionOf(prompt: LauncherPrompt, verdict: String, text: String) = mapOf(
        "hostId" to prompt.hostId,
        "agentId" to prompt.agentId,
        "requestId" to prompt.requestId,
        "verdict" to verdict,
        "text" to text,
    )

    private fun fail(error: String) = Outcome(ok = false, error = error)

    companion object {
        const val METHOD_REPLY = "reply"
        const val METHOD_CHOOSE = "choose"
        const val EXTRA_TEXT = "text"
        const val EXTRA_INDEX = "index"
        const val RESULT_OK = "ok"
        const val RESULT_ERROR = "error"
        const val RESULT_QUEUED = "queued"

        /** The longest reply accepted. */
        const val MAX_TEXT = 4000

        /** How long a call waits for the app's outcome. */
        const val WAIT_MILLIS = 5_000L

        /** An action Dart never answered (the engine went away) stops blocking after this. */
        const val IN_FLIGHT_EXPIRY_MILLIS = 60_000L

        private const val ANSWER = "answer"
        const val STALE = "That agent isn't waiting any more"
        const val UNLOCK_FIRST = "Unlock your phone first"
        const val OPEN_FIRST = "Open Conductore first"
        const val OPEN_TO_ANSWER = "Open it in Conductore to answer"
        const val PICK_AN_OPTION = "Pick one of its options"
        const val REPLY_INSTEAD = "It takes a reply, not an option"
    }
}
