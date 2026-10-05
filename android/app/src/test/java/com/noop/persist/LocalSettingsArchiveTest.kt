package com.noop.persist

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

class LocalSettingsArchiveCodecTest {
    @Test
    fun roundTripsThePreferenceTypes() {
        val encoded = LocalSettingsArchive.encodeSnapshot(
            mapOf(
                "noop.appLanguage" to "de",
                "noop.coachEnabled" to false,
                "noop.count" to 3,
                "noop.when" to 42L,
                "noop.scale" to 1.5f,
                "noop.tags" to setOf("a", "b"),
            ),
        )
        val decoded = LocalSettingsArchive.decodeSnapshot(encoded)
        assertEquals("de", decoded["noop.appLanguage"])
        assertEquals(false, decoded["noop.coachEnabled"])
        assertEquals(3, decoded["noop.count"])
        assertEquals(42L, decoded["noop.when"])
        assertEquals(1.5f, decoded["noop.scale"])
        assertEquals(setOf("a", "b"), decoded["noop.tags"])
    }

    @Test
    fun restoresOnlyAnEmptyStoreThatHasASnapshot() {
        assertTrue(LocalSettingsArchive.shouldRestore(liveCount = 0, archiveExists = true))
        assertFalse(LocalSettingsArchive.shouldRestore(liveCount = 0, archiveExists = false))
        assertFalse(LocalSettingsArchive.shouldRestore(liveCount = 4, archiveExists = true))
    }
}

@RunWith(RobolectricTestRunner::class)
class LocalSettingsArchiveRestoreTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Test
    fun anEmptyPrefsFileIsFilledFromTheLastSnapshot() {
        val prefs = context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        prefs.edit().putString("noop.appLanguage", "de").putBoolean("noop.onboarded", true).commit()
        LocalSettingsArchive.snapshot(context)

        prefs.edit().clear().commit()
        assertEquals(0, prefs.all.size)

        LocalSettingsArchive.restoreIfMissing(context)
        assertEquals("de", prefs.getString("noop.appLanguage", null))
        assertTrue(prefs.getBoolean("noop.onboarded", false))
    }

    @Test
    fun aLiveValueIsNotReplacedByAnOlderSnapshot() {
        val prefs = context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        prefs.edit().putString("noop.appLanguage", "de").commit()
        LocalSettingsArchive.snapshot(context)
        prefs.edit().putString("noop.appLanguage", "en").commit()

        LocalSettingsArchive.restoreIfMissing(context)
        assertEquals("en", prefs.getString("noop.appLanguage", null))
    }
}
