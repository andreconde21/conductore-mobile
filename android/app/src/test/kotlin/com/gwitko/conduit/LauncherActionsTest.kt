package com.gwitko.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LauncherActionsTest {
    private val permission = LauncherPrompt(
        id = "h/s1", hostId = "h", agentId = "s1", requestId = "r1", question = "Approve Bash: ls",
        options = listOf(LauncherOption("Allow", "allow"), LauncherOption("Always allow", "always"), LauncherOption("Deny", "deny")),
        replyVerdict = null, note = null,
    )
    private val question = LauncherPrompt(
        id = "h/s2", hostId = "h", agentId = "s2", requestId = "q1", question = "Which database?",
        options = listOf(LauncherOption("Postgres", "answer"), LauncherOption("SQLite", "answer")),
        replyVerdict = null, note = null,
    )
    private val reply = LauncherPrompt(
        id = "h/s3", hostId = "h", agentId = "s3", requestId = "reply", question = "Which branch?",
        options = null, replyVerdict = "reply", note = null,
    )
    private val highRisk = LauncherPrompt(
        id = "h/s4", hostId = "h", agentId = "s4", requestId = "r4", question = "Approve Bash: sudo reboot",
        options = null, replyVerdict = null, note = "High-risk request: open it in Conductore",
    )
    private val terminalOnly = highRisk.copy(id = "h/s5", agentId = "s5", note = "Answer it in the terminal")

    private class FakeEnv : LauncherActions.Env {
        var permitted = true
        var locked = false
        var listening = true
        var appLocked = false
        val prompts = mutableMapOf<String, LauncherPrompt>()
        val dispatched = mutableListOf<Map<String, String>>()

        /** What Dart answers at once (null: it cannot take it). */
        var outcome: LauncherActions.Outcome? = LauncherActions.Outcome(ok = true, error = null)

        /** Keep the callback instead of answering (Dart still busy). */
        var hold = false
        var held: ((LauncherActions.Outcome?) -> Unit)? = null
        var changes = 0

        /** Answers held for the unlock; [canHold] false: the store failed. */
        val heldAnswers = mutableListOf<Pair<String, Map<String, String>>>()
        var canHold = true

        override fun callerPermitted() = permitted
        override fun deviceLocked() = locked
        override fun appListening() = listening
        override fun appLocked() = appLocked
        override fun prompt(itemId: String) = prompts[itemId]
        override fun dispatch(action: Map<String, String>, done: (LauncherActions.Outcome?) -> Unit) {
            dispatched.add(action)
            if (hold) held = done else done(outcome)
        }
        override fun itemsChanged() {
            changes++
        }
        override fun hold(prompt: LauncherPrompt, action: Map<String, String>): Boolean {
            if (canHold) heldAnswers.add(prompt.id to action)
            return canHold
        }
    }

    private val held = LauncherActions.Outcome(ok = true, error = null, queued = true, pendingUnlock = true)

    private fun setUp(): Pair<FakeEnv, LauncherActions> {
        val env = FakeEnv()
        listOf(permission, question, reply, highRisk, terminalOnly).forEach { env.prompts[it.id] = it }
        return env to LauncherActions(env)
    }

    private fun LauncherActions.choose(id: String?, index: Int?) = perform("choose", id, null, index, 1_000)
    private fun LauncherActions.reply(id: String?, text: String?) = perform("reply", id, text, null, 1_000)

    @Test(expected = SecurityException::class)
    fun aCallerWithoutThePermissionIsRefused() {
        val (env, actions) = setUp()
        env.permitted = false
        actions.choose("h/s1", 0)
    }

    @Test
    fun theCallerIsCheckedBeforeAnythingElse() {
        val (env, actions) = setUp()
        env.permitted = false
        env.locked = true
        try {
            actions.perform("nope", null, null, null, 0)
            throw AssertionError("expected SecurityException")
        } catch (_: SecurityException) {
        }
        assertTrue(env.dispatched.isEmpty())
    }

    @Test
    fun aLockedPhoneIsRefused() {
        val (env, actions) = setUp()
        env.locked = true
        assertEquals(LauncherActions.Outcome(false, "Unlock your phone first"), actions.choose("h/s1", 0))
        assertTrue(env.dispatched.isEmpty())
    }

    @Test
    fun aLockedAppHoldsTheAnswerForTheUnlock() {
        val (env, actions) = setUp()
        env.appLocked = true
        assertEquals(held, actions.choose("h/s1", 0))
        assertEquals(held, actions.reply("h/s3", "main"))
        // Nothing reaches the app until it is unlocked.
        assertTrue(env.dispatched.isEmpty())
        assertEquals(
            listOf(
                "h/s1" to mapOf("hostId" to "h", "agentId" to "s1", "requestId" to "r1", "verdict" to "allow", "text" to ""),
                "h/s3" to mapOf("hostId" to "h", "agentId" to "s3", "requestId" to "reply", "verdict" to "reply", "text" to "main"),
            ),
            env.heldAnswers,
        )
        // Not answered yet: /items has not changed.
        assertEquals(0, env.changes)
    }

    @Test
    fun aLockedPhoneStillRefusesEvenWithTheAppLocked() {
        val (env, actions) = setUp()
        env.locked = true
        env.appLocked = true
        assertEquals(LauncherActions.Outcome(false, "Unlock your phone first"), actions.reply("h/s3", "main"))
        assertTrue(env.heldAnswers.isEmpty())
    }

    @Test
    fun aHeldAnswerIsCheckedLikeAnyOther() {
        val (env, actions) = setUp()
        env.appLocked = true
        assertEquals("High-risk request: open it in Conductore", actions.choose("h/s4", 0).error)
        assertEquals("No option 3: it has 3 (0 to 2)", actions.choose("h/s1", 3).error)
        assertEquals("Type a message first", actions.reply("h/s3", " ").error)
        assertEquals("That agent isn't waiting any more", actions.choose("h/gone", 0).error)
        assertTrue(env.heldAnswers.isEmpty())
    }

    @Test
    fun anAnswerThatCannotBeStoredIsRefusedAsBefore() {
        val (env, actions) = setUp()
        env.canHold = false
        env.appLocked = true
        assertEquals(LauncherActions.Outcome(false, "Unlock Conductore first"), actions.choose("h/s1", 0))
        env.appLocked = false
        env.listening = false
        assertEquals(LauncherActions.Outcome(false, "Open Conductore first"), actions.reply("h/s3", "go"))
    }

    @Test
    fun anAppThatIsNotRunningHoldsItForTheNextStart() {
        val (env, actions) = setUp()
        env.listening = false
        assertEquals(held, actions.reply("h/s3", "go"))
        assertTrue(env.dispatched.isEmpty())
        assertEquals("h/s3", env.heldAnswers.single().first)
    }

    @Test
    fun anAppThatIsNotRunningWithoutTheAgentSaysOpenConductore() {
        // A stopped engine left no prompts: nothing to hold.
        val (env, actions) = setUp()
        env.listening = false
        env.prompts.clear()
        assertEquals(LauncherActions.Outcome(false, "Open Conductore first"), actions.reply("h/s3", "go"))
        assertTrue(env.heldAnswers.isEmpty())
    }

    @Test
    fun dartNotTakingItHoldsTheAnswer() {
        val (env, actions) = setUp()
        env.outcome = null
        assertEquals(held, actions.choose("h/s1", 0))
        // Locked between the check and Dart: held as well.
        env.outcome = LauncherActions.Outcome(false, "Unlock Conductore first")
        assertEquals(held, actions.choose("h/s2", 0))
        assertEquals(listOf("h/s1", "h/s2"), env.heldAnswers.map { it.first })
        assertEquals(0, env.changes)
        env.canHold = false
        env.outcome = null
        assertEquals(LauncherActions.Outcome(false, "Open Conductore first"), actions.choose("h/s1", 0))
    }

    @Test
    fun aStaleOrUnknownItemIsNotWaiting() {
        val (env, actions) = setUp()
        val stale = LauncherActions.Outcome(false, "That agent isn't waiting any more")
        assertEquals(stale, actions.choose("h/gone", 0))
        assertEquals(stale, actions.reply(null, "hi"))
        assertTrue(env.dispatched.isEmpty())
    }

    @Test
    fun choosingMapsTheIndexToItsDecision() {
        val (env, actions) = setUp()
        assertEquals(LauncherActions.Outcome(true, null), actions.choose("h/s1", 1))
        assertEquals(
            mapOf("hostId" to "h", "agentId" to "s1", "requestId" to "r1", "verdict" to "always", "text" to ""),
            env.dispatched.single(),
        )
        actions.choose("h/s1", 2)
        assertEquals("deny", env.dispatched.last()["verdict"])
        actions.choose("h/s1", 0)
        assertEquals("allow", env.dispatched.last()["verdict"])
        // notifyChange on /items after each answer.
        assertEquals(3, env.changes)
    }

    @Test
    fun choosingAnAnswerSendsItsLabel() {
        val (env, actions) = setUp()
        actions.choose("h/s2", 1)
        assertEquals("answer", env.dispatched.single()["verdict"])
        assertEquals("SQLite", env.dispatched.single()["text"])
        assertEquals("q1", env.dispatched.single()["requestId"])
    }

    @Test
    fun anIndexOutOfRangeOrMissingIsRejected() {
        val (env, actions) = setUp()
        assertEquals("No option 3: it has 3 (0 to 2)", actions.choose("h/s1", 3).error)
        assertEquals("No option -1: it has 3 (0 to 2)", actions.choose("h/s1", -1).error)
        assertEquals("Missing the option index", actions.choose("h/s1", null).error)
        assertTrue(env.dispatched.isEmpty())
    }

    @Test
    fun replyTypesTheTextIntoTheAgent() {
        val (env, actions) = setUp()
        assertTrue(actions.reply("h/s3", "Use main").ok)
        assertEquals(
            mapOf("hostId" to "h", "agentId" to "s3", "requestId" to "reply", "verdict" to "reply", "text" to "Use main"),
            env.dispatched.single(),
        )
    }

    @Test
    fun replyTextIsCappedAndRequired() {
        val (env, actions) = setUp()
        assertTrue(actions.reply("h/s3", "x".repeat(4000)).ok)
        assertEquals("Too long: at most 4000 characters", actions.reply("h/s3", "x".repeat(4001)).error)
        assertEquals("Type a message first", actions.reply("h/s3", "  ").error)
        assertEquals("Type a message first", actions.reply("h/s3", null).error)
        assertEquals(1, env.dispatched.size)
    }

    @Test
    fun replyAndChooseOnlyWhereOffered() {
        val (env, actions) = setUp()
        assertEquals("Pick one of its options", actions.reply("h/s1", "yes").error)
        assertEquals("It takes a reply, not an option", actions.choose("h/s3", 0).error)
        assertTrue(env.dispatched.isEmpty())
    }

    @Test
    fun highRiskAndTerminalOnlyAreNeverAnswered() {
        val (env, actions) = setUp()
        assertEquals("High-risk request: open it in Conductore", actions.choose("h/s4", 0).error)
        assertEquals("High-risk request: open it in Conductore", actions.reply("h/s4", "yes").error)
        assertEquals("Answer it in the terminal", actions.choose("h/s5", 0).error)
        assertTrue(env.dispatched.isEmpty())
    }

    @Test
    fun dartsErrorComesBackAsIs() {
        val (env, actions) = setUp()
        env.outcome = LauncherActions.Outcome(false, "That agent isn't waiting any more")
        assertEquals(LauncherActions.Outcome(false, "That agent isn't waiting any more"), actions.choose("h/s1", 0))
        assertEquals(0, env.changes)
    }

    @Test
    fun oneActionPerItemAtATime() {
        val (env, actions) = setUp()
        env.hold = true
        // Dart has not answered within the wait: reported as queued.
        val first = actions.perform("choose", "h/s1", null, 0, 1)
        assertEquals(LauncherActions.Outcome(ok = true, error = null, queued = true), first)
        assertEquals("Already sending an answer to that agent", actions.choose("h/s1", 2).error)
        // Another agent is not held up.
        env.hold = false
        assertTrue(actions.choose("h/s2", 0).ok)
        // Once Dart answers, the item takes actions again.
        env.held!!.invoke(LauncherActions.Outcome(true, null))
        assertTrue(actions.choose("h/s1", 0).ok)
    }

    @Test
    fun anActionDartNeverAnsweredExpires() {
        var now = 1_000L
        val env = FakeEnv().apply {
            prompts[permission.id] = permission
            hold = true
        }
        val actions = LauncherActions(env) { now }
        assertTrue(actions.perform("choose", "h/s1", null, 0, 0).queued)
        now += LauncherActions.IN_FLIGHT_EXPIRY_MILLIS - 1
        assertFalse(actions.perform("choose", "h/s1", null, 0, 0).ok)
        now += 1
        assertTrue(actions.perform("choose", "h/s1", null, 0, 0).queued)
    }

    @Test
    fun anUnknownMethodIsAnError() {
        val (env, actions) = setUp()
        val outcome = actions.perform("delete", "h/s1", null, null, 0)
        assertFalse(outcome.ok)
        assertEquals("Unknown method delete", outcome.error)
        assertNull(env.held)
        assertTrue(env.dispatched.isEmpty())
    }
}
