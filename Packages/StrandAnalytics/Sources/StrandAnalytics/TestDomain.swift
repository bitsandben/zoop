import Foundation

/// The domain tag stamped on each Test Centre log line and used to filter the export bundle. Only `.sleep`
/// and `.battery` have emitters wired so far. `.universal` is the preamble plus the three derived traces
/// that ride every export; `.master` is "log everything".
public enum TestDomain: String, CaseIterable, Sendable, Codable {
    case universal          // preamble plus the 3 derived traces; always present under any active mode
    case sleep              // 1  Sleep and Rest          (guided, nights)
    case connection         // 2  Connection and Sync
    case workouts           // 3  Workouts and GPS
    case display            // 4  Display and Performance (plus screenshot)
    case dataImport         // 5  Import and Data Ingest   (raw value "import" is a reserved word, avoided)
    case steps              // 6  Steps
    case notifications      // 7  Notifications, Alarm and Wake
    case battery            // 8  Battery and Charging      (guided, days)
    case recovery           // 9  Recovery (Charge)
    case hrv                // 10 HRV and Autonomic
    case sources            // 11 Sources, Fusion and Metric Decode
    case stress             // 12 Stress and Illness
    case longevity          // 13 Longevity, Cycles and Haptics
    case master             // Log Everything

    /// Stable wire id used in log tags, meta.json and the GitHub label; `dataImport` maps to "import".
    public var id: String { self == .dataImport ? "import" : rawValue }

    /// GitHub label the deep-link self-applies, e.g. "test:sleep". `master` becomes "test:all".
    public var githubLabel: String { self == .master ? "test:all" : "test:\(id)" }
}
