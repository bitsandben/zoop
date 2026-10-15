import Foundation
import SwiftUI
import WhoopStore

/// Which slice of the history the session list shows.
///
/// A VIEW split, never a delete. Archived rows stay in the database untouched and are one tap away,
/// which is why a request for "keep the last 10 and auto-delete the rest" is answered this way: Zoop
/// has no server and no cloud copy, so pruning real training history would be irreversible, and
/// hiding it costs nothing.
enum TrainingScope: String, CaseIterable, Identifiable {
    case current, archived

    var id: String { rawValue }

    var label: LocalizedStringKey { self == .current ? "Current" : "Archived" }

    /// How many of the most recent sessions "Current" holds.
    static let currentCount = 10

    /// Split rows into the most recent `currentCount` and everything older.
    ///
    /// Pure and order-preserving: membership is decided by ranking on `startTs`, but rows come back in
    /// the order they arrived, so the caller's sort still decides what the screen shows. Ranking rather
    /// than a cutoff timestamp is what makes ties safe: two sessions starting in the same second cannot
    /// both pass a threshold and hand "Current" an eleventh row. Applied after the sport/source filters,
    /// so each tab means "the 10 most recent of what you are looking at".
    nonisolated static func rows(_ rows: [WorkoutRow], scope: TrainingScope,
                                 currentCount: Int = currentCount) -> [WorkoutRow] {
        guard rows.count > currentCount else { return scope == .current ? rows : [] }
        let key: (WorkoutRow) -> String = { "\($0.startTs)|\($0.sport)" }
        let newest = Set(rows.sorted { $0.startTs > $1.startTs }.prefix(currentCount).map(key))
        return rows.filter { scope == .current ? newest.contains(key($0)) : !newest.contains(key($0)) }
    }
}
