package com.gwitko.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLockGuardTest {
    @Test
    fun anUnknownStateIsLocked() {
        assertTrue(AppLockGuard.appLocked(null, 1_000L))
    }

    @Test
    fun aLockedAppIsLocked() {
        assertTrue(AppLockGuard.appLocked(AppLockGuard.State(locked = true, relockAtMillis = null), 1_000L))
    }

    @Test
    fun anUnlockedAppOnScreenIsOpen() {
        assertFalse(AppLockGuard.appLocked(AppLockGuard.State(locked = false, relockAtMillis = null), 1_000L))
    }

    @Test
    fun anAppAwayPastItsRelockDelayIsLocked() {
        val state = AppLockGuard.State(locked = false, relockAtMillis = 5_000L)
        assertFalse(AppLockGuard.appLocked(state, 4_999L))
        assertTrue(AppLockGuard.appLocked(state, 5_000L))
        assertTrue(AppLockGuard.appLocked(state, 60_000L))
    }

    @Test
    fun readsDartsArgumentsAndRefusesGarbage() {
        assertEquals(AppLockGuard.State(false, 42L), AppLockGuard.fromMap(mapOf("locked" to false, "relockAtMillis" to 42)))
        assertEquals(AppLockGuard.State(true, null), AppLockGuard.fromMap(mapOf("locked" to true, "relockAtMillis" to null)))
        assertNull(AppLockGuard.fromMap(mapOf("locked" to "no")))
        assertNull(AppLockGuard.fromMap(null))
    }
}
