import Foundation
import SwiftUI

// MARK: - Reorderable Today sections
//
// Today's sections render in one default order; the user can REORDER or HIDE them. Display-only: no
// metric is computed or stored differently.
//
// Order is a comma-joined list of section keys in @AppStorage("today.sectionOrder"). Unknown tokens are
// dropped, and any known section missing from the saved order is INSERTED at its default-order position
// relative to the saved sections, so a section added in a later version surfaces where users expect it.
//
// Visibility is stored separately in "today.hiddenSections": hiding is reversible, and a section
// introduced later defaults to visible because it is absent from the hidden set.

/// One reorderable Today section. The rawValue is the stable persisted identifier.
enum TodaySection: String, CaseIterable, Identifiable {
    case hero
    case liveSession
    case synthesis
    case keyMetrics
    case workouts
    case heartRate
    case recoveryVitals
    case yourCards
    case menstrualCycle
    case journal
    /// Cards hosted from the Trends / Sleep tabs (`HostedCardPrefs` selection, in order); empty until the user
    /// adds one. Appended LAST so `decodeOrder`'s back-fill places it predictably in existing saved orders.
    case addedCards

    var id: String { rawValue }

    /// The section's display label in the Arrange sheet.
    var title: String {
        switch self {
        case .hero:           return String(localized: "Charge / Effort / Rest")
        case .liveSession:    return String(localized: "Start session")
        case .synthesis:      return String(localized: "Synthesis")
        case .keyMetrics:     return String(localized: "Key Metrics")
        case .workouts:       return String(localized: "Workouts")
        case .heartRate:      return String(localized: "Heart Rate")
        case .recoveryVitals: return String(localized: "Recovery Vitals")
        case .yourCards:      return String(localized: "Your Cards")
        case .menstrualCycle: return String(localized: "Menstrual Cycle")
        case .journal:        return String(localized: "Logbook")
        case .addedCards:     return String(localized: "Added Cards")
        }
    }

    /// The default section order, used when the layout isn't customised.
    static let defaultOrder: [TodaySection] = [
        .hero, .liveSession, .synthesis, .keyMetrics, .workouts, .heartRate, .recoveryVitals, .yourCards,
        .menstrualCycle, .journal, .addedCards,
    ]
}

/// Display-only persistence for the Today section order and visibility. The order registry always contains
/// every known section; `hiddenKey` stores the explicit reversible hidden set.
enum TodayLayoutPrefs {
    /// UserDefaults key: comma-joined `TodaySection` rawValues in display order.
    static let orderKey = "today.sectionOrder"
    /// UserDefaults key: comma-joined explicitly hidden `TodaySection` rawValues.
    static let hiddenKey = "today.hiddenSections"

    /// Encodes an ordered section list into the stored comma-joined string.
    static func encode(_ sections: [TodaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Encodes the explicit hidden set in stable list order; rendering treats the decoded value as a set.
    static func encodeHidden(_ sections: [TodaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Decodes the stored string into the FULL ordered section list. Empty/unset yields the default order.
    /// Unknown tokens are ignored, duplicates collapsed, and a known section missing from the saved order
    /// is inserted before the first saved section that follows it in the default order (appended when
    /// none does), so every section always renders.
    static func decodeOrder(_ raw: String) -> [TodaySection] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return TodaySection.defaultOrder }
        var saved: [TodaySection] = []
        for token in trimmed.split(separator: ",") {
            if let s = TodaySection(rawValue: token.trimmingCharacters(in: .whitespaces)), !saved.contains(s) {
                saved.append(s)
            }
        }
        guard !saved.isEmpty else { return TodaySection.defaultOrder }
        // Iterate allCases (not defaultOrder) so a case missing from defaultOrder is never silently hidden;
        // it sorts after everything. TodayLayoutPrefsTests pins defaultOrder covering allCases.
        func defIdx(_ s: TodaySection) -> Int {
            TodaySection.defaultOrder.firstIndex(of: s) ?? TodaySection.defaultOrder.count
        }
        for missing in TodaySection.allCases where !saved.contains(missing) {
            let insertAt = saved.firstIndex { defIdx($0) > defIdx(missing) }
            if let insertAt { saved.insert(missing, at: insertAt) } else { saved.append(missing) }
        }
        return saved
    }

    /// Decodes explicitly hidden sections. Empty/unset means nothing is hidden; unlike `decodeOrder`, missing
    /// cases are NOT inserted because absence means visible.
    static func decodeHidden(_ raw: String) -> [TodaySection] {
        var seen = Set<TodaySection>()
        var hidden: [TodaySection] = []
        for token in raw.split(separator: ",") {
            if let section = TodaySection(rawValue: token.trimmingCharacters(in: .whitespaces)),
               seen.insert(section).inserted {
                hidden.append(section)
            }
        }
        return hidden
    }

    /// The sections Today should render: the full saved order minus the explicit hidden set. The editor,
    /// not the decoder, enforces at least one visible section.
    static func visibleOrder(orderRaw: String, hiddenRaw: String) -> [TodaySection] {
        let hidden = Set(decodeHidden(hiddenRaw))
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
