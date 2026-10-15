import Foundation

/// The hours of the local day in which a wearable's daytime-HR mode should stand down so the device can run its
/// own night suite, derived from the learned sleep schedule rather than a fixed clock.
///
/// An Oura ring emits daytime HR only while a client holds it in daytime-HR mode. Zoop's screen-off suspend
/// (#1526) releases the ring so its sleep suite can run, right at night, but screen-off is also true most of a
/// working day, which emptied the daytime HR bins and windowed rMSSD; keying the stand-down on the night band
/// instead of the screen fixes that.
///
/// Bedtime is `BatteryEstimator.bedtimeSec` and wake is midsleep + `BatteryEstimator.halfNightSec`, the same
/// arithmetic `BatteryEstimator.bedtimeAlert` uses so the two policies agree on the user's night. The band opens
/// `leadSeconds` before bedtime and closes `tailSeconds` after wake. Cold start yields nil and the caller falls
/// back to the screen rule (a guessed 23:00 band would be wrong for exactly the shift/late sleepers the learner
/// serves). Naps outside the band are not stood down for. Pure and clock-free.
public enum NightStandDown {

    /// A circular local-time band `[startSec, endSec)` in seconds-of-day; `endSec` < `startSec` when it crosses midnight.
    public struct Band: Equatable, Sendable {
        public let startSec: Int
        public let endSec: Int
        public init(startSec: Int, endSec: Int) { self.startSec = startSec; self.endSec = endSec }
    }

    /// How long before the learned bedtime the stand-down opens (the screen-off grace still applies inside the band).
    public static let leadSeconds = 3_600
    /// How long after the learned wake the stand-down stays closed, covering a lie-in; afterwards the ring is held again so the morning is charted.
    public static let tailSeconds = 3_600

    static let secondsPerDay = 86_400

    /// The night band for a learned schedule, or nil at cold start.
    public static func band(habitualMidsleepSec: Int?, typicalSleepHours: Double?,
                            leadSeconds: Int = leadSeconds, tailSeconds: Int = tailSeconds) -> Band? {
        guard let midsleep = habitualMidsleepSec, let hours = typicalSleepHours, hours > 0,
              (0..<secondsPerDay).contains(midsleep) else { return nil }
        let half = BatteryEstimator.halfNightSec(sleepHours: hours)
        // A padded night covering the whole day leaves no "day"; treat as unlearned rather than never hold the ring.
        guard 2 * half + leadSeconds + tailSeconds < secondsPerDay else { return nil }
        let bedtime = BatteryEstimator.bedtimeSec(midsleepSec: midsleep, sleepHours: hours)
        return Band(startSec: floorMod(bedtime - leadSeconds, secondsPerDay),
                    endSec: floorMod(midsleep + half + tailSeconds, secondsPerDay))
    }

    /// Whether a local second-of-day falls inside the band, circularly.
    public static func contains(_ band: Band, secOfDay: Int) -> Bool {
        let s = floorMod(secOfDay, secondsPerDay)
        if band.startSec <= band.endSec {
            return s >= band.startSec && s < band.endSec
        }
        return s >= band.startSec || s < band.endSec
    }

    /// `HH:MM-HH:MM` for a log line.
    public static func describe(_ band: Band) -> String {
        "\(describeSecOfDay(band.startSec))–\(describeSecOfDay(band.endSec))"
    }

    /// `HH:MM` for a local second-of-day (wrapped), for a log line.
    public static func describeSecOfDay(_ secOfDay: Int) -> String {
        let s = floorMod(secOfDay, secondsPerDay)
        return String(format: "%02d:%02d", s / 3_600, (s % 3_600) / 60)
    }

    static func floorMod(_ a: Int, _ n: Int) -> Int {
        let r = a % n
        return r < 0 ? r + n : r
    }
}
