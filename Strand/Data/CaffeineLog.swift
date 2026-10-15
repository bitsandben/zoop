import Foundation

// MARK: - Caffeine window (#526) — log an intake + a rough on-device "still active" estimate
//
// Opt-in, manual-first caffeine log: the user logs a time and optionally mg, and Zoop shows a "still
// active" hint from first-order half-life decay.
// A rough guide from what was logged, not a measurement or health claim (half-life varies a lot between
// people). UserDefaults-backed, on-device; empty by default.

/// Pure caffeine half-life decay math: the fraction remaining after `t` hours is `0.5 ^ (t /
/// halfLifeHours)`; intakes add. Default half-life 5.5 h (population-average adult, ~5-6 h).
public enum CaffeineDecay {

    /// Half-life in hours. A population average; real clearance varies widely, so it is never presented as
    /// a per-user value.
    public static let defaultHalfLifeHours = 5.5

    /// Fraction (0...1) of a dose left `hoursElapsed` after intake. Negative elapsed (future-dated log)
    /// clamps to 1.0.
    public static func fractionRemaining(hoursElapsed: Double,
                                         halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        guard halfLifeHours > 0 else { return 0 }
        let t = max(0, hoursElapsed)
        return pow(0.5, t / halfLifeHours)
    }

    /// Estimated mg still active from one dose.
    public static func remainingMg(doseMg: Double, hoursElapsed: Double,
                                   halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        max(0, doseMg) * fractionRemaining(hoursElapsed: hoursElapsed, halfLifeHours: halfLifeHours)
    }

    /// Total mg still active across intakes. Unknown-dose intakes are excluded (no invented amounts);
    /// `isStillActive` covers them.
    public static func totalRemainingMg(_ intakes: [(doseMg: Double, hoursElapsed: Double)],
                                        halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        intakes.reduce(0) { $0 + remainingMg(doseMg: $1.doseMg, hoursElapsed: $1.hoursElapsed,
                                             halfLifeHours: halfLifeHours) }
    }

    /// Hours until a dose decays to `fraction` of itself (default 25%, about two half-lives).
    public static func hoursUntilFraction(_ fraction: Double,
                                          halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        guard fraction > 0, fraction < 1, halfLifeHours > 0 else { return 0 }
        return halfLifeHours * (log(fraction) / log(0.5))
    }

    /// True when more than `threshold` (default 25%) of a dose remains. Used when the dose is unknown.
    public static func isStillActive(hoursElapsed: Double,
                                     threshold: Double = 0.25,
                                     halfLifeHours: Double = defaultHalfLifeHours) -> Bool {
        fractionRemaining(hoursElapsed: hoursElapsed, halfLifeHours: halfLifeHours) > threshold
    }

    // MARK: - Cutoff window (PR#566, mvanhorn) — the latest caffeine time before bed.
    // Cutoff framing: bedtime minus `hoursUntilFraction(target)`. A dose at the cutoff decays to exactly
    // `targetResidualFraction` by bedtime.

    /// Default residual at bedtime (a quarter of the dose), matching `isStillActive` so the two agree.
    public static let defaultBedtimeResidual = 0.25

    /// Hours before bedtime the cutoff falls. Pure number; the UI subtracts it from bedtime.
    public static func cutoffLeadHours(targetResidualFraction: Double = defaultBedtimeResidual,
                                       halfLifeHours: Double = defaultHalfLifeHours) -> Double {
        hoursUntilFraction(targetResidualFraction, halfLifeHours: halfLifeHours)
    }

    /// Cutoff as minutes since midnight, normalised into [0, 1440).
    public static func cutoffMinutesSinceMidnight(bedtimeMinutes: Int,
                                                  targetResidualFraction: Double = defaultBedtimeResidual,
                                                  halfLifeHours: Double = defaultHalfLifeHours) -> Int {
        let leadMin = Int(cutoffLeadHours(targetResidualFraction: targetResidualFraction,
                                          halfLifeHours: halfLifeHours) * 60)
        let raw = bedtimeMinutes - leadMin
        return ((raw % 1440) + 1440) % 1440
    }

    /// True when an intake is later than the cutoff for `bedtimeMinutes`.
    public static func isPastCutoff(intakeMinutes: Int,
                                    bedtimeMinutes: Int,
                                    targetResidualFraction: Double = defaultBedtimeResidual,
                                    halfLifeHours: Double = defaultHalfLifeHours) -> Bool {
        let leadMin = Int(cutoffLeadHours(targetResidualFraction: targetResidualFraction,
                                          halfLifeHours: halfLifeHours) * 60)
        // Raw (un-normalised) axis, so a cutoff in the previous evening makes every same-day intake past cutoff.
        return intakeMinutes > (bedtimeMinutes - leadMin)
    }
}

/// One logged caffeine intake: a timestamp and an optional mg amount.
public struct CaffeineIntake: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    /// Amount in mg; nil means unknown (never invented).
    public let mg: Double?
    /// Apple Health sample UUID, or nil when logged in Zoop (#949). Optional so old JSON still decodes;
    /// lets a re-import recognise an existing drink.
    public let externalId: String?

    /// True when from Apple Health. Imported intakes are not editable here.
    public var isImported: Bool { externalId != nil }

    public init(id: UUID = UUID(), at: Date, mg: Double? = nil, externalId: String? = nil) {
        self.id = id; self.at = at; self.mg = mg; self.externalId = externalId
    }
}

/// Summary of the caffeine still active now.
public struct CaffeineActiveEstimate: Equatable, Sendable {
    public let activeIntakeCount: Int
    /// Total mg still active across intakes with a known dose; nil when none had an amount.
    public let totalRemainingMg: Double?
    /// Hours since the most recent still-active intake.
    public let hoursSinceMostRecentActive: Double?

    public var hasActive: Bool { activeIntakeCount > 0 }

    public init(activeIntakeCount: Int, totalRemainingMg: Double?, hoursSinceMostRecentActive: Double?) {
        self.activeIntakeCount = activeIntakeCount
        self.totalRemainingMg = totalRemainingMg
        self.hoursSinceMostRecentActive = hoursSinceMostRecentActive
    }

    /// Builds the estimate for `now` from the intakes using the decay model.
    public static func compute(intakes: [CaffeineIntake], now: Date = Date(),
                               halfLifeHours: Double = CaffeineDecay.defaultHalfLifeHours,
                               activeThreshold: Double = 0.25) -> CaffeineActiveEstimate {
        var activeCount = 0
        var mgSum = 0.0
        var anyMg = false
        var mostRecentActiveHours: Double?

        for intake in intakes {
            let hours = now.timeIntervalSince(intake.at) / 3600.0
            // Future-dated intakes are not active yet.
            guard hours >= 0,
                  CaffeineDecay.isStillActive(hoursElapsed: hours, threshold: activeThreshold,
                                              halfLifeHours: halfLifeHours) else { continue }
            activeCount += 1
            if let mg = intake.mg {
                mgSum += CaffeineDecay.remainingMg(doseMg: mg, hoursElapsed: hours, halfLifeHours: halfLifeHours)
                anyMg = true
            }
            if mostRecentActiveHours == nil || hours < mostRecentActiveHours! {
                mostRecentActiveHours = hours
            }
        }
        return CaffeineActiveEstimate(activeIntakeCount: activeCount,
                                      totalRemainingMg: anyMg ? mgSum : nil,
                                      hoursSinceMostRecentActive: mostRecentActiveHours)
    }
}

/// UserDefaults-backed store of logged intakes (single user, default empty). Intakes past the cleared
/// horizon are pruned on load.
@MainActor
public final class CaffeineLogStore: ObservableObject {

    /// Process-wide store (#949). The Apple Health import writes from outside the card, so a second
    /// instance over one key would publish stale data.
    public static let shared = CaffeineLogStore()

    /// Logged intakes, newest first, persisted as JSON.
    @Published public private(set) var intakes: [CaffeineIntake] { didSet { save() } }

    private let d: UserDefaults
    private let now: () -> Date
    private static let key = "caffeine.intakes"
    /// Intakes older than this many hours are dropped on load (past the decay horizon).
    static let retentionHours = 48.0

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.d = defaults
        self.now = now
        let loaded = (try? JSONDecoder().decode([CaffeineIntake].self,
                                                from: d.data(forKey: Self.key) ?? Data())) ?? []
        let cutoff = now().addingTimeInterval(-Self.retentionHours * 3600)
        self.intakes = loaded
            .filter { $0.at >= cutoff }
            .sorted { $0.at > $1.at }
    }

    /// Logs a new intake; pass nil `mg` for an unknown amount.
    public func log(at date: Date, mg: Double? = nil) {
        // Non-finite or negative mg is stored as nil so it cannot poison the estimate.
        let cleanMg: Double? = {
            guard let mg, mg.isFinite, mg > 0 else { return nil }
            return min(mg, 2000)   // a sane upper clamp (no single drink is ~2000 mg)
        }()
        intakes = ([CaffeineIntake(at: date, mg: cleanMg)] + intakes).sorted { $0.at > $1.at }
    }

    /// Replaces every imported intake with `imported`, leaving hand-logged ones alone (#949). Wholesale
    /// replacement makes re-import idempotent and drops drinks deleted in the source app.
    public func replaceImported(_ imported: [CaffeineIntake]) {
        let manual = intakes.filter { !$0.isImported }
        let next = (manual + imported).sorted { $0.at > $1.at }
        // Skip the write when unchanged: `intakes` persists in didSet and this runs every sync.
        if next != intakes { intakes = next }
    }

    /// Removes a hand-logged intake. Imported ones are a no-op, since the next sync would bring them straight back.
    public func remove(_ id: UUID) {
        guard let hit = intakes.first(where: { $0.id == id }), !hit.isImported else { return }
        intakes = intakes.filter { $0.id != id }
    }

    /// Clears hand-logged intakes only; imported ones would repopulate on the next sync (#949).
    public func clearAll() {
        intakes = intakes.filter { $0.isImported }
    }

    /// Current "still active" estimate at `now()`.
    public func estimate(halfLifeHours: Double = CaffeineDecay.defaultHalfLifeHours)
        -> CaffeineActiveEstimate {
        CaffeineActiveEstimate.compute(intakes: intakes, now: now(), halfLifeHours: halfLifeHours)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(intakes) { d.set(data, forKey: Self.key) }
    }
}
