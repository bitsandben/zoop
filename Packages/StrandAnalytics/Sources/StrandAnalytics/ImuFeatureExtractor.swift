import Foundation
import WhoopProtocol

// Activity features from decoded WHOOP 5/MG raw 6-axis IMU (#423): 100 Hz accel (g) + gyro (deg/s) resolve
// gait cadence, jerk and rotational energy that the 1 Hz gravity vector cannot (a 1.8 Hz step rate is above
// its Nyquist limit). Feeds coarse sport/HAR classification behind `WorkoutTypeClassifying`.
//
// Cadence is an autocorrelation peak on the accel-magnitude AC over a genuinely high-rate stream, reported
// with its own strength so callers can ignore weak peaks; it is a feature, never fed to a physiological
// gate. Validated to recover multiple injected cadences (ImuFeatureExtractorTests).

/// Compact activity features over a window of raw IMU samples.
public struct ImuActivityFeatures: Equatable, Sendable, Codable {
    /// RMS of the accel-magnitude AC (gravity removed), g: movement intensity.
    public let accelEnergyG: Double
    /// Mean gyroscope magnitude, deg/s: rotational intensity.
    public let gyroEnergyDps: Double
    /// RMS of the accel first difference, g/sample: impact / explosiveness.
    public let jerkRms: Double
    /// Dominant gait-band cadence (Hz; x60 for steps/min); nil when no peak clears `minCadenceStrength`.
    public let cadenceHz: Double?
    /// Normalized cadence-peak strength (0...1): high = rhythmic, low = bursty or still.
    public let cadenceStrength: Double
    public let sampleCount: Int

    public init(accelEnergyG: Double, gyroEnergyDps: Double, jerkRms: Double,
                cadenceHz: Double?, cadenceStrength: Double, sampleCount: Int) {
        self.accelEnergyG = accelEnergyG; self.gyroEnergyDps = gyroEnergyDps; self.jerkRms = jerkRms
        self.cadenceHz = cadenceHz; self.cadenceStrength = cadenceStrength; self.sampleCount = sampleCount
    }
}

public enum ImuFeatureExtractor {

    /// Cadence search band, Hz (~72-210 steps/min), below the IMU Nyquist.
    public static let cadenceBand: ClosedRange<Double> = 1.2...3.5
    /// Peaks below this normalized autocorrelation strength count as "no rhythm" (nil Hz).
    public static let minCadenceStrength = 0.20

    /// Extracts features from `samples` (in frame order) at `sampleRateHz`.
    public static func extract(_ samples: [RawImuSample], sampleRateHz: Int) -> ImuActivityFeatures {
        let n = samples.count
        guard n >= 8, sampleRateHz > 0 else {
            return ImuActivityFeatures(accelEnergyG: 0, gyroEnergyDps: 0, jerkRms: 0,
                                       cadenceHz: nil, cadenceStrength: 0, sampleCount: n)
        }
        let amag = samples.map { ($0.ax * $0.ax + $0.ay * $0.ay + $0.az * $0.az).squareRoot() }
        let gmag = samples.map { ($0.gx * $0.gx + $0.gy * $0.gy + $0.gz * $0.gz).squareRoot() }

        let gyroEnergy = gmag.reduce(0, +) / Double(n)
        // Remove DC (~gravity), then RMS.
        let mean = amag.reduce(0, +) / Double(n)
        let ac = amag.map { $0 - mean }
        let accelEnergy = (ac.reduce(0) { $0 + $1 * $1 } / Double(n)).squareRoot()
        var jerkSq = 0.0
        for i in 1..<n { let d = amag[i] - amag[i - 1]; jerkSq += d * d }
        let jerk = (jerkSq / Double(n - 1)).squareRoot()

        // Normalized autocorrelation over gait-band lags; strength = peak ACF / zero-lag ACF, so it is amplitude-scale free.
        let ac0 = ac.reduce(0) { $0 + $1 * $1 }
        var bestFreq: Double? = nil, bestStrength = 0.0
        if ac0 > 0 {
            let loLag = max(1, Int((Double(sampleRateHz) / cadenceBand.upperBound).rounded()))
            let hiLag = min(n - 1, Int((Double(sampleRateHz) / cadenceBand.lowerBound).rounded()))
            if loLag < hiLag {
                for lag in loLag...hiLag {
                    var s = 0.0
                    for i in 0..<(n - lag) { s += ac[i] * ac[i + lag] }
                    let strength = s / ac0
                    if strength > bestStrength { bestStrength = strength; bestFreq = Double(sampleRateHz) / Double(lag) }
                }
            }
        }
        let cadence = bestStrength >= minCadenceStrength ? bestFreq : nil
        return ImuActivityFeatures(accelEnergyG: accelEnergy, gyroEnergyDps: gyroEnergy, jerkRms: jerk,
                                   cadenceHz: cadence, cadenceStrength: max(0, bestStrength), sampleCount: n)
    }

    /// Extracts over the concatenated samples of decoded IMU frames.
    public static func extract(frames: [Whoop5ImuFrame]) -> ImuActivityFeatures {
        let rate = frames.first?.sampleRateHz ?? 100
        return extract(frames.flatMap { $0.samples }, sampleRateHz: rate)
    }
}
