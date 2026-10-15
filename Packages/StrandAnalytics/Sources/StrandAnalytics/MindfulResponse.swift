import Foundation
import WhoopProtocol

// MindfulResponse.swift - did a practice session calm the body, measured rather than assumed.
//
// Per session (the relaxation response): mean heart rate and RMSSD in the settle window (the second
// half of the session) against a reference just before it. The reference is the 10 minutes before the
// start; when those have too little signal (strap off, walking to the mat) the first 3 minutes of the
// session stand in, and the result says so. Too little data on either side gives nil, never a guess.
//
// Across sessions: means with their sample size, and whether recent sessions settle further than the
// earlier ones. A trend is only claimed with enough sessions on both sides.

public enum MindfulResponse {

    // MARK: - Tunables

    /// Sessions shorter than this are too brief for a settle window to mean anything.
    public static let minSessionSeconds = 5 * 60
    /// Reference window before the session.
    public static let preWindowSeconds = 10 * 60
    /// Fallback reference: the opening minutes of the session itself.
    public static let openingWindowSeconds = 3 * 60
    /// HR samples a window needs (2 minutes at the strap's 1 Hz).
    public static let minHRSamples = 120
    /// Clean beats a window needs before its RMSSD is used.
    public static let minBeats = 60

    // MARK: - One session

    public struct Session: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let hrBefore: Double
        public let hrSettled: Double
        public let rmssdBefore: Double?
        public let rmssdSettled: Double?
        /// True when the reference came from the session's opening minutes, not the time before it.
        public let referenceIsOpening: Bool

        public init(startTs: Int, endTs: Int, hrBefore: Double, hrSettled: Double,
                    rmssdBefore: Double?, rmssdSettled: Double?, referenceIsOpening: Bool) {
            self.startTs = startTs
            self.endTs = endTs
            self.hrBefore = hrBefore
            self.hrSettled = hrSettled
            self.rmssdBefore = rmssdBefore
            self.rmssdSettled = rmssdSettled
            self.referenceIsOpening = referenceIsOpening
        }

        /// Positive when the heart slowed (bpm).
        public var hrDrop: Double { hrBefore - hrSettled }

        /// Relative RMSSD change in percent; positive when HRV rose.
        public var rmssdChangePercent: Double? {
            guard let b = rmssdBefore, let s = rmssdSettled, b > 0 else { return nil }
            return (s - b) / b * 100
        }
    }

    /// The relaxation response of one session, or nil when the session is too short or either window
    /// lacks heart-rate data. `hr` and `rr` should cover `[start - preWindowSeconds, end]`.
    public static func evaluate(startTs: Int, endTs: Int, hr: [HRSample], rr: [RRInterval]) -> Session? {
        guard endTs - startTs >= minSessionSeconds else { return nil }
        let settleStart = startTs + (endTs - startTs) / 2
        guard let settledHR = meanHR(hr, from: settleStart, to: endTs) else { return nil }

        var openingRef = false
        var refFrom = startTs - preWindowSeconds, refTo = startTs
        var refHR = meanHR(hr, from: refFrom, to: refTo)
        if refHR == nil {
            openingRef = true
            refFrom = startTs
            refTo = startTs + openingWindowSeconds
            refHR = meanHR(hr, from: refFrom, to: refTo)
        }
        guard let before = refHR else { return nil }
        return Session(startTs: startTs, endTs: endTs, hrBefore: before, hrSettled: settledHR,
                       rmssdBefore: rmssd(rr, from: refFrom, to: refTo),
                       rmssdSettled: rmssd(rr, from: settleStart, to: endTs),
                       referenceIsOpening: openingRef)
    }

    static func meanHR(_ hr: [HRSample], from: Int, to: Int) -> Double? {
        let xs = hr.filter { $0.ts >= from && $0.ts < to && $0.bpm >= 30 && $0.bpm <= 220 }
        guard xs.count >= minHRSamples else { return nil }
        return Double(xs.reduce(0) { $0 + $1.bpm }) / Double(xs.count)
    }

    static func rmssd(_ rr: [RRInterval], from: Int, to: Int) -> Double? {
        let raw = rr.filter { $0.ts >= from && $0.ts < to }.map { Double($0.rrMs) }
        let clean = HRVAnalyzer.cleanRR(raw)
        guard clean.count >= minBeats else { return nil }
        return HRVAnalyzer.rmssdRaw(clean)
    }

    // MARK: - Across sessions

    public enum Trend: Equatable, Sendable {
        /// Fewer than `minSessionsForTrend` measured sessions.
        case notEnoughData
        /// Recent sessions settle the heart further than earlier ones by at least `trendMarginBPM`.
        case deeper
        case steady
        case shallower
    }

    public static let minSessionsForMean = 3
    public static let minSessionsForTrend = 6
    /// Smallest difference in mean HR drop (bpm) between early and recent sessions called a trend.
    public static let trendMarginBPM = 1.5

    public struct Progress: Equatable, Sendable {
        public let sessions: Int
        /// Mean HR drop (bpm), nil below `minSessionsForMean`.
        public let meanHRDrop: Double?
        /// Mean RMSSD change (%), over the sessions with R-R on both sides.
        public let meanRMSSDChange: Double?
        public let rmssdSessions: Int
        /// Share of measured sessions in which the heart slowed at all (0-1).
        public let settledShare: Double?
        public let trend: Trend
    }

    /// Aggregates measured sessions (any order) into the progress readout.
    public static func progress(_ sessions: [Session]) -> Progress {
        let ordered = sessions.sorted { $0.startTs < $1.startTs }
        let n = ordered.count
        let drops = ordered.map(\.hrDrop)
        let hrv = ordered.compactMap(\.rmssdChangePercent)
        let enough = n >= minSessionsForMean
        var trend = Trend.notEnoughData
        if n >= minSessionsForTrend {
            let half = n / 2
            let early = mean(Array(drops.prefix(half))) ?? 0
            let recent = mean(Array(drops.suffix(n - half))) ?? 0
            let d = recent - early
            trend = d >= trendMarginBPM ? .deeper : (d <= -trendMarginBPM ? .shallower : .steady)
        }
        return Progress(sessions: n,
                        meanHRDrop: enough ? mean(drops) : nil,
                        meanRMSSDChange: hrv.count >= minSessionsForMean ? mean(hrv) : nil,
                        rmssdSessions: hrv.count,
                        settledShare: enough ? Double(drops.filter { $0 > 0 }.count) / Double(n) : nil,
                        trend: trend)
    }

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}
