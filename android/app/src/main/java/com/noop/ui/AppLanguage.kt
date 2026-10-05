package com.noop.ui

import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.LocaleList
import java.util.Locale

/**
 * App-owned UI language. Units and time zone remain independent, while locale-sensitive display
 * formatting follows this selection through [Locale.setDefault].
 *
 * Only English and German are offered. System follows a German phone and uses English otherwise, so a
 * device set to another language cannot surface a leftover translation. Storage formats must still pin
 * their locale and chronology; this selection must not leak into persistent day keys.
 */
enum class AppLanguage(val storageValue: String?, val autonym: String) {
    SYSTEM(null, ""),
    ENGLISH("en", "English"),
    GERMAN("de", "Deutsch");

    companion object {
        fun fromStorage(raw: String?): AppLanguage =
            entries.firstOrNull { it.storageValue == raw } ?: SYSTEM

        /**
         * English, German, or — for System and any legacy tag (Spanish, French, …) — German only when
         * [systemLanguage] itself is German.
         */
        fun resolvedTag(stored: String?, systemLanguage: String): String = when (fromStorage(stored)) {
            GERMAN -> "de"
            ENGLISH -> "en"
            SYSTEM -> if (languageSubtag(systemLanguage) == "de") "de" else "en"
        }

        private fun languageSubtag(tag: String): String =
            tag.lowercase().substringBefore('-').substringBefore('_')
    }
}

/**
 * Process-wide locale owner. Both the Application and Activity wrap their base contexts through this
 * object, which keeps composable `stringResource`, non-composable `uiString`, services, and widgets on
 * one locale. `Locale.setDefault` also keeps date/month words and locale-aware casing aligned with the
 * selected UI language instead of leaking the phone language into otherwise translated copy.
 */
object AppLanguagePrefs {
    private const val FILE = "noop_prefs"
    private const val KEY = "noop.appLanguage"

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun selected(context: Context): AppLanguage {
        canonicalize(context)
        return AppLanguage.fromStorage(prefs(context).getString(KEY, null))
    }

    fun wrap(context: Context): Context {
        canonicalize(context)
        val language = AppLanguage.fromStorage(prefs(context).getString(KEY, null))
        val locales = localesFor(language)
        Locale.setDefault(locales[0])
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocales(locales)
        return context.createConfigurationContext(configuration)
    }

    fun set(context: Context, language: AppLanguage) {
        prefs(context).edit().apply {
            if (language == AppLanguage.SYSTEM) remove(KEY)
            else putString(KEY, language.storageValue)
        }.commit()
        applyToResources(context, language)
    }

    /** Drop a stored tag this build no longer offers (es, fr, …) so the picker lands on System. */
    private fun canonicalize(context: Context) {
        val raw = prefs(context).getString(KEY, null) ?: return
        if (AppLanguage.entries.none { it.storageValue == raw }) {
            prefs(context).edit().remove(KEY).commit()
        }
    }

    private fun applyToResources(context: Context, language: AppLanguage) {
        // The Application outlives Activity.recreate(), so update its Resources too. That keeps
        // uiString() and a running foreground service from retaining the previous language.
        val appResources = context.applicationContext.resources
        val configuration = Configuration(appResources.configuration)
        val locales = localesFor(language)
        configuration.setLocales(locales)
        Locale.setDefault(locales[0])
        @Suppress("DEPRECATION")
        appResources.updateConfiguration(configuration, appResources.displayMetrics)
    }

    private fun localesFor(language: AppLanguage): LocaleList {
        val system = Resources.getSystem().configuration.locales
        val systemTag = if (system.isEmpty) "en" else system[0].toLanguageTag()
        return LocaleList.forLanguageTags(AppLanguage.resolvedTag(language.storageValue, systemTag))
    }
}
