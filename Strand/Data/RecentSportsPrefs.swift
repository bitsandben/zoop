import Foundation

// MARK: - Recently selected workout types
//
// Both sport pickers surface the user's most recent selections above the full list. Stored as a
// comma-joined string of sport names in UserDefaults, most-recent-first, deduplicated
// case-insensitively. Display-only, so it stays OUT of the .zoopbak settings whitelist.

/// Persistence for the "Recent" section of the sport pickers: an ordered, comma-joined list of
/// sport names exactly as selected (free-typed, off-catalogue sports included).
enum RecentSportsPrefs {
    /// UserDefaults key.
    static let key = "workout.recentSports"

    /// Most-recent-first cap; wide enough to surface a rotation without scrolling.
    static let maxCount = 5

    /// Encodes an ordered list of names into the stored comma-joined string.
    static func encode(_ names: [String]) -> String { names.joined(separator: ",") }

    /// Decodes the stored string to the ordered name list; blank tokens are dropped.
    static func decode(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Pure fold of one selection into the list: front-inserted, deduplicated case-insensitively (a
    /// re-selection moves to the front with the new casing), capped at `maxCount`. A blank name or one
    /// containing a comma (which can't ride the encoding) is a no-op.
    static func recording(_ name: String, into current: [String]) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(",") else { return current }
        var list = current.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        return Array(list.prefix(maxCount))
    }

    /// The persisted recents, most-recent-first.
    static func recent(_ defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.string(forKey: key) ?? "")
    }

    /// Folds a confirmed selection into the persisted list. Called on confirm only, so an abandoned
    /// sheet leaves the recents untouched.
    static func recordSelection(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.set(encode(recording(name, into: recent(defaults))), forKey: key)
    }
}
