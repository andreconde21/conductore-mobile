package com.gwitko.conduit

import com.gwitko.conduit.BackgroundServicePolicy.StopReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundServicePolicyTest {
    @Test
    fun theSystemNeverRestartsTheServiceAfterTheProcessDies() {
        // android.app.Service.START_NOT_STICKY; START_STICKY (1) revived a
        // stale "N sessions" notification after a swipe-away.
        assertEquals(2, BackgroundServicePolicy.startMode())
    }

    @Test
    fun aSwipeAwayTakesTheStatusNotificationWithIt() {
        assertFalse(BackgroundServicePolicy.keepsStatus(StopReason.TASK_REMOVED, hasStatus = true))
    }

    @Test
    fun otherStopsKeepTheAgentsStatusUp() {
        assertTrue(BackgroundServicePolicy.keepsStatus(StopReason.REQUESTED, hasStatus = true))
        assertTrue(BackgroundServicePolicy.keepsStatus(StopReason.TIMEOUT, hasStatus = true))
        assertTrue(BackgroundServicePolicy.keepsStatus(StopReason.START_REFUSED, hasStatus = true))
        assertFalse(BackgroundServicePolicy.keepsStatus(StopReason.TIMEOUT, hasStatus = false))
    }
}
