package com.noop.persist

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * On-device copy of this install's settings, kept in [Context.getFilesDir] so an update does not
 * start the app from empty SharedPreferences.
 *
 * Android already keeps `shared_prefs` and the Room database (`noop_whoop.db`) across an update of
 * the same install. This archive is the safety net for the preferences half: every non-empty prefs
 * file is written to a private JSON snapshot, and a launch whose prefs file comes back empty copies
 * that snapshot back before the UI language is applied. It never uploads anything. The database is
 * not copied — it is already durable, and a second copy would risk a half-written store.
 */
object LocalSettingsArchive {
    private const val DIR = "local-settings"

    /** True only when the live store has nothing and a snapshot is sitting on disk. */
    internal fun shouldRestore(liveCount: Int, archiveExists: Boolean): Boolean =
        liveCount == 0 && archiveExists

    /**
     * Copy any empty prefs file back from its snapshot. Call this before anything reads a setting,
     * including the UI language.
     */
    fun restoreIfMissing(context: Context) {
        // Use the context we were given. Application.attachBaseContext calls this before
        // super.attachBaseContext, where applicationContext is not ready yet.
        for (name in knownNames(context)) {
            if (name.contains('/') || name.contains('\\')) continue
            val archive = archiveFile(context, name)
            val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            if (!shouldRestore(prefs.all.size, archive.exists())) continue
            val decoded = runCatching { decodeSnapshot(archive.readText()) }.getOrNull() ?: continue
            if (decoded.isEmpty()) continue
            writePrefs(prefs, decoded)
        }
    }

    /** Refresh the snapshots from the live prefs. An empty file is not written over a good snapshot. */
    fun snapshot(context: Context) {
        val dir = File(context.filesDir, DIR)
        if (!dir.exists()) dir.mkdirs()
        for (name in knownNames(context)) {
            if (name.contains('/') || name.contains('\\')) continue
            val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            val values = prefs.all
            if (values.isEmpty()) continue
            runCatching {
                archiveFile(context, name).writeText(encodeSnapshot(values))
            }
        }
    }

    internal fun encodeSnapshot(values: Map<String, *>): String {
        val entries = JSONArray()
        for (key in values.keys.sorted()) {
            val tagged = tag(values[key]) ?: continue
            entries.put(JSONObject().put("k", key).put("t", tagged.first).put("v", tagged.second))
        }
        return JSONObject().put("v", 1).put("entries", entries).toString()
    }

    internal fun decodeSnapshot(raw: String): Map<String, Any> {
        val root = JSONObject(raw)
        val entries = root.optJSONArray("entries") ?: return emptyMap()
        val out = LinkedHashMap<String, Any>()
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val key = item.optString("k", "")
            if (key.isEmpty()) continue
            untag(item.optString("t", ""), item.opt("v"))?.let { out[key] = it }
        }
        return out
    }

    private fun knownNames(context: Context): Set<String> {
        val names = linkedSetOf<String>()
        File(context.applicationInfo.dataDir, "shared_prefs").listFiles()?.forEach { file ->
            if (file.isFile && file.name.endsWith(".xml")) {
                names += file.name.removeSuffix(".xml")
            }
        }
        File(context.filesDir, DIR).listFiles()?.forEach { file ->
            if (file.isFile && file.name.endsWith(".json")) {
                names += file.name.removeSuffix(".json")
            }
        }
        return names
    }

    private fun archiveFile(context: Context, name: String): File =
        File(File(context.filesDir, DIR), "$name.json")

    private fun writePrefs(prefs: SharedPreferences, values: Map<String, Any>) {
        val editor = prefs.edit()
        for ((key, value) in values) {
            when (value) {
                is String -> editor.putString(key, value)
                is Boolean -> editor.putBoolean(key, value)
                is Int -> editor.putInt(key, value)
                is Long -> editor.putLong(key, value)
                is Float -> editor.putFloat(key, value)
                is Set<*> -> editor.putStringSet(key, value.map { it.toString() }.toSet())
            }
        }
        editor.commit()
    }

    private fun tag(value: Any?): Pair<String, Any>? = when (value) {
        is String -> "s" to value
        is Boolean -> "b" to value
        is Int -> "i" to value
        is Long -> "l" to value
        is Float -> "f" to value.toString()
        is Set<*> -> "S" to JSONArray().apply { value.forEach { put(it.toString()) } }
        else -> null
    }

    private fun untag(type: String, raw: Any?): Any? = when (type) {
        "s" -> raw as? String
        "b" -> raw as? Boolean
        "i" -> when (raw) {
            is Int -> raw
            is Long -> raw.toInt()
            is Number -> raw.toInt()
            else -> null
        }
        "l" -> when (raw) {
            is Long -> raw
            is Int -> raw.toLong()
            is Number -> raw.toLong()
            else -> null
        }
        "f" -> when (raw) {
            is String -> raw.toFloatOrNull()
            is Number -> raw.toFloat()
            else -> null
        }
        "S" -> {
            val array = raw as? JSONArray ?: return null
            buildSet {
                for (i in 0 until array.length()) add(array.optString(i))
            }
        }
        else -> null
    }
}
