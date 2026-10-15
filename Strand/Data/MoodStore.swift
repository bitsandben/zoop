import Foundation
import WhoopStore

// MARK: - MoodStore
//
// Daily mood check-ins for the "Mind" section. Stored in the metric-series tall table under a
// DEDICATED source id, so WHOOP CSV or Apple Health re-imports can never clobber a check-in. One
// scalar per LOCAL day (key "mood", 1-5); the (deviceId, day, key) upsert makes an edit an overwrite.
// Offline and opt-in: a row exists only when the user taps a face.

enum MoodStore {
    /// Dedicated source id for native mood rows (as `Repository.journalDeviceId`); imports never touch it.
    static let moodDeviceId = "noop-mood"

    /// metricSeries key for the daily 1–5 mood scalar.
    static let moodKey = "mood"

    /// The check-in scale: 1 (lowest) … 5 (highest).
    static let scale: ClosedRange<Int> = 1...5

    /// Face glyph for a stored 1–5 value (clamps out-of-range defensively).
    static func face(for value: Int) -> String {
        switch value {
        case ...1: return "😞"
        case 2:    return "😕"
        case 3:    return "😐"
        case 4:    return "🙂"
        default:   return "😄"
        }
    }

    /// Neutral, non-clinical word for a stored 1–5 value — never a verdict.
    static func label(for value: Int) -> String {
        switch value {
        case ...1: return String(localized: "Rough")
        case 2:    return String(localized: "Low")
        case 3:    return String(localized: "Okay")
        case 4:    return String(localized: "Good")
        default:   return String(localized: "Great")
        }
    }
}

// MARK: - Persistence (Repository extension)

extension Repository {

    /// Full mood series (day "yyyy-MM-dd", value 1-5), oldest first; one row per local day.
    func moodSeries(days: Int = 4000) async -> [(day: String, value: Double)] {
        await series(key: MoodStore.moodKey, source: MoodStore.moodDeviceId, days: days)
    }

    /// The stored mood for one local day, nil if not checked in yet.
    func mood(day: String) async -> Int? {
        guard let store = await storeHandle() else { return nil }
        let pts = (try? await store.metricSeries(deviceId: MoodStore.moodDeviceId,
                                                 key: MoodStore.moodKey,
                                                 from: day, to: day)) ?? []
        return pts.last.map { Int($0.value.rounded()) }
    }

    /// Saves (or overwrites) the day's mood; the upsert conflict target makes an edit replace the earlier tap.
    func saveMood(day: String, value: Int) async {
        guard MoodStore.scale.contains(value),
              let store = await storeHandle() else { return }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: day, key: MoodStore.moodKey, value: Double(value))],
            deviceId: MoodStore.moodDeviceId)
    }
}
