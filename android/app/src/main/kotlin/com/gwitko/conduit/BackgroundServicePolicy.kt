package com.gwitko.conduit

/**
 * The lifecycle rules of [BackgroundConnectionService] (CON-089): plain
 * Kotlin, so JVM unit tests cover them without a device.
 *
 * Type: `dataSync`. The service keeps the app's SSH and Mosh connections and
 * the agent monitor running while the app is in the background, which no
 * standard type describes exactly; `specialUse` would fit better but needs a
 * Play Console declaration and review. `dataSync` is capped by Android 15+ at
 * 6 h per 24 h (the budget refills while the app is in the foreground), so
 * the service stops itself in `onTimeout` instead of crashing with
 * `ForegroundServiceDidNotStopInTimeException`.
 */
object BackgroundServicePolicy {
    /** `Service.START_NOT_STICKY`. */
    const val START_NOT_STICKY = 2

    /** Android 15 (API 35): `Service.onTimeout(int, int)` for `dataSync`. */
    const val TIMEOUT_CALLBACK_SDK = 35

    enum class StopReason {
        /** Dart asked (the app came back, or no session is left). */
        REQUESTED,

        /** The user swiped the app away: its sessions die with the process. */
        TASK_REMOVED,

        /** Android 15+ ran out of the `dataSync` time budget. */
        TIMEOUT,

        /** startForeground was refused (background start, budget exhausted). */
        START_REFUSED,
    }

    /**
     * Never restarted by the system after the process dies: the sessions it
     * kept alive died with the process, so a sticky restart only revived a
     * stale "N sessions" notification. Dart starts it again when needed.
     */
    fun startMode(): Int = START_NOT_STICKY

    /**
     * Whether the agents' status stays up as a plain ongoing notification
     * once the service stops. Not after a swipe-away: nothing would refresh
     * it any more.
     */
    fun keepsStatus(reason: StopReason, hasStatus: Boolean): Boolean =
        hasStatus && reason != StopReason.TASK_REMOVED
}
