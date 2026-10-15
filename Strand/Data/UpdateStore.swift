import Foundation
import Combine

// MARK: - UpdateItem
//
// One entry in the "Updates inbox" (the Today header bell): informational (What's New, a "new data"
// reading) or actionable (a deep link, or a dismissed Today card the user can restore). On-device only.

struct UpdateItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case dismissedCard   // a Today info-card the user swiped into the inbox (restorable)
        case whatsNew        // a release note (seeded from AppChangelog on first run after an update)
        case reading         // new data arrived (e.g. "N days backfilled") — links to Trends
        case strapAlert      // a strap-side heads-up (low battery, sync) — informational
        /// A NEWER RELEASE exists that this install does not have (#1659). Deliberately not `.whatsNew`
        /// ("what you just got") so the bell stays unambiguous.
        case newVersion
    }

    let id: UUID
    var kind: Kind
    var title: String
    var message: String
    var date: Date
    var read: Bool
    /// Optional route key opened on tap (nil = informational); matches a `NavRouter.Destination.rawValue`.
    /// Unknown keys just dismiss the sheet.
    var deepLink: String?
    var restorePayload: String?

    init(id: UUID = UUID(), kind: Kind, title: String, message: String,
         date: Date = Date(), read: Bool = false,
         deepLink: String? = nil, restorePayload: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.date = date
        self.read = read
        self.deepLink = deepLink
        self.restorePayload = restorePayload
    }
}

// MARK: - UpdateStore
//
// The bell's backing store: an on-device inbox of `UpdateItem`s persisted as JSON in UserDefaults (the
// whole list under one key on every mutation). A shared singleton so any surface can post without
// threading an instance. First run posts the current What's New once, tracked by `lastSeededVersion`.
@MainActor
final class UpdateStore: ObservableObject {

    static let shared = UpdateStore()

    @Published private(set) var items: [UpdateItem] {
        didSet { persist() }
    }

    /// A restore signal TodayView observes: set to a card id when "Restore to Today" is tapped so Today (which
    /// owns the dismissed flags) can flip the flag back. Cleared by the observer once handled.
    @Published var restoreRequest: String?

    private let d = UserDefaults.standard
    private enum K {
        static let items = "updates.items"
        static let lastSeededVersion = "updates.lastSeededWhatsNewVersion"
    }

    /// Inbox guard-rails (#521). Background ticks post informational items, so an identical post (same kind +
    /// deepLink) within `dedupWindow` only refreshes the existing row, and informational rows beyond
    /// `maxItems` are evicted oldest first. Actionable rows (`.dismissedCard`, `.strapAlert`) are never
    /// auto-evicted.
    private static let maxItems = 50
    private static let dedupWindow: TimeInterval = 30 * 60   // 30 minutes

    private init() {
        if let data = d.data(forKey: K.items),
           let decoded = try? JSONDecoder().decode([UpdateItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    // MARK: Derived

    var sortedItems: [UpdateItem] { items.sorted { $0.date > $1.date } }

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    // MARK: Mutations

    /// Adds a new unread item. Informational rows are deduped and capped (#521); actionable rows always
    /// append. A deduped post refreshes the existing row's date and re-arms its unread badge.
    func post(_ item: UpdateItem) {
        if Self.isInformational(item.kind),
           let i = items.firstIndex(where: {
               $0.kind == item.kind && $0.deepLink == item.deepLink
                   && item.date.timeIntervalSince($0.date) < Self.dedupWindow
                   && item.date.timeIntervalSince($0.date) >= 0
           }) {
            items[i].date = item.date
            items[i].title = item.title
            items[i].message = item.message
            items[i].read = false
        } else {
            items.append(item)
        }
        evictOverflow()
    }

    private static func isInformational(_ kind: UpdateItem.Kind) -> Bool {
        // `.newVersion` is informational: deduped and evictable, so several ignored releases cannot crowd out
        // actionable rows.
        kind == .reading || kind == .whatsNew || kind == .newVersion
    }

    private func evictOverflow() {
        let informationalCount = items.lazy.filter { Self.isInformational($0.kind) }.count
        guard informationalCount > Self.maxItems else { return }
        var toRemove = informationalCount - Self.maxItems
        let orderedOldest = items.enumerated().sorted { $0.element.date < $1.element.date }
        var removeIDs = Set<UUID>()
        for (_, item) in orderedOldest where toRemove > 0 {
            if Self.isInformational(item.kind) {
                removeIDs.insert(item.id)
                toRemove -= 1
            }
        }
        if !removeIDs.isEmpty { items.removeAll { removeIDs.contains($0.id) } }
    }

    func markRead(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
    }

    func requestRestore(_ item: UpdateItem) {
        if let payload = item.restorePayload {
            restoreRequest = payload
        }
        remove(item.id)
    }

    // MARK: Seeding

    /// Posts the current What's New as a `.whatsNew` item ONCE per version (tracked in UserDefaults, so a
    /// relaunch never double-posts). Call on app appear in both shells; `current` is injectable for tests.
    func seedWhatsNewIfNeeded(version: String = AppChangelog.currentVersion,
                              title: String = AppChangelog.releases.first?.title ?? "",
                              summary: String? = nil) {
        guard !version.isEmpty else { return }
        guard d.string(forKey: K.lastSeededVersion) != version else { return }
        // Mark seeded first so a re-entrant call or a crash mid-post can't double-post.
        d.set(version, forKey: K.lastSeededVersion)

        let message = summary ?? String(localized: "Zoop \(version) is here. Tap to read what's new.")
        post(UpdateItem(
            kind: .whatsNew,
            title: title.isEmpty ? String(localized: "What's new in Zoop \(version)") : title,
            message: message
        ))
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        d.set(data, forKey: K.items)
    }
}
