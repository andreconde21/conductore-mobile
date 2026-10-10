package com.gwitko.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.KeyGenerator

class LauncherAnswerQueueTest {
    private val prompt = LauncherPrompt(
        id = "h/s3", hostId = "h", agentId = "s3", requestId = "reply", question = "Which branch?",
        options = null, replyVerdict = "reply", note = null,
    )
    private val action = mapOf("hostId" to "h", "agentId" to "s3", "requestId" to "reply", "verdict" to "reply", "text" to "Use main")
    private val agent = AgentStatusLine(
        name = "api", host = "dev", state = "needsInput", label = "Needs input",
        hostId = "h", agentId = "s3", changedAtMillis = 900L,
    )

    private fun answer(itemId: String = "h/s3", at: Long = 1_000L, text: String = "Use main") =
        LauncherAnswerQueue.answerOf(prompt.copy(id = itemId), action + ("text" to text), agent, at)

    @Test
    fun anAnswerCarriesTheAgentsNamesAndWhenItStartedWaiting() {
        val held = LauncherAnswerQueue.answerOf(prompt, action, agent, 1_000L)
        assertEquals(QueuedLauncherAnswer("h/s3", action, "api", "dev", 900L, 1_000L), held)
        // Dart reads the action's fields plus the names and times.
        assertEquals(action + mapOf("key" to "h/s3@1000", "title" to "api", "host" to "dev", "since" to 900L, "queuedAt" to 1_000L), held.toMap())
        // Without the snapshot's line: empty names, no start time.
        assertEquals(QueuedLauncherAnswer("h/s3", action, "", "", 0L, 1_000L), LauncherAnswerQueue.answerOf(prompt, action, null, 1_000L))
    }

    @Test
    fun aNewerAnswerToTheSameAgentReplacesTheOlder() {
        val queue = LauncherAnswerQueue.add(listOf(answer(text = "first"), answer("h/s1")), answer(text = "second", at = 2_000L), 2_000L)
        assertEquals(listOf("h/s1", "h/s3"), queue.map { it.itemId })
        assertEquals("second", queue.last().action["text"])
    }

    @Test
    fun answersExpireAfterFifteenMinutes() {
        val first = answer(at = 0L)
        assertFalse(first.expired(LauncherAnswerQueue.EXPIRY_MILLIS - 1))
        assertTrue(first.expired(LauncherAnswerQueue.EXPIRY_MILLIS))
        // Adding drops the expired ones.
        val queue = LauncherAnswerQueue.add(listOf(first), answer("h/s1", at = LauncherAnswerQueue.EXPIRY_MILLIS), LauncherAnswerQueue.EXPIRY_MILLIS)
        assertEquals(listOf("h/s1"), queue.map { it.itemId })
        assertEquals(2 * LauncherAnswerQueue.EXPIRY_MILLIS, LauncherAnswerQueue.expiresAt(queue))
        assertEquals(0L, LauncherAnswerQueue.expiresAt(emptyList()))
    }

    @Test
    fun theQueueIsCapped() {
        var queue = emptyList<QueuedLauncherAnswer>()
        repeat(LauncherAnswerQueue.MAX_ANSWERS + 5) { queue = LauncherAnswerQueue.add(queue, answer("h/a$it"), 1_000L) }
        assertEquals(LauncherAnswerQueue.MAX_ANSWERS, queue.size)
        assertEquals("h/a${LauncherAnswerQueue.MAX_ANSWERS + 4}", queue.last().itemId)
    }

    @Test
    fun theQueueRoundTripsAndToleratesGarbage() {
        val queue = listOf(answer(), answer("h/s1", text = "ünïcode ✓"))
        assertEquals(queue, LauncherAnswerQueue.decode(LauncherAnswerQueue.encode(queue)))
        assertTrue(LauncherAnswerQueue.decode(null).isEmpty())
        assertTrue(LauncherAnswerQueue.decode("not json").isEmpty())
        assertTrue(LauncherAnswerQueue.decode("""[{"itemId":""}, {"title":"x"}]""").isEmpty())
    }

    @Test
    fun theNotificationNeverCarriesTheAnswer() {
        assertEquals("1 answer waits for you to unlock Conductore", LauncherAnswerQueue.waitingText(1))
        assertEquals("3 answers wait for you to unlock Conductore", LauncherAnswerQueue.waitingText(3))
    }

    @Test
    fun theSealerEncryptsAndRejectsAnythingElse() {
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val sealer = AnswerSealer { key }
        val plain = LauncherAnswerQueue.encode(listOf(answer(text = "the secret reply")))
        val sealed = sealer.seal(plain)
        assertFalse(String(sealed, Charsets.ISO_8859_1).contains("secret"))
        assertEquals(plain, sealer.open(sealed))
        // A fresh IV each time.
        assertFalse(sealed.contentEquals(sealer.seal(plain)))
        // Tampered, truncated or sealed with another key: unreadable.
        val tampered = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertNull(sealer.open(tampered))
        assertNull(sealer.open(sealed.copyOf(8)))
        val other = AnswerSealer { KeyGenerator.getInstance("AES").apply { init(256) }.generateKey() }
        assertNull(other.open(sealed))
    }

    @Test
    fun aTakenAnswerStaysStoredUntilResolved() {
        val first = answer("h/s1", at = 1_000L)
        val second = answer("h/s3", at = 1_000L)
        var stored = listOf(first, second)
        val inFlight = mutableSetOf<String>()
        // Taking marks them in flight; storage is untouched.
        val taken = LauncherAnswerQueue.takeable(stored, inFlight)
        assertEquals(listOf(first, second), taken)
        inFlight.addAll(taken.map { it.key })
        assertTrue(LauncherAnswerQueue.takeable(stored, inFlight).isEmpty())
        assertEquals(2, stored.size)
        // The first was sent: resolved, gone.
        stored = LauncherAnswerQueue.remove(stored, first.key)
        inFlight.remove(first.key)
        // The app locked (or died) before the second: released, takeable again.
        inFlight.remove(second.key)
        assertEquals(listOf(second), LauncherAnswerQueue.takeable(stored, inFlight))
    }

    @Test
    fun resolvingAReplacedAnswerKeepsTheNewerOne() {
        val older = answer(at = 1_000L, text = "first")
        val newer = answer(at = 2_000L, text = "second")
        val stored = LauncherAnswerQueue.add(listOf(older), newer, 2_000L)
        assertEquals(listOf(newer), LauncherAnswerQueue.remove(stored, older.key))
    }
}
