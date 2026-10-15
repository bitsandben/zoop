import Foundation
import WhoopProtocol

// HR-max (Tanaka 2001: 208 - 0.7 x age, optional manual override) and the five conventional %HRmax display
// zones: 50-60 / 60-70 / 70-80 / 80-90 / 90-100 %. Independent of the Karvonen %HRR zones used for strain
// in StrainScorer.swift.

/// A single heart-rate zone defined as a bpm interval [lower, upper).
public struct HRZone: Equatable, Sendable {
    public let number: Int
    public let lower: Double
    /// Upper bound (bpm); exclusive except for the top zone, where it is inclusive.
    public let upper: Double
    /// Fraction-of-HRmax lower bound.
    public let lowerPct: Double
    /// Fraction-of-HRmax upper bound.
    public let upperPct: Double

    public init(number: Int, lower: Double, upper: Double, lowerPct: Double, upperPct: Double) {
        self.number = number
        self.lower = lower
        self.upper = upper
        self.lowerPct = lowerPct
        self.upperPct = upperPct
    }
}

/// Five HR zones derived from a max HR or personalized BPM boundaries, plus the max HR and its source.
public struct HRZoneSet: Equatable, Sendable {
    public let zones: [HRZone]
    public let maxHR: Double
    /// "tanaka" (age formula), "manual" (caller override), or "custom" (personalized boundaries).
    public let source: String

    public init(zones: [HRZone], maxHR: Double, source: String) {
        self.zones = zones
        self.maxHR = maxHR
        self.source = source
    }

    /// Return the zone number (1...5) for a bpm value, or 0 when below Zone 1.
    public func zoneNumber(forBPM bpm: Double) -> Int {
        for z in zones {
            // Top zone is inclusive at its upper edge so HRmax itself lands in z5.
            if z.number == 5 {
                if bpm >= z.lower { return 5 }
            } else if bpm >= z.lower && bpm < z.upper {
                return z.number
            }
        }
        return 0
    }
}

/// Time spent in each zone (seconds), including below-Zone-1 time.
public struct TimeInZone: Equatable, Sendable {
    /// Seconds per zone, indexed z1...z5.
    public let seconds: [Double]
    public let belowZone1: Double

    public init(seconds: [Double], belowZone1: Double) {
        self.seconds = seconds
        self.belowZone1 = belowZone1
    }

    public var total: Double { seconds.reduce(0, +) + belowZone1 }

    public func seconds(inZone zone: Int) -> Double {
        guard zone >= 1 && zone <= 5 else { return 0 }
        return seconds[zone - 1]
    }
}

public enum HRZones {

    public static let zoneEdges: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    /// Editable BPM range for personalized zone starts; the analytics API accepts any positive finite values.
    public static let customBPMRange: ClosedRange<Int> = 30...250

    public static func tanakaMaxHR(age: Double) -> Double {
        208.0 - 0.7 * age
    }

    /// Builds the 5-zone set from age (Tanaka) or a manual `maxHROverride` (`source == "manual"`).
    public static func zones(age: Double,
                             maxHROverride: Double? = nil,
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        let maxHR: Double
        let source: String
        if let override = maxHROverride {
            maxHR = override
            source = "manual"
        } else {
            maxHR = tanakaMaxHR(age: age)
            source = "tanaka"
        }
        return zones(maxHR: maxHR, source: source, customLowerBounds: customLowerBounds)
    }

    /// Builds the 5-zone set from a known max HR, optionally with five personalized inclusive lower bounds (BPM).
    /// Invalid custom input falls back to the conventional model.
    public static func zones(maxHR: Double,
                             source: String = "manual",
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        let custom = customLowerBounds.flatMap(validCustomLowerBounds)
        var built: [HRZone] = []
        for i in 0..<5 {
            let lower = custom?[i] ?? zoneEdges[i] * maxHR
            let upper = custom.map { i < 4 ? $0[i + 1] : max(maxHR, $0[i]) }
                ?? zoneEdges[i + 1] * maxHR
            let loPct = maxHR > 0 ? lower / maxHR : 0
            let hiPct = maxHR > 0 ? upper / maxHR : 0
            built.append(HRZone(
                number: i + 1,
                lower: lower,
                upper: upper,
                lowerPct: loPct,
                upperPct: hiPct
            ))
        }
        return HRZoneSet(zones: built, maxHR: maxHR, source: custom == nil ? source : "custom")
    }

    /// The conventional lower bounds rounded up to whole BPM, preserving integer-sample classification.
    public static func defaultLowerBounds(maxHR: Double) -> [Int] {
        Array(zoneEdges.prefix(5)).map { Int(ceil($0 * maxHR)) }
    }

    /// Returns the custom bounds if positive, finite and strictly increasing, else nil; shared with backup validation.
    public static func validCustomLowerBounds(_ values: [Double]) -> [Double]? {
        guard values.count == 5,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        for i in 1..<values.count where values[i] <= values[i - 1] { return nil }
        return values
    }

    /// Time-in-zone (seconds) from an HR stream: each sample is credited until the next one, the last with the
    /// median inter-sample interval. Samples are sorted defensively.
    public static func timeInZone(_ hr: [HRSample], zoneSet: HRZoneSet) -> TimeInZone {
        let sorted = hr.sorted { $0.ts < $1.ts }
        var zoneSeconds = [Double](repeating: 0, count: 5)
        var below: Double = 0

        guard !sorted.isEmpty else {
            return TimeInZone(seconds: zoneSeconds, belowZone1: 0)
        }

        // Tail sample gets the median inter-sample gap.
        let tailDuration = medianInterval(sorted)

        for i in 0..<sorted.count {
            let dur: Double
            if i < sorted.count - 1 {
                let gap = Double(sorted[i + 1].ts - sorted[i].ts)
                // Cap at the median so one huge wall-clock gap can't swamp a bucket.
                dur = (gap > 0) ? min(gap, tailDuration) : tailDuration
            } else {
                dur = tailDuration
            }
            let z = zoneSet.zoneNumber(forBPM: Double(sorted[i].bpm))
            if z >= 1 {
                zoneSeconds[z - 1] += dur
            } else {
                below += dur
            }
        }
        return TimeInZone(seconds: zoneSeconds, belowZone1: below)
    }

    /// Median spacing between timestamps over plausible (0, 300 s] gaps; 1.0 s when none.
    static func medianInterval(_ sorted: [HRSample]) -> Double {
        guard sorted.count >= 2 else { return 1.0 }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let g = Double(sorted[i].ts - sorted[i - 1].ts)
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 1.0 }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }
}
