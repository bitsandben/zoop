import Foundation
import StrandAnalytics

// MARK: - App mindfulness sessions
//
// The app's own breathing exercises and meditation timer leave no workout row, so finished sessions are
// kept here: start, end and kind, nothing else. On-device only (UserDefaults, like the breathing
// outcome), capped so the list never grows without bound.

enum MindfulSessionLog {

    static let storageKey = "zoop.mindful.sessions"
    /// Sessions kept; about a year of daily practice.
    static let cap = 400
    /// Posted after a session is recorded so an open Training page can refresh.
    static let didChange = Notification.Name("zoop.mindful.sessions.changed")

    private struct Entry: Codable {
        let s: Int
        let e: Int
        let k: String
    }

    /// Records a finished session if it lasted at least `MindfulPractice.minSessionSeconds`.
    static func record(kind: MindfulPractice.Kind, start: Date, end: Date = Date(),
                       defaults: UserDefaults = .standard) {
        let s = Int(start.timeIntervalSince1970), e = Int(end.timeIntervalSince1970)
        guard e - s >= MindfulPractice.minSessionSeconds else { return }
        var entries = load(defaults)
        entries.append(Entry(s: s, e: e, k: kind.rawValue))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Recorded sessions, oldest first.
    static func sessions(defaults: UserDefaults = .standard) -> [MindfulPractice.Session] {
        load(defaults).compactMap { entry in
            MindfulPractice.Kind(rawValue: entry.k).map {
                MindfulPractice.Session(startTs: entry.s, endTs: entry.e, kind: $0, source: .app)
            }
        }
    }

    private static func load(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
