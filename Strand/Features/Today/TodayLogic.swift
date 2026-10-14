import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Today rules shared outside the Today screen
//
// Carry-over, day navigation and provenance wording that other screens (Coupled, Metric Explorer, the
// watch bridge) and the macOS classic Today read too. They lived as statics on the classic `TodayView`;
// they sit here so the iOS target, which no longer compiles that view, keeps one copy of each rule.

enum TodayLogic {

    /// Product mark, never natural-language copy, so source labels stay stable across app languages.
    static let whoopBrandName = "WHOOP"

    // MARK: Recovery carry-over

    /// The freshest scored prior row to carry onto an unscored today, or nil.
    ///
    /// Only today carries, only while today is unscored, and never while calibrating (calibration owns
    /// its own copy). `days` is oldest first; `$0.day < selectedDayKey` keeps a stray future-dated row
    /// from surfacing as "last night" (#547).
    static func lastScoredRecoveryDay(days: [DailyMetric], selectedDayKey: String,
                                      isToday: Bool, todayScored: Bool, isCalibrating: Bool) -> DailyMetric? {
        guard isToday, !todayScored, !isCalibrating else { return nil }
        return days.last(where: { $0.recovery != nil && $0.day < selectedDayKey })
    }

    /// A carried score older than this many days is relabelled "Latest sleep" so it never reads as
    /// last night's (#779).
    static let carryFreshnessDays = 2

    /// True when the carried day is older than `carryFreshnessDays`. Unparseable keys read as fresh, so
    /// staleness is never over-claimed.
    static func isCarryStale(priorDayKey: String, todayKey: String) -> Bool {
        guard let prior = dayKeyParser.date(from: priorDayKey),
              let today = dayKeyParser.date(from: todayKey) else { return false }
        let days = Calendar.current.dateComponents([.day], from: prior, to: today).day ?? 0
        return days > carryFreshnessDays
    }

    /// "Last night · 14 Oct", or "Latest sleep · 2 Oct" once the carried day is stale.
    static func carriedCaption(priorDayKey: String, todayKey: String) -> String {
        let date = shortDate(priorDayKey)
        return isCarryStale(priorDayKey: priorDayKey, todayKey: todayKey)
            ? String(localized: "Latest sleep · \(date)")
            : String(localized: "Last night · \(date)")
    }

    /// The selected day's own Rest; on today only, the last scored night while it is still fresh (#977),
    /// so a strap whose sleep stopped scoring cannot pin an old number to today.
    static func freshRestScore(todayValue: Double?, lastDay: String?, lastValue: Double?,
                               isTodaySelected: Bool, todayKey: String) -> Double? {
        if let v = todayValue { return v }
        guard isTodaySelected, let lastDay, let lastValue,
              !isCarryStale(priorDayKey: lastDay, todayKey: todayKey) else { return nil }
        return lastValue
    }

    /// Whether today's Rest should be captioned as still settling: more strap data is on its way, so the
    /// score may move once the full night lands (#1164/#2012). Annotates a score, never hides one.
    static func restPendingSync(restScore: Double?, backfilling: Bool,
                                historyPendingSync: Bool, isTodaySelected: Bool) -> Bool {
        guard isTodaySelected, restScore != nil else { return false }
        return backfilling || historyPendingSync
    }

    /// One word for a readiness level (Push / Maintain / Rest); nil while there is no read.
    static func readinessWord(_ level: ReadinessEngine.Level) -> String? {
        switch level {
        case .primed: return String(localized: "Push")
        case .balanced: return String(localized: "Maintain")
        case .strained, .rundown: return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    // MARK: Day navigation

    /// Offset after stepping `delta` days (+1 older), clamped to today ... the earliest banked day (#817).
    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }

    /// The step a horizontal swipe asks for: rightward is older, leftward newer (#2378).
    static func daySwipeDelta(dx: Double) -> Int {
        dx > 0 ? 1 : -1
    }

    /// Days back from the logical day to a picked date, never negative (#16).
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }

    /// Whole days from today back to the earliest banked day; 0 when unknown.
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let cal = Calendar.current
        let gap = cal.dateComponents([.day], from: cal.startOfDay(for: earliest),
                                     to: cal.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }

    // MARK: Provenance

    /// The source name a data table shows for a resolved row: "On-device" for anything Zoop computed,
    /// the strap brand for the strap import, otherwise the source's own display name.
    static func provenanceDisplayLabel(rawSource: String, deviceId: String) -> String {
        if rawSource.hasPrefix(vo2MaxAttributionPrefix) {
            let raw = String(rawSource.dropFirst(vo2MaxAttributionPrefix.count))
            let method = vo2MaxEstimatorDisplayName(Vo2MaxEstimator(rawValue: raw))
            return "\(String(localized: "On-device")) · \(method)"
        }
        // An unvalidated SpO₂ estimate must say so wherever it is attributed.
        if rawSource == spo2CandidateAttributionSource {
            return String(localized: "strap estimate (unverified)")
        }
        if rawSource.hasSuffix("-zoop") { return String(localized: "On-device") }
        if rawSource == deviceId || rawSource == Repository.whoopSource { return whoopBrandName }
        if rawSource == Repository.appleHealthSource { return "Apple Health" }
        switch FusionSource(rawValue: rawSource) {
        case .healthConnect: return "Health Connect"
        case .xiaomiBand: return "Mi Band"
        case .nutritionCsv: return String(localized: "Nutrition")
        case .localCache: return String(localized: "Cached")
        case .whoopImport: return whoopBrandName
        case .zoopComputed: return String(localized: "On-device")
        case .appleHealth: return "Apple Health"
        case nil: return rawSource
        }
    }

    static func isWatchSource(_ rawSource: String?, appleHealthSource: String) -> Bool {
        rawSource == appleHealthSource
    }

    /// Like `provenanceDisplayLabel`, but names the Apple-Health source after the device people know.
    static func todayProvenanceChipLabel(rawSource: String, deviceId: String, appleHealthSource: String) -> String {
        if rawSource == appleHealthSource { return "Apple Watch" }
        return provenanceDisplayLabel(rawSource: rawSource, deviceId: deviceId)
    }

    /// The provider that supplied a score's inputs (not where Zoop ran the math). Unknown ids stay
    /// visible rather than being labelled as the strap.
    static func todayScoreProviderLabel(sourceId: String, brand: String?) -> String {
        let source = sourceId.lowercased()
        switch source {
        case Repository.appleHealthSource: return "Apple Watch"
        case Repository.healthConnectSource: return "Health Connect"
        case "oura-import", "oura-api": return "Oura"
        case "fitbit-import": return "Fitbit"
        case "garmin-import": return "Garmin"
        case "xiaomi-band": return "Mi Band"
        case Repository.activityFileSource: return String(localized: "Workout files")
        default: break
        }
        if let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            return brand.caseInsensitiveCompare("WHOOP") == .orderedSame ? whoopBrandName : brand
        }
        if source == Repository.whoopSource { return whoopBrandName }
        switch FusionSource(rawValue: sourceId) {
        case .nutritionCsv: return String(localized: "Nutrition")
        case .localCache: return String(localized: "Cached")
        case let known?: return known.displayName
        case nil: return sourceId
        }
    }

    /// One provenance line for several scores: identical providers collapse, at most two are named.
    static func scoreSourceLabel(providers: [ScoreInputProvider]) -> String? {
        var labels: [String] = []
        for provider in providers {
            let label = todayScoreProviderLabel(sourceId: provider.sourceId, brand: provider.brand)
            if !labels.contains(label) { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    // MARK: Day keys

    /// Parses a stored "yyyy-MM-dd" key in the device zone, as `DailyMetric.day` is written.
    static let dayKeyParser: DateFormatter = DayKeyFormat.local

    /// "14 Oct" for a day key in the app language; the raw key when it does not parse.
    static func shortDate(_ dayKey: String) -> String {
        guard let date = dayKeyParser.date(from: dayKey) else { return dayKey }
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }
}
