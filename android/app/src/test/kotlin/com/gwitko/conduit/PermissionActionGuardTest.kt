package com.gwitko.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermissionActionGuardTest {
    private val issued = PermissionActionGuard.Issued(
        token = "0123456789abcdef0123456789abcdef",
        hostId = "host-1",
        requestId = "req-1",
    )

    @Test
    fun buttonsOpenTheAppBelowAndroid12() {
        assertTrue(PermissionActionGuard.buttonsLaunchApp(30, engineListening = true))
        assertTrue(PermissionActionGuard.buttonsLaunchApp(23, engineListening = true))
    }

    @Test
    fun buttonsDecideInPlaceFromAndroid12OnlyWhileTheEngineListens() {
        assertFalse(PermissionActionGuard.buttonsLaunchApp(31, engineListening = true))
        assertFalse(PermissionActionGuard.buttonsLaunchApp(35, engineListening = true))
        assertTrue(PermissionActionGuard.buttonsLaunchApp(35, engineListening = false))
    }

    @Test
    fun aTapOnALockedDeviceIsNeverQueued() {
        assertFalse(PermissionActionGuard.mayQueue(deviceLocked = true))
        assertTrue(PermissionActionGuard.mayQueue(deviceLocked = false))
    }

    @Test
    fun acceptsTheAppsOwnButton() {
        assertTrue(PermissionActionGuard.accepts(issued, "host-1", "req-1", issued.token))
    }

    @Test
    fun rejectsForgedOrStaleIntents() {
        // Another app's intent to the exported activity: no token, or a guess.
        assertFalse(PermissionActionGuard.accepts(issued, "host-1", "req-1", null))
        assertFalse(PermissionActionGuard.accepts(issued, "host-1", "req-1", ""))
        assertFalse(
            PermissionActionGuard.accepts(issued, "host-1", "req-1", "0123456789abcdef0123456789abcdee"),
        )
        // The right token aimed at another request or host.
        assertFalse(PermissionActionGuard.accepts(issued, "host-1", "req-2", issued.token))
        assertFalse(PermissionActionGuard.accepts(issued, "host-2", "req-1", issued.token))
        // A notification the app never posted, or whose token was used up.
        assertFalse(PermissionActionGuard.accepts(null, "host-1", "req-1", issued.token))
    }
}
