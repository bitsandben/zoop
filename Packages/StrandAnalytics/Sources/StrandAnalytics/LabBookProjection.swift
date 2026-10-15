import Foundation

// MARK: - Lab Book projection (pure)
//
// Pure, DB-free, deterministic logic turning Lab Book readings into daily `(day, key, value)` series, plus the
// windowed-aggregate pairing used before `CorrelationEngine.pearson`. No new statistics: a marker is just
// another `(day, value)` series.
//
// Bloods are months apart, so naive day-alignment leaves too few overlapping points; a reading on day D is
// paired with the mean of a wearable series over a trailing window up to and including D (default 14 days).
// Callers gate any conclusion on a reading-count floor (default 4); this engine reports the pairs and n.
// Timezone-free: it works on pre-derived `yyyy-MM-dd` strings, like `CorrelationEngine`.
// Non-clinical: never judges a value normal/abnormal and ships no thresholds.

/// One numeric reading on a pre-derived day. `takenAt` only breaks ties between same-day readings of a marker.
/// Non-numeric readings are not represented (the caller omits them).
public struct LabReading: Equatable, Sendable {
    /// Marker identifier (e.g. `"ldl"`, `"bp_systolic"`).
    public let markerKey: String
    /// Pre-derived `yyyy-MM-dd` day key.
    public let day: String
    public let value: Double
    /// Reading instant (epoch seconds); only orders same-day readings, never re-derives the day.
    public let takenAtEpoch: Double

    public init(markerKey: String, day: String, value: Double, takenAtEpoch: Double) {
        self.markerKey = markerKey
        self.day = day
        self.value = value
        self.takenAtEpoch = takenAtEpoch
    }
}

/// The value representing marker `key` on `day` after folding same-day readings (upserted into `metricSeries`).
public struct ProjectedPoint: Equatable, Sendable {
    public let markerKey: String
    public let day: String
    public let value: Double

    public init(markerKey: String, day: String, value: Double) {
        self.markerKey = markerKey
        self.day = day
        self.value = value
    }
}

/// How to collapse same-day readings of a marker into one daily value.
public enum DailyFold: Sendable {
    /// Latest `takenAt` wins (ties by input order).
    case latest
    /// Arithmetic mean of the day's readings.
    case mean
}

/// A marker reading on `day` paired with the wearable mean over the trailing window ending that day.
public struct WindowedPair: Equatable, Sendable {
    /// The marker reading's day (`yyyy-MM-dd`).
    public let day: String
    /// The marker's daily value (x of the pair).
    public let markerValue: Double
    /// Trailing-window wearable mean (y of the pair).
    public let wearableMean: Double
    /// Wearable points inside the window; always >= 1 for an emitted pair.
    public let wearableN: Int

    public init(day: String, markerValue: Double, wearableMean: Double, wearableN: Int) {
        self.day = day
        self.markerValue = markerValue
        self.wearableMean = wearableMean
        self.wearableN = wearableN
    }
}

public enum LabBookProjection {

    /// Device id every projected marker day is written under, so the per-source resolver treats markers as single-source.
    public static let sourceId = "lab-book"

    /// Blood pressure is stored as two keys (systolic / diastolic) for clean correlation, not one composite.
    public static let bpSystolicKey = "bp_systolic"
    public static let bpDiastolicKey = "bp_diastolic"

    /// Default trailing window (days, inclusive of the reading day) for pairing a sparse marker with a wearable series.
    public static let defaultWindowDays = 14

    // MARK: - Daily projection

    /// Folds readings into one point per (markerKey, day) using `fold`. Sorted by markerKey then day.
    public static func project(_ readings: [LabReading], fold: DailyFold = .latest) -> [ProjectedPoint] {
        var cells: [String: [LabReading]] = [:]
        var order: [String] = []
        for r in readings {
            let cellKey = r.markerKey + "\u{1}" + r.day
            if cells[cellKey] == nil { order.append(cellKey) }
            cells[cellKey, default: []].append(r)
        }

        var out: [ProjectedPoint] = []
        out.reserveCapacity(order.count)
        for cellKey in order {
            guard let group = cells[cellKey], !group.isEmpty else { continue }
            let value: Double
            switch fold {
            case .latest:
                // Latest takenAt wins; ties keep input order (store dedupes by natural key).
                var best = group[0]
                for r in group.dropFirst() where r.takenAtEpoch >= best.takenAtEpoch {
                    best = r
                }
                value = best.value
            case .mean:
                var sum = 0.0
                for r in group { sum += r.value }
                value = sum / Double(group.count)
            }
            out.append(ProjectedPoint(markerKey: group[0].markerKey, day: group[0].day, value: value))
        }

        out.sort { $0.markerKey != $1.markerKey ? $0.markerKey < $1.markerKey : $0.day < $1.day }
        return out
    }

    // MARK: - Windowed-aggregate pairing

    /// Pairs each marker day D with the mean of wearable values in `D-(windowDays-1) ... D`. Days with no wearable
    /// coverage are dropped; the window is clamped to >= 1; result sorted by day. Day arithmetic reuses the UTC
    /// `shiftDay` of `CorrelationEngine.lagged`.
    public static func pairMarkerToWearable(
        marker: [(day: String, value: Double)],
        wearable: [(day: String, value: Double)],
        windowDays: Int = defaultWindowDays
    ) -> [WindowedPair] {
        let width = max(1, windowDays)

        // Last-write-wins per day for both series (matches CorrelationEngine.alignByDay).
        var markerByDay: [String: Double] = [:]
        for row in marker { markerByDay[row.day] = row.value }
        var wearableByDay: [String: Double] = [:]
        for row in wearable { wearableByDay[row.day] = row.value }

        var pairs: [WindowedPair] = []
        for day in markerByDay.keys.sorted() {
            guard let mv = markerByDay[day] else { continue }
            var sum = 0.0
            var n = 0
            for back in 0..<width {
                guard let wDay = CorrelationEngine.shiftDay(day, by: -back) else { continue }
                if let wv = wearableByDay[wDay] {
                    sum += wv
                    n += 1
                }
            }
            guard n > 0 else { continue } // no coverage → drop the reading
            pairs.append(WindowedPair(day: day, markerValue: mv, wearableMean: sum / Double(n), wearableN: n))
        }
        return pairs
    }

    /// Reduces pairs to the `(x, y)` tuples `CorrelationEngine.pearson` consumes, ordered by day.
    public static func correlationInput(_ pairs: [WindowedPair]) -> [(Double, Double)] {
        pairs.map { ($0.markerValue, $0.wearableMean) }
    }
}
