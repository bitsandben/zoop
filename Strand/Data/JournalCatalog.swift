import Foundation

/// UserDefaults keys `JournalCatalogStore` persists under, exposed so the backup bridge
/// (`DataBackup`, off the main actor) can read/write them without the `@MainActor` store.
/// A restore writes custom names to `legacyCustom` and clears `items`; init re-migrates on relaunch.
enum JournalCatalogBackupKeys {
    static let items = "journal.catalog.v2"
    static let legacyCustom = "journal.customQuestions"
    static let legacyHidden = "journal.hiddenQuestions"
}

@MainActor
final class JournalCatalogStore: ObservableObject {

    /// Starter questions are DATA, stored and rendered verbatim, so they must never be localised
    /// (a translated key would start a new, disconnected behaviour).
    nonisolated static let starterQuestions: [String] = [
        "Did you drink any alcohol?",
        "Did you have caffeine late in the day?",
        "Did you view a screen in bed?",
        "Did you eat close to bedtime?",
        "Did you feel stressed?",
        "Did you use a sauna?",
        "Did you share your bed?",
        "Did you feel sick or ill?",
        "Did you take magnesium?",
        "Did you read before bed?",
    ]

    /// Default group for each starter question (canonical to group); unlisted falls to `.other`.
    nonisolated static let starterGroups: [String: JournalGroup] = [
        "Did you drink any alcohol?": .nutrition,
        "Did you have caffeine late in the day?": .nutrition,
        "Did you eat close to bedtime?": .nutrition,
        "Did you take magnesium?": .supplements,
        "Did you view a screen in bed?": .lifestyle,
        "Did you use a sauna?": .lifestyle,
        "Did you share your bed?": .lifestyle,
        "Did you read before bed?": .lifestyle,
        "Did you feel sick or ill?": .health,
        "Did you feel stressed?": .behaviour,
    ]

    /// The user's deltas (renamed, retyped, regrouped, reordered, hidden) plus customs; default
    /// starters are synthesised at merge time. Persisted as one JSON blob under `journal.catalog.v2`.
    @Published var items: [JournalCatalogItem] { didSet { persistItems() } }

    private let d = UserDefaults.standard
    private enum K {
        static let items = JournalCatalogBackupKeys.items
        // Legacy (v1) keys, read once for migration, never written.
        static let custom = JournalCatalogBackupKeys.legacyCustom
        static let hidden = JournalCatalogBackupKeys.legacyHidden
    }

    init() {
        if let blob = d.data(forKey: K.items),
           let decoded = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) {
            items = decoded
        } else {
            // One-time fold of the legacy arrays into v2 items (customs become `.bool`/`.other`); idempotent.
            items = Self.migrateLegacy(
                custom: d.stringArray(forKey: K.custom) ?? [],
                hidden: d.stringArray(forKey: K.hidden) ?? [])
            persistItems()
        }
    }

    private func persistItems() {
        if let blob = try? JSONEncoder().encode(items) { d.set(blob, forKey: K.items) }
    }

    /// Builds the v2 item list from the legacy custom/hidden arrays.
    nonisolated static func migrateLegacy(custom: [String], hidden: [String]) -> [JournalCatalogItem] {
        var out: [JournalCatalogItem] = []
        var seen = Set<String>()
        var i = 0
        for q in custom {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            guard !t.isEmpty, seen.insert(key).inserted else { continue }
            out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                          group: .other, sortIndex: i, hidden: false, custom: true))
            i += 1
        }
        for q in hidden {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            guard !t.isEmpty else { continue }
            if let idx = out.firstIndex(where: { norm($0.canonical) == key }) {
                out[idx].hidden = true   // a hidden custom question
            } else if seen.insert(key).inserted {
                out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                              group: Self.starterGroups[t] ?? .other,
                                              sortIndex: i, hidden: true, custom: false))
                i += 1
            }
        }
        return out
    }

    // MARK: - Legacy-shape accessors

    /// The user's custom question canonicals, derived from the v2 items.
    var customQuestions: [String] {
        get { items.filter { $0.custom }.sorted { $0.sortIndex < $1.sortIndex }.map(\.canonical) }
        set {
            // Append new customs as `.bool`/`.other` items; drop customs no longer present.
            let keys = Set(newValue.map { Self.norm($0) })
            items.removeAll { $0.custom && !keys.contains(Self.norm($0.canonical)) }
            let existing = Set(items.map { Self.norm($0.canonical) })
            var next = nextSortIndex()
            for q in newValue {
                let key = Self.norm(q)
                let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !existing.contains(key) else { continue }
                items.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                                group: .other, sortIndex: next,
                                                hidden: false, custom: true))
                next += 1
            }
        }
    }

    /// The user's hidden question canonicals, derived from the v2 items.
    var hiddenQuestions: [String] {
        items.filter { $0.hidden }.map(\.canonical)
    }

    private func nextSortIndex() -> Int { (items.map(\.sortIndex).max() ?? -1) + 1 }

    /// Dedup key for a question: collapses all whitespace runs (including NBSP and trailing newlines
    /// from WHOOP exports) to one space and lowercases, so "magnesium?\n" folds onto the starter.
    /// Display text stays verbatim; the stored behaviour key the effects engine joins on is intact.
    nonisolated static func norm(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// imported > starter > custom; case-insensitive dedupe, first casing wins, hidden filtered out.
    /// Imported strings lead so the export's exact wording survives verbatim.
    nonisolated static func mergeCatalog(imported: [String], custom: [String],
                                         hidden: [String] = []) -> [String] {
        let hiddenSet = Set(hidden.map(norm))
        var seen = Set<String>()
        var out: [String] = []
        for q in imported + starterQuestions + custom {
            // Display text trims; the dedup key normalises all whitespace (see `norm`).
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            if !t.isEmpty, !hiddenSet.contains(key), seen.insert(key).inserted { out.append(t) }
        }
        return out
    }

    /// The merged catalog resolved into typed v2 items, grouped and ordered for display. Hidden items
    /// are dropped unless `includeHidden`. `canonical` is the verbatim engine key; the UI renders
    /// `displayName ?? canonical`. The `custom` flag lets the edit UI offer "Delete" vs "Hide".
    func resolvedItems(imported: [String], includeHidden: Bool = false) -> [JournalCatalogItem] {
        var byKey: [String: JournalCatalogItem] = [:]
        for it in items { byKey[Self.norm(it.canonical)] = it }

        var out: [JournalCatalogItem] = []
        var seen = Set<String>()
        var fallbackIndex = (items.map(\.sortIndex).max() ?? -1) + 1
        for q in imported + Self.starterQuestions {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.norm(q)
            guard !t.isEmpty, seen.insert(key).inserted else { continue }
            if let saved = byKey[key] {
                out.append(saved)
            } else {
                out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                              group: Self.starterGroups[t] ?? .other,
                                              sortIndex: fallbackIndex, hidden: false, custom: false))
                fallbackIndex += 1
            }
        }
        // Custom items (only in `items`) come after the merge.
        for it in items where it.custom && !seen.contains(Self.norm(it.canonical)) {
            seen.insert(Self.norm(it.canonical))
            out.append(it)
        }
        if !includeHidden { out.removeAll { $0.hidden } }
        return out
    }

    // MARK: - Item lookup / edits (v2)

    /// The saved item for a canonical key, if the user has customised it.
    func item(for canonical: String) -> JournalCatalogItem? {
        let key = Self.norm(canonical)
        return items.first { Self.norm($0.canonical) == key }
    }

    /// Upserts the saved item for `canonical`, materialising a touched starter with defaults.
    /// Never changes `canonical`.
    private func edit(_ canonical: String, mutate: (inout JournalCatalogItem) -> Void) {
        let key = Self.norm(canonical)
        if let idx = items.firstIndex(where: { Self.norm($0.canonical) == key }) {
            mutate(&items[idx])
        } else {
            let t = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            var fresh = JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                           group: Self.starterGroups[t] ?? .other,
                                           sortIndex: nextSortIndex(), hidden: false, custom: false)
            mutate(&fresh)
            items.append(fresh)
        }
    }

    /// Sets a display-only label; the stored `canonical` is untouched so history stays joined.
    /// A blank name clears the rename.
    func rename(_ canonical: String, to displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(canonical) { $0.displayName = trimmed.isEmpty ? nil : trimmed }
    }

    /// Moves an item to a different group (display only).
    func setGroup(_ canonical: String, to group: JournalGroup) {
        edit(canonical) { $0.group = group }
    }

    /// Changes an item's type; `.numeric` carries an optional unit label (e.g. "mg").
    func setKind(_ canonical: String, to kind: JournalKind) {
        edit(canonical) { $0.kind = kind }
    }

    // MARK: - Custom add / remove / restore (v1 API preserved)

    /// The display label for a canonical key: the user's rename, or the verbatim canonical.
    func displayName(for canonical: String) -> String {
        item(for: canonical)?.displayName ?? canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `q` is a user-added custom question (not a starter/imported one).
    func isCustom(_ q: String) -> Bool {
        let key = Self.norm(q)
        return items.contains { Self.norm($0.canonical) == key && $0.custom }
    }

    /// Add a custom question of the given type and group (defaults: yes/no, Other).
    func addCustom(_ q: String, kind: JournalKind = .bool, group: JournalGroup = .other) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = Self.norm(t)
        guard !items.contains(where: { Self.norm($0.canonical) == key }) else { return }
        items.append(JournalCatalogItem(canonical: t, displayName: nil, kind: kind,
                                        group: group, sortIndex: nextSortIndex(),
                                        hidden: false, custom: true))
    }

    /// Deletes a custom question outright; hides a starter/imported one (restorable).
    func remove(_ q: String) {
        let key = Self.norm(q)
        if isCustom(q) {
            items.removeAll { Self.norm($0.canonical) == key }
        } else {
            edit(q) { $0.hidden = true }
        }
    }

    /// Un-hide a previously hidden starter/imported question.
    func restore(_ q: String) {
        let key = Self.norm(q)
        if let idx = items.firstIndex(where: { Self.norm($0.canonical) == key }) {
            items[idx].hidden = false
        }
    }
}

/// A journal item's type: a plain yes/no toggle, or a numeric value with an optional unit label.
enum JournalKind: Equatable, Codable {
    case bool
    case numeric(unitLabel: String?)

    var isNumeric: Bool { if case .numeric = self { return true } else { return false } }
    var unitLabel: String? { if case let .numeric(u) = self { return u } else { return nil } }
}

/// A user-visible grouping for journal items (display only, never scoring). `rawValue` is the
/// stable persisted key; `title` is the localised label.
enum JournalGroup: String, CaseIterable, Codable {
    case supplements
    case nutrition
    case lifestyle
    case health
    case behaviour
    case other

    /// Fixed display order; empty groups hide outside edit.
    static let displayOrder: [JournalGroup] = [.nutrition, .supplements, .lifestyle, .health, .behaviour, .other]

    var title: String {
        switch self {
        case .supplements: return String(localized: "Supplements")
        case .nutrition:   return String(localized: "Nutrition")
        case .lifestyle:   return String(localized: "Lifestyle")
        case .health:      return String(localized: "Health")
        case .behaviour:   return String(localized: "Behaviour")
        case .other:       return String(localized: "Other")
        }
    }
}

/// One journal catalog item. `canonical` is the verbatim DB/engine key, never localised or
/// rewritten; `displayName`, `kind`, `group` and `sortIndex` are display and organisation only.
struct JournalCatalogItem: Equatable, Codable, Identifiable {
    /// The stable key. Rename NEVER touches this, so history (logged + imported) is preserved.
    var canonical: String
    /// The renamed display label, or nil to render the canonical verbatim.
    var displayName: String?
    var kind: JournalKind
    var group: JournalGroup
    var sortIndex: Int
    var hidden: Bool
    /// True for a user-added question (deletable); false for a starter/imported one (hideable only).
    var custom: Bool

    var id: String { canonical }

    /// What the UI renders: the rename if present, else the verbatim canonical.
    var display: String {
        displayName ?? canonical
    }

    init(canonical: String, displayName: String?, kind: JournalKind, group: JournalGroup,
         sortIndex: Int, hidden: Bool, custom: Bool) {
        self.canonical = canonical
        self.displayName = displayName
        self.kind = kind
        self.group = group
        self.sortIndex = sortIndex
        self.hidden = hidden
        self.custom = custom
    }
}
