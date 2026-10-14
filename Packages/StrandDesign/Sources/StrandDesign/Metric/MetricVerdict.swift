import Foundation

// MARK: - Verdict vocabulary (CONCEPT §1.1, closed sets)
//
// A verdict is never free text: each case maps to exactly one catalogue entry, so the same state
// reads the same on every screen and in every language.

public enum MetricVerdict: Equatable, Sendable {
    /// Vital vs. the user's typical range.
    case typical, above, below
    /// 0–100 score band.
    case score(ScoreBand)
    /// Training / day load.
    case load(LoadBand)
    /// No number can be shown; the reason replaces it (a dash is never a valid state).
    case unavailable(UnavailableReason)

    /// Places a vital against its typical range. The bounds belong to the range (inclusive).
    public static func vital(_ value: Double, typicalRange: ClosedRange<Double>) -> MetricVerdict {
        if value > typicalRange.upperBound { return .above }
        if value < typicalRange.lowerBound { return .below }
        return .typical
    }

    /// Bands a 0–100 score; see `ScoreBand.init(score:)`.
    public static func score(_ value: Double) -> MetricVerdict { .score(ScoreBand(score: value)) }

    public var text: LocalizedStringResource {
        switch self {
        case .typical: return MetricStrings.verdictTypical
        case .above: return MetricStrings.verdictAbove
        case .below: return MetricStrings.verdictBelow
        case .score(let band): return band.text
        case .load(let band): return band.text
        case .unavailable(let reason): return reason.text
        }
    }
}

/// WHOOP-compatible score bands: Low 0–33, Medium 34–66, High 67–100.
public enum ScoreBand: Equatable, Sendable, CaseIterable {
    case low, medium, high

    /// Bands the score as it is DISPLAYED (rounded to an integer): 66.6 shows as "67" and must read
    /// "High", or the number and its verdict word would disagree.
    public init(score: Double) {
        let shown = score.rounded()
        if shown >= 67 { self = .high } else if shown >= 34 { self = .medium } else { self = .low }
    }

    public var text: LocalizedStringResource {
        switch self {
        case .high: return MetricStrings.scoreHigh
        case .medium: return MetricStrings.scoreMedium
        case .low: return MetricStrings.scoreLow
        }
    }
}

/// Load vocabulary. The thresholds belong to the training-load engine, not to the design layer.
public enum LoadBand: Equatable, Sendable, CaseIterable {
    case restorative, building, demanding, overreaching

    public var text: LocalizedStringResource {
        switch self {
        case .restorative: return MetricStrings.loadRestorative
        case .building: return MetricStrings.loadBuilding
        case .demanding: return MetricStrings.loadDemanding
        case .overreaching: return MetricStrings.loadOverreaching
        }
    }
}

public enum UnavailableReason: Equatable, Sendable {
    /// Still collecting the nights a personal baseline needs.
    case calibrating(nightsLeft: Int)
    /// No data in the window; `since` is the last sample, nil if there never was one.
    case noData(since: Date?)

    public var text: LocalizedStringResource {
        switch self {
        case .calibrating(let nights): return MetricStrings.nightsLeft(max(nights, 1))
        case .noData(let since?): return MetricStrings.noDataSince(since)
        case .noData(nil): return MetricStrings.noDataYet
        }
    }
}
