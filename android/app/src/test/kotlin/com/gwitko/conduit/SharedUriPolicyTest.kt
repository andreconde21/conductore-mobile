package com.gwitko.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedUriPolicyTest {
    private val own = "com.outsmartis.conductore"

    @Test
    fun acceptsAnotherAppsContentProvider() {
        assertTrue(SharedUriPolicy.accepts("content", "com.android.providers.media.documents", own))
        assertTrue(SharedUriPolicy.accepts("content", "com.google.android.apps.photos.contentprovider", own))
    }

    @Test
    fun rejectsFileUris() {
        assertFalse(SharedUriPolicy.accepts("file", null, own))
        assertFalse(SharedUriPolicy.accepts("file", "", own))
        assertFalse(SharedUriPolicy.accepts("FILE", "localhost", own))
    }

    @Test
    fun rejectsTheAppsOwnProviders() {
        assertFalse(SharedUriPolicy.accepts("content", own, own))
        assertFalse(SharedUriPolicy.accepts("content", "$own.fileprovider", own))
        assertFalse(SharedUriPolicy.accepts("content", "$own.flutter.share_provider", own))
        assertFalse(SharedUriPolicy.accepts("content", "user@$own.fileprovider", own))
    }

    @Test
    fun rejectsOtherSchemesAndMissingAuthorities() {
        assertFalse(SharedUriPolicy.accepts("http", "example.com", own))
        assertFalse(SharedUriPolicy.accepts(null, "x", own))
        assertFalse(SharedUriPolicy.accepts("content", null, own))
    }
}
