package com.gwitko.conduit

/**
 * Which shared streams the share target reads: plain Kotlin, so JVM unit
 * tests cover it.
 *
 * The app reads a shared stream with its own permissions, so a `file://`
 * URI (which carries no grant) or a `content://` URI of the app's own
 * providers would let any app make Conductore upload its private files,
 * such as the local shell's `~/.ssh`, to a remote machine. Only another
 * app's content provider, which granted this one read access with the
 * share, is accepted.
 */
object SharedUriPolicy {
    fun accepts(scheme: String?, authority: String?, ownPackage: String): Boolean {
        if (!scheme.equals("content", ignoreCase = true)) return false
        val host = authority?.substringAfterLast('@')?.lowercase() ?: return false
        if (host.isEmpty()) return false
        val own = ownPackage.lowercase()
        return host != own && !host.startsWith("$own.")
    }
}
