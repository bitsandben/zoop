import Foundation
import WhoopStore

// MARK: - Muscle load
//
// Which muscle groups the last week of training loaded, from any workout, not only the Lift Log. An openly
// stated estimate: nothing on the strap sees which muscles worked.
//   - Each sport has a fixed 0...1 involvement table per group (`involvement(sport:)`); unknown sports get a
//     light even full-body table.
//   - Load = involvement x minutes x intensity (heart-rate reserve when avg HR and max/resting HR are known,
//     else Effort, else 1).
//   - A Lift Log session uses its own fractional sets (`LiftMetrics.muscleCounts`) at `loadPerSet` units per
//     set, so a logged lift is never counted twice via its workout row.
//   - State compares this week's load with the mean group ("share") and the person's own 4-week weekly average
//     ("ratio"): High = share >= 1.6, or ratio >= 1.5 with share >= 0.8; Under = share <= 0.4, or ratio <= 0.5
//     with share < 1; else Balanced. The ratio rule applies only once history spans 14 days.
//   - Recovery reuses `MuscleRecovery`'s linear decay: window grows with set-equivalent dose (load / loadPerSet),
//     starting fatigue (dose - 0.5) / 4 capped at 1, so a group that barely took part reads recovered.

public enum MuscleLoad {

    /// Load units one fractional working set counts as (about eight minutes of full involvement).
    public static let loadPerSet = 8.0
    public static let highShare = 1.6
    public static let underShare = 0.4
    public static let highRatio = 1.5
    public static let underRatio = 0.5
    /// Days of history before the personal-ratio rule applies.
    public static let ratioMinHistoryDays = 14
    /// No workout ended within this many days: no result.
    public static let recentDays = 14
    public static let weeks = 4

    // MARK: Groups

    public enum Group: String, CaseIterable, Sendable, Hashable {
        case chest, shoulders, biceps, triceps, forearms, core
        case upperBack, lats, lowerBack, glutes, quads, hamstrings, calves

        public enum Region: String, CaseIterable, Sendable { case upperBody, core, legs }

        public var region: Region {
            switch self {
            case .chest, .shoulders, .biceps, .triceps, .forearms, .upperBack, .lats: return .upperBody
            case .core, .lowerBack: return .core
            case .glutes, .quads, .hamstrings, .calves: return .legs
            }
        }

        /// The coarse group a Lift Log muscle counts toward.
        public init(lift: LiftMuscle) {
            switch lift {
            case .chest: self = .chest
            case .frontDelts, .sideDelts, .rearDelts: self = .shoulders
            case .triceps: self = .triceps
            case .lats: self = .lats
            case .upperBack, .traps, .neck: self = .upperBack
            case .biceps: self = .biceps
            case .forearms: self = .forearms
            case .quads, .adductors: self = .quads
            case .hamstrings: self = .hamstrings
            case .glutes, .abductors: self = .glutes
            case .calves: self = .calves
            case .abs, .obliques: self = .core
            case .lowerBack: self = .lowerBack
            }
        }
    }

    public enum State: String, Sendable { case under, balanced, high }

    // MARK: Input

    public struct Session: Sendable, Equatable {
        /// Stored sport name, shown in the detail sheet.
        public let sport: String
        public let startTs: Int
        public let endTs: Int
        /// Load per group for this session.
        public let load: [Group: Double]
        /// A Lift Log session rated hard (mean working RPE >= 9): longer recovery window.
        public let hard: Bool

        public init(sport: String, startTs: Int, endTs: Int, load: [Group: Double], hard: Bool = false) {
            self.sport = sport; self.startTs = startTs; self.endTs = endTs; self.load = load; self.hard = hard
        }

        /// A workout from its sport table.
        public static func workout(sport: String, startTs: Int, endTs: Int, minutes: Double,
                                   intensity: Double) -> Session {
            let table = MuscleLoad.involvement(sport: sport)
            let m = Swift.max(0, minutes), k = Swift.max(0, intensity)
            return Session(sport: sport, startTs: startTs, endTs: endTs,
                           load: table.mapValues { $0 * m * k })
        }

        /// A stored workout row; HR reserve when the profile allows, else Effort.
        public static func workout(_ row: WorkoutRow, hrMax: Int?, restingHr: Int?) -> Session {
            let minutes = (row.durationS ?? Double(row.endTs - row.startTs)) / 60
            return workout(sport: row.sport, startTs: row.startTs, endTs: row.endTs, minutes: minutes,
                           intensity: MuscleLoad.intensity(avgHr: row.avgHr, hrMax: hrMax,
                                                           restingHr: restingHr, effort: row.strain))
        }

        /// A Lift Log session from its logged sets.
        public static func lift(sport: String, startTs: Int, endTs: Int, sets: [LiftSetRow]) -> Session {
            var load: [Group: Double] = [:]
            for (muscle, n) in LiftMetrics.muscleCounts(sets).fractional where n > 0 {
                load[Group(lift: muscle), default: 0] += n * MuscleLoad.loadPerSet
            }
            let hard = (LiftMetrics.rpeProfile(sets).mean ?? 0) >= MuscleRecovery.hardSessionRpe
            return Session(sport: sport, startTs: startTs, endTs: endTs, load: load, hard: hard)
        }
    }

    /// 0.4...1.6; heart-rate reserve 0.5 or Effort 40 reads 1.0.
    public static func intensity(avgHr: Int?, hrMax: Int?, restingHr: Int?, effort: Double?) -> Double {
        if let a = avgHr, let mx = hrMax, let r = restingHr, mx > r, a > 0 {
            let hrr = Swift.max(0, Swift.min(1, Double(a - r) / Double(mx - r)))
            return Swift.max(0.4, Swift.min(1.6, 0.4 + 1.2 * hrr))
        }
        if let e = effort, e > 0 {
            return Swift.max(0.4, Swift.min(1.6, 0.6 + e / 100))
        }
        return 1
    }

    // MARK: Output

    public struct Contribution: Sendable, Equatable {
        public let sport: String
        public let startTs: Int
        public let load: Double
    }

    public struct Entry: Sendable, Equatable {
        public let group: Group
        /// Load in the last 7 days.
        public let weekLoad: Double
        /// Mean weekly load over the last four weeks (this week included).
        public let weeklyAverage: Double
        /// weekLoad / weeklyAverage; nil while history is too short or the average is zero.
        public let ratio: Double?
        /// weekLoad / the mean group's weekLoad this week.
        public let share: Double
        public let state: State
        public let percentRecovered: Int
        public let hoursToFull: Double
        /// Weekly loads, oldest first, last = this week.
        public let weeklyLoads: [Double]
        /// This week's sessions that loaded this group, largest first.
        public let contributions: [Contribution]
    }

    public enum Verdict: Sendable, Equatable {
        case quietWeek
        case balanced
        /// `top` carried most of the load; `sport` drove it when one sport gave most; `lowRegion` is a body region with little work.
        case focused(top: [Group], sport: String?, lowRegion: Group.Region?)
    }

    public struct Result: Sendable, Equatable {
        public let entries: [Entry]
        public let verdict: Verdict
        public func entry(_ g: Group) -> Entry? { entries.first { $0.group == g } }
    }

    // MARK: Compute

    /// Nil when no session ended within `recentDays` of `now`.
    public static func compute(sessions: [Session], now: Int) -> Result? {
        let past = sessions.filter { $0.endTs <= now }
        let day = 86_400
        guard past.contains(where: { $0.endTs > now - recentDays * day }) else { return nil }

        let weekStart = now - 7 * day
        let windowStart = now - weeks * 7 * day
        let inWindow = past.filter { $0.endTs > windowStart }
        let earliest = inWindow.map(\.startTs).min() ?? now
        let ratioUsable = now - earliest >= ratioMinHistoryDays * day

        var weekly: [Group: [Double]] = [:]
        for g in Group.allCases { weekly[g] = Array(repeating: 0, count: weeks) }
        for s in inWindow {
            let k = (now - s.endTs) / (7 * day)   // 0 = this week
            guard k >= 0 && k < weeks else { continue }
            for (g, v) in s.load { weekly[g]?[weeks - 1 - k] += v }
        }
        let thisWeek = inWindow.filter { $0.endTs > weekStart }
        let weekTotals = Group.allCases.map { weekly[$0]?.last ?? 0 }
        let meanGroup = weekTotals.reduce(0, +) / Double(Group.allCases.count)

        let recovery = recoveryState(sessions: past, now: now)

        var entries: [Entry] = Group.allCases.map { g in
            let loads = weekly[g] ?? []
            let week = loads.last ?? 0
            let avg = loads.reduce(0, +) / Double(weeks)
            let ratio: Double? = (ratioUsable && avg > 0) ? week / avg : nil
            let share = meanGroup > 0 ? week / meanGroup : 0
            let state: State
            if meanGroup <= 0 {
                state = .under
            } else if share >= highShare || (ratio.map { $0 >= highRatio } == true && share >= 0.8) {
                state = .high
            } else if share <= underShare || (ratio.map { $0 <= underRatio } == true && share < 1) {
                state = .under
            } else {
                state = .balanced
            }
            let contributions = thisWeek.compactMap { s -> Contribution? in
                guard let v = s.load[g], v > 0 else { return nil }
                return Contribution(sport: s.sport, startTs: s.startTs, load: v)
            }.sorted { $0.load > $1.load }
            let rec = recovery[g] ?? (fatigue: 0, toFull: 0)
            return Entry(group: g, weekLoad: week, weeklyAverage: avg, ratio: ratio, share: share,
                         state: state,
                         percentRecovered: Int((100 * (1 - Swift.min(1, rec.fatigue))).rounded(.down)),
                         hoursToFull: rec.toFull, weeklyLoads: loads, contributions: contributions)
        }
        let order = Dictionary(uniqueKeysWithValues: Group.allCases.enumerated().map { ($1, $0) })
        entries.sort {
            $0.weekLoad != $1.weekLoad ? $0.weekLoad > $1.weekLoad
                : (order[$0.group] ?? 0) < (order[$1.group] ?? 0)
        }
        return Result(entries: entries, verdict: verdict(entries: entries, thisWeek: thisWeek))
    }

    static func verdict(entries: [Entry], thisWeek: [Session]) -> Verdict {
        guard entries.contains(where: { $0.weekLoad > 0 }) else { return .quietWeek }
        let high = entries.filter { $0.state == .high }
        guard !high.isEmpty else { return .balanced }
        let top = Array(high.prefix(2).map(\.group))

        // Sport giving >= 60% of the top groups' load, if any.
        var bySport: [String: Double] = [:]
        var total = 0.0
        for s in thisWeek {
            let v = top.reduce(0) { $0 + (s.load[$1] ?? 0) }
            bySport[s.sport, default: 0] += v
            total += v
        }
        let sport = bySport.max { $0.value < $1.value }.flatMap { total > 0 && $0.value / total >= 0.6 ? $0.key : nil }

        // A region mostly Under that holds none of the top groups.
        let topRegions = Set(top.map(\.region))
        let low = Group.Region.allCases.filter { !topRegions.contains($0) }.compactMap { r -> (Group.Region, Double)? in
            let inRegion = entries.filter { $0.group.region == r }
            let under = inRegion.filter { $0.state == .under }.count
            guard !inRegion.isEmpty, Double(under) / Double(inRegion.count) >= 0.5 else { return nil }
            return (r, inRegion.map(\.share).reduce(0, +) / Double(inRegion.count))
        }.min { $0.1 < $1.1 }?.0
        return .focused(top: top, sport: sport, lowRegion: low)
    }

    /// Fatigue (0...1+) and hours to full per group at `now` (`MuscleRecovery` linear decay on set-equivalent doses).
    static func recoveryState(sessions: [Session], now: Int) -> [Group: (fatigue: Double, toFull: Double)] {
        var out: [Group: (fatigue: Double, toFull: Double)] = [:]
        for s in sessions where s.endTs <= now {
            let elapsed = Double(now - s.endTs) / 3600
            for (g, v) in s.load where v > 0 {
                let dose = v / loadPerSet
                let window = MuscleRecovery.windowHours(sets: dose, hard: s.hard)
                guard elapsed < window else { continue }
                let start = Swift.min(1, Swift.max(0, dose - 0.5) / 4)
                var cur = out[g] ?? (0, 0)
                cur.fatigue += start * (1 - elapsed / window)
                cur.toFull = Swift.max(cur.toFull, window - elapsed)
                out[g] = cur
            }
        }
        return out
    }

    /// Filled segments of a 10-segment bar for a load share (share >= 2 fills it).
    public static func filledSegments(share: Double, of segments: Int = 10) -> Int {
        Swift.max(0, Swift.min(segments, Int((share / 2 * Double(segments)).rounded())))
    }

    // MARK: Sport table

    public typealias Table = [Group: Double]

    /// Involvement 0...1 per group for a stored sport name (catalogue and HealthKit camel-case names); unknown gets a light full-body table.
    public static func involvement(sport: String) -> Table {
        let key = normalized(sport)
        if let t = exact[key] { return t }
        for (needle, t) in keywords where key.contains(needle) { return t }
        return generic
    }

    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static let generic: Table = [
        .chest: 0.3, .shoulders: 0.3, .biceps: 0.3, .triceps: 0.3, .forearms: 0.3, .core: 0.3,
        .upperBack: 0.3, .lats: 0.3, .lowerBack: 0.3, .glutes: 0.4, .quads: 0.4, .hamstrings: 0.4, .calves: 0.4,
    ]
    static let running: Table = [
        .quads: 1, .hamstrings: 0.8, .calves: 1, .glutes: 0.8, .core: 0.4, .lowerBack: 0.3,
        .shoulders: 0.1, .upperBack: 0.1, .lats: 0.05, .chest: 0.05, .triceps: 0.05, .biceps: 0.05, .forearms: 0.05,
    ]
    static let walking: Table = [
        .quads: 0.5, .hamstrings: 0.4, .calves: 0.6, .glutes: 0.5, .core: 0.2, .lowerBack: 0.15,
    ]
    static let hiking: Table = [
        .quads: 0.8, .hamstrings: 0.6, .calves: 0.8, .glutes: 0.8, .core: 0.35, .lowerBack: 0.35,
        .upperBack: 0.15, .shoulders: 0.1,
    ]
    static let cycling: Table = [
        .quads: 1, .glutes: 0.8, .calves: 0.6, .hamstrings: 0.6, .core: 0.3, .lowerBack: 0.2,
        .forearms: 0.1, .shoulders: 0.05,
    ]
    static let swimming: Table = [
        .shoulders: 1, .lats: 1, .triceps: 0.6, .chest: 0.6, .upperBack: 0.7, .core: 0.5, .lowerBack: 0.3,
        .biceps: 0.3, .forearms: 0.3, .glutes: 0.15, .quads: 0.15, .hamstrings: 0.15, .calves: 0.1,
    ]
    static let rowing: Table = [
        .upperBack: 0.9, .lats: 0.9, .quads: 0.8, .glutes: 0.7, .hamstrings: 0.6, .biceps: 0.6, .core: 0.6,
        .lowerBack: 0.6, .forearms: 0.5, .shoulders: 0.4, .calves: 0.3, .triceps: 0.1,
    ]
    static let paddling: Table = [
        .lats: 0.9, .shoulders: 0.9, .upperBack: 0.8, .core: 0.7, .biceps: 0.5, .triceps: 0.4,
        .forearms: 0.5, .chest: 0.3, .lowerBack: 0.3,
    ]
    static let climbing: Table = [
        .forearms: 1, .lats: 0.9, .upperBack: 0.8, .biceps: 0.8, .core: 0.6, .shoulders: 0.5,
        .calves: 0.3, .quads: 0.3, .glutes: 0.3, .hamstrings: 0.2, .lowerBack: 0.3,
    ]
    static let boxing: Table = [
        .shoulders: 1, .triceps: 0.6, .chest: 0.5, .core: 0.7, .upperBack: 0.4, .calves: 0.5, .quads: 0.4,
        .glutes: 0.3, .forearms: 0.4, .biceps: 0.3, .lats: 0.3, .hamstrings: 0.2, .lowerBack: 0.3,
    ]
    static let kickboxing: Table = [
        .shoulders: 0.8, .core: 0.8, .quads: 0.7, .glutes: 0.6, .hamstrings: 0.5, .calves: 0.5,
        .triceps: 0.5, .chest: 0.4, .upperBack: 0.3, .forearms: 0.3, .lats: 0.3, .biceps: 0.2, .lowerBack: 0.3,
    ]
    static let grappling: Table = [
        .forearms: 0.8, .core: 0.8, .upperBack: 0.7, .lats: 0.6, .biceps: 0.6, .glutes: 0.6, .quads: 0.6,
        .shoulders: 0.6, .hamstrings: 0.5, .chest: 0.5, .lowerBack: 0.5, .triceps: 0.4, .calves: 0.3,
    ]
    static let racket: Table = [
        .shoulders: 0.7, .forearms: 0.7, .quads: 0.7, .calves: 0.7, .glutes: 0.5, .core: 0.5,
        .hamstrings: 0.4, .triceps: 0.3, .chest: 0.3, .upperBack: 0.3, .lowerBack: 0.3, .lats: 0.2, .biceps: 0.2,
    ]
    static let fieldTeam: Table = [
        .quads: 0.9, .hamstrings: 0.9, .calves: 0.8, .glutes: 0.8, .core: 0.5, .lowerBack: 0.3,
        .shoulders: 0.15, .upperBack: 0.15, .chest: 0.1, .lats: 0.1,
    ]
    static let contactTeam: Table = [
        .quads: 0.8, .hamstrings: 0.7, .glutes: 0.8, .calves: 0.6, .core: 0.6, .shoulders: 0.5,
        .upperBack: 0.5, .chest: 0.5, .lowerBack: 0.4, .lats: 0.3, .forearms: 0.3, .triceps: 0.3, .biceps: 0.3,
    ]
    static let courtTeam: Table = [
        .quads: 0.8, .calves: 0.9, .glutes: 0.7, .hamstrings: 0.6, .shoulders: 0.5, .core: 0.5,
        .triceps: 0.3, .chest: 0.2, .forearms: 0.3, .upperBack: 0.2, .lats: 0.2, .lowerBack: 0.2,
    ]
    static let yoga: Table = [
        .core: 0.6, .shoulders: 0.5, .glutes: 0.4, .hamstrings: 0.5, .quads: 0.4, .lowerBack: 0.4,
        .triceps: 0.3, .chest: 0.3, .upperBack: 0.3, .calves: 0.3, .forearms: 0.2, .lats: 0.2,
    ]
    static let pilates: Table = [
        .core: 1, .glutes: 0.6, .lowerBack: 0.5, .hamstrings: 0.4, .quads: 0.3, .shoulders: 0.3, .upperBack: 0.3,
    ]
    static let stretching: Table = [
        .hamstrings: 0.2, .lowerBack: 0.2, .glutes: 0.15, .quads: 0.15, .shoulders: 0.15, .core: 0.1,
    ]
    static let hiit: Table = [
        .quads: 0.8, .glutes: 0.7, .core: 0.7, .hamstrings: 0.6, .calves: 0.6, .shoulders: 0.6, .chest: 0.5,
        .triceps: 0.5, .upperBack: 0.4, .lats: 0.3, .lowerBack: 0.4, .biceps: 0.3, .forearms: 0.3,
    ]
    static let crossfit: Table = [
        .quads: 0.8, .glutes: 0.8, .shoulders: 0.8, .core: 0.7, .hamstrings: 0.7, .upperBack: 0.7,
        .lats: 0.6, .lowerBack: 0.6, .forearms: 0.6, .triceps: 0.5, .chest: 0.5, .biceps: 0.4, .calves: 0.4,
    ]
    /// A strength session with no Lift Log sets: an even, moderate full-body guess.
    static let strength: Table = [
        .chest: 0.6, .shoulders: 0.6, .triceps: 0.5, .biceps: 0.5, .forearms: 0.4, .core: 0.5,
        .upperBack: 0.6, .lats: 0.6, .lowerBack: 0.5, .glutes: 0.6, .quads: 0.6, .hamstrings: 0.5, .calves: 0.3,
    ]
    static let calisthenics: Table = [
        .chest: 0.7, .shoulders: 0.7, .triceps: 0.7, .lats: 0.7, .biceps: 0.6, .core: 0.8, .upperBack: 0.6,
        .forearms: 0.5, .quads: 0.4, .glutes: 0.4, .hamstrings: 0.2, .lowerBack: 0.3, .calves: 0.2,
    ]
    static let skiing: Table = [
        .quads: 1, .glutes: 0.8, .core: 0.6, .hamstrings: 0.5, .calves: 0.5, .lowerBack: 0.4,
        .shoulders: 0.2, .triceps: 0.2, .forearms: 0.2,
    ]
    static let skating: Table = [
        .quads: 0.9, .glutes: 0.9, .hamstrings: 0.6, .calves: 0.5, .core: 0.5, .lowerBack: 0.4,
    ]
    static let elliptical: Table = [
        .quads: 0.8, .glutes: 0.7, .hamstrings: 0.6, .calves: 0.5, .core: 0.3, .shoulders: 0.2,
        .chest: 0.15, .upperBack: 0.2, .lats: 0.15, .triceps: 0.15, .biceps: 0.15,
    ]
    static let stairs: Table = [
        .quads: 1, .glutes: 1, .calves: 0.8, .hamstrings: 0.6, .core: 0.3, .lowerBack: 0.2,
    ]
    static let jumpRope: Table = [
        .calves: 1, .quads: 0.6, .shoulders: 0.4, .forearms: 0.4, .core: 0.4, .glutes: 0.4, .hamstrings: 0.3,
    ]
    static let dancing: Table = [
        .calves: 0.7, .quads: 0.6, .glutes: 0.6, .core: 0.5, .hamstrings: 0.4, .shoulders: 0.2, .lowerBack: 0.2,
    ]
    static let golf: Table = [
        .core: 0.5, .shoulders: 0.4, .forearms: 0.4, .lowerBack: 0.4, .glutes: 0.3, .lats: 0.3,
        .quads: 0.3, .calves: 0.2, .hamstrings: 0.2,
    ]
    static let surfing: Table = [
        .shoulders: 0.9, .lats: 0.9, .upperBack: 0.7, .triceps: 0.5, .core: 0.6, .chest: 0.4, .lowerBack: 0.5,
        .quads: 0.4, .glutes: 0.4, .biceps: 0.3, .forearms: 0.3,
    ]
    static let gymnastics: Table = [
        .shoulders: 0.9, .core: 0.9, .chest: 0.6, .triceps: 0.7, .lats: 0.6, .upperBack: 0.6, .forearms: 0.6,
        .biceps: 0.5, .glutes: 0.5, .quads: 0.5, .hamstrings: 0.4, .lowerBack: 0.5, .calves: 0.4,
    ]
    static let throwing: Table = [
        .shoulders: 0.6, .core: 0.6, .quads: 0.5, .glutes: 0.5, .hamstrings: 0.5, .calves: 0.4,
        .forearms: 0.4, .lats: 0.3, .chest: 0.3, .triceps: 0.3, .lowerBack: 0.3, .upperBack: 0.3,
    ]
    static let light: Table = [
        .core: 0.1, .shoulders: 0.1, .forearms: 0.1, .quads: 0.1, .glutes: 0.1, .calves: 0.1, .lowerBack: 0.1,
    ]

    static let exact: [String: Table] = [
        "running": running, "treadmillrun": running, "trailrunning": running, "run": running,
        "walking": walking, "treadmillwalk": walking, "rucking": hiking, "hiking": hiking,
        "snowshoeing": hiking,
        "cycling": cycling, "indoorcycle": cycling, "spinning": cycling, "mountainbiking": cycling,
        "openwaterswim": swimming, "poolswim": swimming, "swimming": swimming, "waterpolo": swimming,
        "rowing": rowing, "rowmachine": rowing,
        "kayaking": paddling, "standuppaddleboard": paddling, "paddling": paddling,
        "climbing": climbing,
        "boxing": boxing, "kickboxing": kickboxing, "martialarts": grappling, "fencing": racket,
        "tennis": racket, "squash": racket, "racquetball": racket, "padel": racket, "pickleball": racket,
        "badminton": racket, "tabletennis": racket,
        "soccer": fieldTeam, "football": fieldTeam, "fieldhockey": fieldTeam, "lacrosse": fieldTeam,
        "gaelicfootball": fieldTeam, "frisbee": fieldTeam,
        "americanfootball": contactTeam, "australianfootball": contactTeam, "rugby": contactTeam,
        "icehockey": contactTeam,
        "basketball": courtTeam, "volleyball": courtTeam, "sandvolleyball": courtTeam, "handball": courtTeam,
        "netball": courtTeam, "spikeball": courtTeam,
        "baseball": throwing, "softball": throwing, "cricket": throwing,
        "yoga": yoga, "pilates": pilates, "stretching": stretching,
        "hiit": hiit, "bootcamp": hiit, "crossfit": crossfit,
        "strength": strength, "weightlifting": strength, "bodybuilding": strength, "powerlifting": strength,
        "calisthenics": calisthenics, "gymnastics": gymnastics,
        "skiing": skiing, "snowboarding": skiing,
        "iceskating": skating, "inlineskating": skating, "skateboarding": skating,
        "elliptical": elliptical, "stairclimber": stairs, "jumprope": jumpRope, "dancing": dancing,
        "golf": golf, "surfing": surfing,
        "meditation": [:], "bowling": light, "archery": light, "fishing": light, "hunting": light,
        "curling": light, "sailing": light, "scubadiving": swimming, "horsebackriding": light,
    ]

    /// Substring fallbacks for names outside the catalogue; first match wins.
    static let keywords: [(String, Table)] = [
        ("swim", swimming), ("run", running), ("jog", running), ("walk", walking), ("hik", hiking),
        ("cycl", cycling), ("bik", cycling), ("spin", cycling), ("row", rowing), ("paddl", paddling),
        ("kayak", paddling), ("climb", climbing), ("boulder", climbing), ("kickbox", kickboxing),
        ("box", boxing), ("martial", grappling), ("wrestl", grappling), ("jiujitsu", grappling),
        ("tennis", racket), ("intervaltraining", hiit), ("hiit", hiit), ("crossfit", crossfit),
        ("crosstraining", crossfit), ("strength", strength), ("weight", strength), ("lift", strength),
        ("yoga", yoga), ("pilates", pilates), ("stretch", stretching), ("flexibility", stretching),
        ("ski", skiing), ("snowboard", skiing), ("skat", skating), ("elliptical", elliptical),
        ("stair", stairs), ("step", stairs), ("dance", dancing), ("soccer", fieldTeam),
        ("football", contactTeam), ("hockey", contactTeam), ("rugby", contactTeam),
        ("basketball", courtTeam), ("volleyball", courtTeam), ("golf", golf), ("surf", surfing),
        ("core", pilates), ("mindandbody", yoga), ("cooldown", stretching),
    ]
}
