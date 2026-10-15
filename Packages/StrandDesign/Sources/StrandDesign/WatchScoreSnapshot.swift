import Foundation

/// The phone-to-watch payload: the small snapshot the iPhone pushes over WatchConnectivity for the watch app and complication to DISPLAY. The watch never recomputes a score.
/// Lives in StrandDesign so the iOS `WatchSessionBridge` (encode) and the watchOS app + complication (decode, from the shared app group's UserDefaults under `latestWatchSnapshot`) share one wire shape.
/// A calibrating score is the number being `nil` AND its `Calibrating` flag true: render "needs more data" (dash + cal marker), NEVER a fabricated number.
/// `nil` with the flag false is missing data and reads as a plain dash.
public struct WatchScoreSnapshot: Codable, Equatable, Sendable {
    /// Charge (recovery), 0 to 100. `nil` when there is no earned number for the day.
    public var charge: Double?
    /// True while Charge is calibrating (baseline not usable yet); `charge` is then `nil`.
    public var chargeCalibrating: Bool

    /// Effort (strain) on Zoop's 0 to 100 axis. `nil` when there is no usable HR window for the day.
    public var effort: Double?
    /// True when Effort is still calibrating. `effort` is `nil` while this is true.
    public var effortCalibrating: Bool

    /// Rest (sleep) composite, 0 to 100. `nil` when there is no matched in-bed session for the day.
    public var rest: Double?
    /// True when Rest is still calibrating. `rest` is `nil` while this is true.
    public var restCalibrating: Bool

    /// Last heart rate (bpm) the phone had; the watch shows its OWN live HR, so this is a fallback / sync indicator.
    public var hr: Int?

    /// One-line sleep summary for the glance (e.g. "7h 12m · 81% efficiency"), preformatted by the phone; empty when nothing to show.
    public var sleepSummary: String

    /// When the phone built this snapshot; the watch shows its age rather than implying live numbers.
    public var asOf: Date

    /// The "YYYY-MM-DD" local day key these scores describe (nil when unknown). Distinct from `asOf`: a 9am snapshot may still describe yesterday.
    /// The watch prefers it for its recency label. Decodes as nil when absent so older payloads stay compatible.
    public var scoreDay: String?

    public init(charge: Double?, chargeCalibrating: Bool,
                effort: Double?, effortCalibrating: Bool,
                rest: Double?, restCalibrating: Bool,
                hr: Int?, sleepSummary: String, asOf: Date,
                scoreDay: String? = nil) {
        self.charge = charge
        self.chargeCalibrating = chargeCalibrating
        self.effort = effort
        self.effortCalibrating = effortCalibrating
        self.rest = rest
        self.restCalibrating = restCalibrating
        self.hr = hr
        self.sleepSummary = sleepSummary
        self.asOf = asOf
        self.scoreDay = scoreDay
    }

    // MARK: - Shared app group transport
    // The watch and complication read the latest snapshot from the shared app group's UserDefaults under this key; the phone also writes it there
    // (alongside updateApplicationContext) so a fresh launch reads the last value immediately.

    /// The shared app group, injected from `APP_GROUP_ID` via the `AppGroupIdentifier` Info.plist key on ZoopiOS, ZoopWatch and ZoopWatchComplications (mirrors `WidgetSnapshot.suiteName`).
    /// The fallback below only applies when this package builds standalone (`swift test`) with no host bundle.
    public static let appGroupId: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.com.zoopapp.zoop"
    }()
    /// The UserDefaults key the latest snapshot is stored under in the shared app group.
    public static let storageKey = "latestWatchSnapshot"

    /// Neutral placeholder for previews / a not-yet-synced watch: everything calibrating and empty, nothing fake drawn.
    public static var placeholder: WatchScoreSnapshot {
        WatchScoreSnapshot(charge: nil, chargeCalibrating: true,
                           effort: nil, effortCalibrating: true,
                           rest: nil, restCalibrating: true,
                           hr: nil, sleepSummary: "", asOf: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Freshness
    // The watch only renders the last snapshot, which goes stale if it hasn't seen the phone. These helpers degrade a too-old snapshot to a dash and always show a short recency label.

    /// How old a snapshot may be before it stops being presented as current. ~36h, not 24h: Rest lands the morning after, so a little over a day is normal.
    private static let stalenessThreshold: TimeInterval = 36 * 3600

    /// True when too old to present as current: callers degrade rings + number to a dash (with `freshnessText` explaining). The placeholder (asOf at the epoch) always reads stale.
    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(asOf) > Self.stalenessThreshold
    }

    /// The semantic freshness buckets behind `freshnessText`. Reason about recency through `isFreshToday` (which switches on this), never by comparing the localized display string, which breaks in translations.
    private enum FreshnessKind {
        case today
        case yesterday
        case weekday(Date)
        case daysAgo(Int)
        case builtJustNow
        case builtMinutesAgo(Int)
        case builtHoursAgo(Int)
        case builtDaysAgo(Int)
    }

    /// Classify recency, preferring `scoreDay` (the day the scores are ABOUT) and falling back to the `asOf` build age for older payloads.
    private func freshnessKind(now: Date) -> FreshnessKind {
        let cal = Calendar.current

        // Preferred path: compare day keys against now so the label tracks the calendar day, not the build clock.
        if let scoreDay, let scored = Self.dayKeyFormatter.date(from: scoreDay) {
            if cal.isDateInToday(scored) { return .today }
            if cal.isDateInYesterday(scored) { return .yesterday }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: scored),
                                          to: cal.startOfDay(for: now)).day ?? 0
            // Within the last week a weekday name ("Mon") is the most readable; past that, a plain count.
            if days >= 2 && days <= 6 { return .weekday(scored) }
            return .daysAgo(max(days, 0))
        }

        // Fallback: no scoreDay (an older snapshot). Describe the build age of the snapshot itself.
        let age = now.timeIntervalSince(asOf)
        if age < 60 { return .builtJustNow }
        if age < 3600 { return .builtMinutesAgo(Int(age / 60)) }
        if age < 86_400 { return .builtHoursAgo(Int(age / 3600)) }
        return .builtDaysAgo(Int(age / 86_400))
    }

    /// Short recency label for the glance + complication, rendered off `freshnessKind` so the words and `isFreshToday` cannot drift.
    public func freshnessText(now: Date = Date()) -> String {
        switch freshnessKind(now: now) {
        case .today:                  return String(localized: "Today", bundle: .module)
        case .yesterday:              return String(localized: "Yesterday", bundle: .module)
        case .weekday(let scored):
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: scored)
        case .daysAgo(let days):      return String(localized: "\(days) days ago", bundle: .module)
        case .builtJustNow:           return String(localized: "just now", bundle: .module)
        case .builtMinutesAgo(let m): return String(localized: "\(m)m ago", bundle: .module)
        case .builtHoursAgo(let h):   return String(localized: "\(h)h ago", bundle: .module)
        case .builtDaysAgo(let d):    return String(localized: "\(d)d ago", bundle: .module)
        }
    }

    /// True when the scores read as CURRENT: they describe today's local day or (without `scoreDay`) the snapshot is under a minute old.
    /// Key display decisions off this, never the localized text. Derived at read time from fields already on the wire, so the payload is unchanged.
    public func isFreshToday(now: Date = Date()) -> Bool {
        switch freshnessKind(now: now) {
        case .today, .builtJustNow: return true
        default:                    return false
        }
    }

    /// Shared "YYYY-MM-DD" parser/formatter for `scoreDay`; fixed POSIX locale so it matches the phone's `Repository.localDayKey` in any region.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Decode the last snapshot the phone wrote into the shared app group, if any.
    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: appGroupId)) -> WatchScoreSnapshot? {
        guard let defaults,
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared app group so the watch app + complication can read it.
    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WatchScoreSnapshot.storageKey)
    }
}
