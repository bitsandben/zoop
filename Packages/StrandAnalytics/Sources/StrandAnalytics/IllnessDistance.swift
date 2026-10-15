import Foundation

// Alternative multivariate illness-anomaly distance (Mahalanobis), behind a flag; the default
// IllnessSignalEngine scorer is unchanged.
//
// The four illness signals (RHR up, RMSSD down, skin-temp up, respiration up) are correlated, so summing
// per-signal z-scores double-counts shared variance. D^2 = x^T C^-1 x over z-scored features (C = the
// correlation matrix) counts two correlated signals moving together as one coordinated move; D is in
// SD-equivalent units, comparable to the per-signal z~2 gate.
//
// Gating: fires only when D > distanceThreshold AND at least minDeviatingFeatures features deviate
// illness-ward (a large D from a wellness-ward signal must not fire); the caller still applies confounder
// suppression. C^-1 is solved by Gauss-Jordan; a singular matrix falls back to the diagonal inverse (no NaNs).
// Pure, deterministic, DB-free, approximate, non-clinical.

public enum IllnessDistance {

    /// Mahalanobis D above which the path considers firing (before the deviating-feature gate and confounder suppression).
    public static let distanceThreshold: Double = 2.5

    /// Minimum features that must point illness-ward (positive z) before a large D can fire.
    public static let minDeviatingFeatures: Int = 2

    /// A feature deviates illness-ward once its illness-oriented z reaches this (matches IllnessSignalEngine.signalZThreshold).
    public static let featureZThreshold: Double = 2.0

    /// Tikhonov ridge added to the correlation diagonal so a near-singular short-baseline matrix still inverts.
    public static let ridge: Double = 1e-6

    /// The four illness signals in fixed order, each as an illness-oriented z (positive = more illness-like; RMSSD
    /// passes the negated z). nil = absent this window: dropped from the distance and never counted as deviating.
    public struct FeatureVector: Equatable, Sendable {
        public var restingHR: Double?
        public var rmssd: Double?       // already negated by the caller so positive == drop == illness-ward
        public var skinTemp: Double?
        public var respiration: Double?
        public init(restingHR: Double? = nil, rmssd: Double? = nil,
                    skinTemp: Double? = nil, respiration: Double? = nil) {
            self.restingHR = restingHR; self.rmssd = rmssd
            self.skinTemp = skinTemp; self.respiration = respiration
        }

        /// Present coordinates in fixed order (restingHR, rmssd, skinTemp, respiration).
        var present: [Double] {
            [restingHR, rmssd, skinTemp, respiration].compactMap { $0 }
        }
    }

    public struct Result: Equatable, Sendable {
        /// Mahalanobis distance D; 0 when no features are present.
        public let distance: Double
        /// Present features whose illness-ward z >= featureZThreshold.
        public let deviatingFeatures: Int
        /// True iff D > distanceThreshold and deviatingFeatures >= minDeviatingFeatures (before confounder suppression).
        public let fires: Bool
        /// True when the singular-matrix diagonal-inverse fallback was used.
        public let usedDiagonalFallback: Bool

        public init(distance: Double, deviatingFeatures: Int, fires: Bool, usedDiagonalFallback: Bool) {
            self.distance = distance; self.deviatingFeatures = deviatingFeatures
            self.fires = fires; self.usedDiagonalFallback = usedDiagonalFallback
        }
    }

    /// Mahalanobis distance of today's illness-oriented z-vector from the personal baseline.
    ///
    /// Features are already z-scored, so the mean is zero and the covariance is the personal correlation matrix.
    /// Pass the identity (or nil) for independent features, which makes D the Euclidean norm.
    ///
    /// - Parameters:
    ///   - features: today's illness-oriented z-vector (absent coordinates dropped).
    ///   - correlation: NxN correlation over the present features in fixed order, or nil for identity.
    public static func evaluate(features: FeatureVector,
                                correlation: [[Double]]? = nil) -> Result {
        let x = features.present
        let k = x.count
        guard k > 0 else {
            return Result(distance: 0, deviatingFeatures: 0, fires: false, usedDiagonalFallback: false)
        }

        var deviating = 0
        for v in x where v >= featureZThreshold { deviating += 1 }

        var corr: [[Double]]
        let suppliedCorrelation: Bool
        if let c = correlation, c.count == k, c.allSatisfy({ $0.count == k }) {
            corr = c; suppliedCorrelation = true
        } else {
            corr = identity(k); suppliedCorrelation = false
        }
        // Ridge only a supplied correlation: the identity must invert to itself so D equals the Euclidean norm exactly.
        if suppliedCorrelation { for i in 0..<k { corr[i][i] += ridge } }

        // On singularity fall back to the diagonal inverse (independent features).
        let (inv, fellBack) = invertOrDiagonal(corr)

        var d2 = 0.0
        for i in 0..<k {
            var rowDot = 0.0
            for j in 0..<k { rowDot += inv[i][j] * x[j] }
            d2 += x[i] * rowDot
        }
        if d2 < 0 { d2 = 0 }   // guard tiny negative from rounding on a near-singular inverse.
        let distance = d2.squareRoot()

        let fires = distance > distanceThreshold && deviating >= minDeviatingFeatures
        return Result(distance: distance, deviatingFeatures: deviating,
                      fires: fires, usedDiagonalFallback: fellBack)
    }

    // MARK: - Linear algebra

    static func identity(_ n: Int) -> [[Double]] {
        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { m[i][i] = 1 }
        return m
    }

    /// Inverts a square matrix by Gauss-Jordan with partial pivoting. A (near-)singular pivot returns the diagonal
    /// inverse with fellBack=true; zero/negative diagonal entries map to 1 so the result is always finite.
    static func invertOrDiagonal(_ a: [[Double]]) -> (inverse: [[Double]], fellBack: Bool) {
        let n = a.count
        var m = [[Double]](repeating: [Double](repeating: 0, count: 2 * n), count: n)
        for i in 0..<n {
            for j in 0..<n { m[i][j] = a[i][j] }
            m[i][n + i] = 1
        }
        let eps = 1e-12
        for col in 0..<n {
            var pivotRow = col
            var pivotMag = abs(m[col][col])
            for r in (col + 1)..<n where abs(m[r][col]) > pivotMag {
                pivotMag = abs(m[r][col]); pivotRow = r
            }
            if pivotMag < eps {
                return (diagonalInverse(a), true)   // singular: fall back.
            }
            if pivotRow != col { m.swapAt(col, pivotRow) }
            let pivot = m[col][col]
            for j in 0..<(2 * n) { m[col][j] /= pivot }
            for r in 0..<n where r != col {
                let factor = m[r][col]
                if factor == 0 { continue }
                for j in 0..<(2 * n) { m[r][j] -= factor * m[col][j] }
            }
        }
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in 0..<n { inv[i][j] = m[i][n + j] } }
        return (inv, false)
    }

    /// 1/diag on the diagonal, zeros elsewhere; a non-positive entry maps to 1 so the fallback is finite.
    static func diagonalInverse(_ a: [[Double]]) -> [[Double]] {
        let n = a.count
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            let d = a[i][i]
            inv[i][i] = d > 1e-12 ? 1.0 / d : 1.0
        }
        return inv
    }
}
