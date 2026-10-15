#if os(iOS)
import Foundation
import StrandAnalytics

/// The coach's suggestions and today's brief, persisted as one small JSON file in Application Support.
///
/// A file rather than a WhoopStore table: the list is bounded (`CoachSuggestionLog.retentionDays`),
/// app-local (not part of the `.zoopbak` contract or any cross-platform schema) and read whole on
/// every change, so a migration and a second schema would buy nothing.
@MainActor
final class CoachSuggestionStore: ObservableObject {

    static let shared = CoachSuggestionStore()

    struct Snapshot: Codable, Equatable {
        var brief: CoachDailyBrief?
        var items: [CoachSuggestion] = []
    }

    @Published private(set) var snapshot = Snapshot()

    private let url: URL?
    private let now: () -> Date

    init(url: URL? = CoachSuggestionStore.defaultURL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        load()
    }

    nonisolated static var defaultURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return dir.appendingPathComponent("zoop-coach-suggestions.json")
    }

    // MARK: Reads

    /// Today's brief, nil when none was generated for `day`.
    func brief(for day: String) -> CoachDailyBrief? {
        snapshot.brief?.day == day ? snapshot.brief : nil
    }

    /// Suggestions waiting for an answer right now, in the order the brief listed them.
    func active(at date: Date) -> [CoachSuggestion] {
        snapshot.items.filter { $0.isActive(at: date) }
    }

    /// Whether today's brief carried suggestions that were all answered or snoozed.
    func hasAnsweredAll(day: String, at date: Date) -> Bool {
        guard let brief = brief(for: day) else { return false }
        let todays = snapshot.items.filter { $0.createdAt >= brief.createdAt }
        return !todays.isEmpty && active(at: date).isEmpty
    }

    var history: [CoachSuggestion] { snapshot.items }

    // MARK: Writes

    /// Stores a new brief and its suggestions. Unanswered suggestions from earlier days are left as
    /// they are: they expire by themselves and show as such in the history.
    func record(brief: CoachDailyBrief, suggestions: [CoachSuggestion]) {
        var next = snapshot
        next.brief = brief
        next.items = CoachSuggestionLog.recording(suggestions, into: next.items, now: now())
        commit(next)
    }

    func answer(_ id: String, status: CoachSuggestion.Status) {
        var next = snapshot
        next.items = CoachSuggestionLog.answering(next.items, id: id, status: status, now: now())
        commit(next)
    }

    func snooze(_ id: String, until date: Date) {
        var next = snapshot
        next.items = CoachSuggestionLog.answering(next.items, id: id, status: .new, snoozeUntil: date, now: now())
        commit(next)
    }

    /// What the next brief should leave out, from the stored answers.
    func suppressed() -> (reasons: Set<String>, kinds: Set<CoachSuggestion.Kind>) {
        CoachSuggestionLog.suppressed(snapshot.items, now: now())
    }

    // MARK: File

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        snapshot = decoded
    }

    private func commit(_ next: Snapshot) {
        snapshot = next
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        } catch {
            // In memory the answer still holds for this session; the next write retries the file.
        }
    }
}
#endif
