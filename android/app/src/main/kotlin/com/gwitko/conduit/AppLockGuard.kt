package com.gwitko.conduit

/**
 * The app lock as actions taken outside the app must see it (notification
 * buttons, the launcher's `reply`/`choose`): plain Kotlin, so JVM unit
 * tests cover it. Dart pushes its state (`appLockState` on the
 * notification channel) on every change; the device lock alone is not
 * enough, the app lock must be open too.
 */
object AppLockGuard {
    /** Dart's lock: [locked], or locked from [relockAtMillis] on (null: it does not re-lock). */
    data class State(val locked: Boolean, val relockAtMillis: Long?)

    /** The last state Dart pushed; null (never told, or the engine went away) counts as locked. */
    @Volatile
    var current: State? = null

    fun appLocked(state: State?, nowMillis: Long): Boolean =
        state == null || state.locked || (state.relockAtMillis != null && nowMillis >= state.relockAtMillis)

    fun appLockedNow(): Boolean = appLocked(current, System.currentTimeMillis())

    /** The channel arguments; null when unreadable (then nothing changes to unlocked). */
    fun fromMap(map: Map<*, *>?): State? {
        val locked = map?.get("locked") as? Boolean ?: return null
        val relockAt = (map["relockAtMillis"] as? Number)?.toLong()
        return State(locked, relockAt)
    }
}
