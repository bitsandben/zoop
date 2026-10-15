import Foundation

// MARK: - "Were you stressed?" labels
//
// After a breathing session the Stress screen asks one question. The answer is the missing ground truth
// for `StressOnsetDetector`: without it the nudge threshold can only be guessed. Answers stay in
// UserDefaults on this device (no server, no account) as a small JSON log, capped so it cannot grow
// without bound.

struct StressLabel: Codable, Equatable {
    let ts: Int
    let stressed: Bool
    /// The 0-3 stress level shown when the user answered, if there was one.
    let level: Double?
}

struct StressLabelLog {
    static let labelsKey = "zoop.stress.labels"
    static let pendingKey = "zoop.stress.labelPendingSince"
    /// A finished session asks for a label for this long; after that the moment has passed.
    static let askWindow: TimeInterval = 30 * 60
    static let maxLabels = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Breathing calls this when a session of at least two minutes ends.
    func markSessionFinished(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.pendingKey)
    }

    func isAsking(now: Date = Date()) -> Bool {
        guard let since = defaults.object(forKey: Self.pendingKey) as? Double else { return false }
        return now.timeIntervalSince1970 - since <= Self.askWindow
    }

    /// Stores the answer and stops asking.
    func record(stressed: Bool, level: Double?, now: Date = Date()) {
        var labels = all()
        labels.append(StressLabel(ts: Int(now.timeIntervalSince1970), stressed: stressed, level: level))
        if labels.count > Self.maxLabels { labels.removeFirst(labels.count - Self.maxLabels) }
        if let data = try? JSONEncoder().encode(labels) { defaults.set(data, forKey: Self.labelsKey) }
        dismiss()
    }

    func dismiss() { defaults.removeObject(forKey: Self.pendingKey) }

    func all() -> [StressLabel] {
        guard let data = defaults.data(forKey: Self.labelsKey) else { return [] }
        return (try? JSONDecoder().decode([StressLabel].self, from: data)) ?? []
    }
}
