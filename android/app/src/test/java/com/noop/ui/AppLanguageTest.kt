package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AppLanguageTest {
    @Test
    fun unknownOrMissingStoredLanguageFallsBackToSystem() {
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage(null))
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage("unsupported"))
    }

    @Test
    fun onlyEnglishAndGermanAreExplicitChoices() {
        assertEquals(
            listOf(AppLanguage.SYSTEM, AppLanguage.ENGLISH, AppLanguage.GERMAN),
            AppLanguage.entries,
        )
    }

    @Test
    fun legacyTagsFallBackToSystem() {
        listOf("zh", "it", "pl", "es", "fr", "pt-PT", "ru").forEach { tag ->
            assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage(tag))
        }
    }

    @Test
    fun resolvedTagIsEnglishOrGermanOnly() {
        assertEquals("en", AppLanguage.resolvedTag("en", systemLanguage = "de-DE"))
        assertEquals("de", AppLanguage.resolvedTag("de", systemLanguage = "en"))
        assertEquals("de", AppLanguage.resolvedTag(null, systemLanguage = "de-DE"))
        assertEquals("de", AppLanguage.resolvedTag("system", systemLanguage = "de_AT"))
        assertEquals("en", AppLanguage.resolvedTag(null, systemLanguage = "fr-FR"))
        assertEquals("de", AppLanguage.resolvedTag("zh", systemLanguage = "de"))
        assertEquals("en", AppLanguage.resolvedTag("es", systemLanguage = "es"))
    }

    @Test
    fun everyExplicitLanguageRoundTripsItsStableTag() {
        AppLanguage.entries.filter { it != AppLanguage.SYSTEM }.forEach { language ->
            assertEquals(language, AppLanguage.fromStorage(language.storageValue))
        }
    }
}
