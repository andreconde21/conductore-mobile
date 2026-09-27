package com.gwitko.conduit

/**
 * The rules that keep permission notification buttons from deciding a
 * Claude tool request without the phone's owner: plain Kotlin, so JVM unit
 * tests cover it without a device.
 */
object PermissionActionGuard {
    /** Android 12 (API 31): `Notification.Action.Builder.setAuthenticationRequired`. */
    const val AUTHENTICATION_REQUIRED_SDK = 31

    /** What the app issued for one posted permission notification. */
    data class Issued(val token: String, val hostId: String, val requestId: String)

    /**
     * Whether the buttons open the app instead of deciding in the background.
     * Below API 31 a button cannot demand an unlock, but an activity launch
     * from the lock screen always asks for one, so the buttons launch the app
     * there; they also must once the engine is gone.
     */
    fun buttonsLaunchApp(sdkInt: Int, engineListening: Boolean): Boolean =
        !engineListening || sdkInt < AUTHENTICATION_REQUIRED_SDK

    /** Whether the system must unlock the device before a button fires. */
    fun buttonsRequireAuthentication(sdkInt: Int): Boolean =
        sdkInt >= AUTHENTICATION_REQUIRED_SDK

    /**
     * Whether a tap may be queued for Dart as it is. A tap that arrives while
     * the device is still locked (a system that did not honour the
     * authentication flag) never decides anything: the notification is
     * re-posted with buttons that open the app, behind the device lock.
     */
    fun mayQueue(deviceLocked: Boolean): Boolean = !deviceLocked

    /**
     * Whether an action intent is one of the app's own buttons: the exported
     * MainActivity also receives intents from other apps, which cannot know
     * the random [Issued.token] a posted notification carries.
     */
    fun accepts(issued: Issued?, hostId: String, requestId: String, token: String?): Boolean =
        issued != null &&
            !token.isNullOrEmpty() &&
            constantTimeEquals(issued.token, token) &&
            issued.hostId == hostId &&
            issued.requestId == requestId

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].code xor b[i].code)
        return diff == 0
    }
}
