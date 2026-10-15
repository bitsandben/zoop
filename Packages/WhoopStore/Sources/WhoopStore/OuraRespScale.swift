import Foundation
import WhoopProtocol

/// The one place the Oura ring's respiration rows are scaled, displayed and kept out of scoring.
///
/// `respSample` was built for a WHOOP 4.0 raw respiration ADC waveform (1 Hz); the ring instead sends an
/// already-computed RATE, one value per ~296 s window. Two different quantities share one table, so the
/// row's owner tells them apart (`DeviceFamily` has no Oura case by design, so `skinTempCelsius`'s approach
/// cannot be reused). Readers go through `displayValue` to show a row and `forScoring` to (not) score it.
public enum OuraRespScale {
    /// The unit tag on a ring-sourced `RespSample`. `respSample` persists no unit column, so the durable
    /// discriminator is the deviceId, via `isRingRateStream`.
    public static let unitTag = "milli_bpm"

    /// MILLI-breaths-per-minute: the scale a ring respiration row is stored at. The wire field is a `u8` divided
    /// by 8, so every value is an exact multiple of 0.125 bpm and `x 1000` is lossless (`raw == wireByte * 125`).
    /// Centi would land on `x.5` for half the alphabet and need a rounding rule both platforms must agree on, and
    /// sub-bpm resolution matters here (the open question is a residual of about -0.30 bpm).
    public static let milliBpmPerBpm: Double = 1000.0

    /// Decoded breaths/min to the durable `RespSample.raw` integer. Exact for every wire value; rounding is only
    /// a floating-point safety net (both platforms round half-up on non-negative input).
    public static func milliBpm(fromBreathsPerMin bpm: Double) -> Int {
        Int((bpm * milliBpmPerBpm).rounded())
    }

    /// Durable `raw` to breaths/min.
    public static func breathsPerMin(raw: Int) -> Double {
        Double(raw) / milliBpmPerBpm
    }

    /// True when this device's `respSample` rows are the ring's per-window RATE (milli-bpm), not a WHOOP ADC waveform.
    public static func isRingRateStream(deviceId: String) -> Bool {
        DeviceBrandCatalog.isOura(deviceId)
    }

    /// The number to PLOT for one stored row: breaths/min for a ring, the raw ADC count verbatim for a WHOOP.
    public static func displayValue(raw: Int, deviceId: String) -> Double {
        isRingRateStream(deviceId: deviceId) ? breathsPerMin(raw: raw) : Double(raw)
    }

    /// The complement of `forScoring`: rows a device measured itself as a respiratory RATE (a ring's), which are
    /// a night's `dailyMetric.respRateBpm` candidate rather than a stager input. A WHOOP's raw waveform does not pass.
    public static func forVendorRate(_ rows: [RespSample], deviceId: String) -> [RespSample] {
        isRingRateStream(deviceId: deviceId) ? rows : []
    }

    /// The respiration rows the sleep stager may see: a ring's are removed.
    ///
    /// This is a shape refusal: `SleepStager` runs `respRateAndRRV`, a peak detector that assumes a ~1 Hz raw
    /// waveform, and its output steers the depth call, so a per-window rate would contribute noise in the shape of
    /// a signal. Today the ~296 s cadence leaves fewer than the required 8 samples per 5-minute window, so staging
    /// is identical either way (pinned by `OuraRespScoringExclusionTests`), but that is luck, so refuse by provenance.
    /// The same rows still reach the daily metric through `forVendorRate`.
    public static func forScoring(_ rows: [RespSample], deviceId: String) -> [RespSample] {
        isRingRateStream(deviceId: deviceId) ? [] : rows
    }
}
