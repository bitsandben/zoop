import Foundation

/// Merge imported and on-device-computed sleep sessions for display and export.
public enum SleepMerge {
    /// Merges imported and computed sleep, preserving every session.
    ///
    /// A day with two sessions (main night plus nap, or two nights ending the same local day) keeps both.
    /// Imported sessions take precedence per day: if any imported session ends on a local day, computed
    /// sessions for that day yield; otherwise computed sessions stand. Result is sorted by start time.
    ///
    /// Richness exception: a day's best session ranks
    ///   2  stages that cover the span they claim (`HypnogramCoverage`)
    ///   1  stages present but holed, describing only part of the night
    ///   0  no stages
    /// and the computed day wins only when it out-ranks the import. This stops a stage-less re-import, or
    /// a holed device hypnogram (e.g. 21 segments over 23% of its span), from clobbering a fully staged
    /// computed night. A holed import still beats no stages.
    ///
    /// - Parameter endDay: maps a session to its canonical local end-day key (injected so this stays pure).
    public static func merge(imported: [CachedSleepSession],
                             computed: [CachedSleepSession],
                             endDay: (CachedSleepSession) -> String) -> [CachedSleepSession] {
        var importedByDay: [String: [CachedSleepSession]] = [:]
        for s in imported { importedByDay[endDay(s), default: []].append(s) }
        var computedByDay: [String: [CachedSleepSession]] = [:]
        for s in computed { computedByDay[endDay(s), default: []].append(s) }

        var out: [CachedSleepSession] = []
        out.reserveCapacity(imported.count + computed.count)
        for (day, imp) in importedByDay {
            if let comp = computedByDay[day],
               dayRichness(comp) > dayRichness(imp) {
                out.append(contentsOf: comp)   // richer computed day survives a stage-less import
            } else {
                out.append(contentsOf: imp)    // imported wins its day (unchanged rule)
            }
        }
        for (day, comp) in computedByDay where importedByDay[day] == nil {
            out.append(contentsOf: comp)
        }
        return out.sorted { $0.startTs < $1.startTs }
    }

    /// True when the session carries a non-empty stage payload; nil, "", and "[]" carry none.
    static func hasStages(_ s: CachedSleepSession) -> Bool {
        guard let json = s.stagesJSON?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !json.isEmpty && json != "[]"
    }

    /// How much of a night this session's stages describe: 2 = covers its span, 1 = present but holed,
    /// 0 = none. A timeline whose coverage cannot be measured (the imported minute-dict shape has no
    /// timestamps) is never holed, so it ranks 2 and is judged on presence alone.
    static func richness(_ s: CachedSleepSession) -> Int {
        guard hasStages(s) else { return 0 }
        return HypnogramCoverage.isHoled(s) ? 1 : 2
    }

    /// A day's richness is that of its best session: a staged main night plus an unstaged nap is a staged day.
    static func dayRichness(_ sessions: [CachedSleepSession]) -> Int {
        sessions.reduce(0) { max($0, richness($1)) }
    }
}
