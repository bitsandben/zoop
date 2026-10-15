import Foundation

// MARK: - SleepRestlessness
//
// How still a night was, read from the per-epoch motion the stager already banks beside the stages
// (`SleepStager.sessionEpochMotion`: summed |Δgravity| per 30 s epoch). Three numbers per night: minutes
// restless, number of movement bouts and the longest still stretch, plus a personal range from earlier
// nights so each reads "compared to you".
//
// Method. A strap's motion floor differs by family and sampling (WHOOP 4.0 banks sparse, clumped gravity;
// 5.0/MG denser), so an absolute count threshold would mean different things on different straps. An
// epoch is therefore "restless" when its motion clearly exceeds the night's own resting floor: at least
// `floorMultiplier` × the median of the night's non-zero epochs (most of a night is still, so the median
// is the noise floor). Restless epochs closer than `boutMergeEpochs` merge into one bout, so one turn-over
// with a short pause is one bout, not two.
//
// Limits, stated so the screen does not overclaim. An epoch with no gravity sample stores 0, which is
// indistinguishable from a perfectly still wrist; nights with little motion coverage (typical of WHOOP 4.0
// backfill, #345) are flagged `.low` and the screen says so. Wrist movement is not sleep quality: it does
// not see a restless mind on a still arm, and a bed partner can move the wrist.

public enum SleepRestlessness {

    public static let epochSeconds: Double = 30
    /// Under three hours of epochs a night is too short to say anything about its stillness.
    public static let minEpochs = 360
    /// Restless means at least this many times the night's resting motion floor.
    public static let floorMultiplier: Double = 4
    /// Restless epochs separated by at most this many still epochs (1 min) belong to one bout.
    public static let boutMergeEpochs = 2
    /// Below this share of epochs carrying any motion there is too little data to read the night at all.
    public static let minCoverage: Double = 0.25
    /// Below this share (or on a night the stager flagged sparse) the readout is shown with low confidence.
    public static let solidCoverage: Double = 0.6
    /// Earlier nights needed before a personal range is drawn.
    public static let minHistoryNights = 7

    public enum Confidence: Equatable, Sendable { case solid, low }

    public struct Night: Equatable, Sendable {
        public let restlessMinutes: Double
        public let bouts: Int
        public let longestStillMinutes: Double
        /// Epochs analysed (30 s each).
        public let epochs: Int
        /// Share of epochs with any motion sample, 0...1.
        public let coverage: Double
        public let confidence: Confidence

        public init(restlessMinutes: Double, bouts: Int, longestStillMinutes: Double, epochs: Int,
                    coverage: Double, confidence: Confidence) {
            self.restlessMinutes = restlessMinutes
            self.bouts = bouts
            self.longestStillMinutes = longestStillMinutes
            self.epochs = epochs
            self.coverage = coverage
            self.confidence = confidence
        }
    }

    /// Reads one night's stored motion. `sparse` is the stager's own motion-coverage flag for the night
    /// (`CachedSleepSession.stagingSparse`). Nil for a night too short or with too little motion data.
    public static func analyze(epochCounts: [Double], sparse: Bool = false) -> Night? {
        let counts = epochCounts.map { $0.isFinite ? max($0, 0) : 0 }
        guard counts.count >= minEpochs else { return nil }
        let nonZero = counts.filter { $0 > 0 }
        let coverage = Double(nonZero.count) / Double(counts.count)
        guard coverage >= minCoverage else { return nil }

        let threshold = floorMultiplier * median(nonZero)
        let restless = counts.map { $0 > threshold && $0 > 0 }

        var bouts = 0
        var stillRun = 0, longestStill = 0
        var lastRestless: Int?
        for (i, moving) in restless.enumerated() {
            if moving {
                // A pause of up to `boutMergeEpochs` still epochs continues the previous bout.
                let continues = lastRestless.map { i - $0 - 1 <= boutMergeEpochs } ?? false
                if !continues { bouts += 1 }
                lastRestless = i
                stillRun = 0
            } else {
                stillRun += 1
                longestStill = max(longestStill, stillRun)
            }
        }
        let restlessEpochs = restless.filter { $0 }.count
        let minutesPerEpoch = epochSeconds / 60
        return Night(restlessMinutes: Double(restlessEpochs) * minutesPerEpoch,
                     bouts: bouts,
                     longestStillMinutes: Double(longestStill) * minutesPerEpoch,
                     epochs: counts.count,
                     coverage: coverage,
                     confidence: (sparse || coverage < solidCoverage) ? .low : .solid)
    }

    // MARK: Personal range

    /// Mean ± one SD of earlier nights (floored at 0), the same shape every other personal range uses.
    /// Nil with fewer than `minHistoryNights` nights.
    public static func typicalRange(_ history: [Double]) -> ClosedRange<Double>? {
        let values = history.filter(\.isFinite)
        guard values.count >= minHistoryNights else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let sd = variance.squareRoot()
        return max(0, mean - sd)...max(0, mean + sd)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
