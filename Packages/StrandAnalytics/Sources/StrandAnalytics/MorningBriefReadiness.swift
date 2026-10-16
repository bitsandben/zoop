import Foundation

// MorningBriefReadiness: whether the morning brief (coach brief or the plain good-morning push) may speak
// about last night yet, and whether an already written brief has to be rewritten.
//
// The sync flags (offload running, strap reports newer records, scoring running) cannot answer this on
// their own. They all read false between two offloads in the middle of the night: a background sync at
// 02:30 offloads the night so far, scores it, and the night "ends" at the last offloaded record, which is
// today and before now. The brief used to go out on that partial night ("you slept 2 h 27 min") and was
// never corrected. The test here is on the data itself: a night counts as over only when offloaded strap
// history reaches clearly past its end, because a night cut off by the end of the data ends where the
// data ends.
//
// The history frontier is the newest record the HISTORY offload stored, not the newest sample in the
// store. The live heart-rate stream (the Live screen, or the smart alarm holding it open around the wake
// window) stores samples stamped with the phone's clock as they arrive, so the store-wide newest sample
// reads "now" while hours of the night are still on the strap.

public enum MorningBriefReadiness {

    /// Offloaded history has to reach this far past the night's end before the night counts as over.
    /// A night cut off by the end of the data ends within a few minutes of that end (tested on synthetic
    /// nights in `MorningBriefReadinessTests`).
    public static let wakeMarginSec = 15 * 60
    /// Before this local hour a night is never treated as over: a short mid-night wake followed by a sync
    /// looks exactly like a morning wake to the data test. Same 04:00 rollover the day keys use.
    public static let earliestLocalHour = 4
    /// A brief already written is rewritten when the night it described changed by at least this much.
    public static let rewriteSleepDeltaMin = 10.0
    public static let rewriteNightEndDeltaSec = 10 * 60

    public enum Verdict: String, Equatable, Sendable {
        /// The night is over and offloaded: the brief may use it.
        case ready
        /// An offload, pending history or scoring is still in flight.
        case syncInFlight
        /// No night that ended today, before now.
        case noNight
        /// Too early in the local morning to call the night over.
        case tooEarly
        /// Offloaded history does not reach clearly past the night's end: the night may still be running,
        /// or the rest of it is still on the strap.
        case nightOpen
    }

    public struct Input: Equatable, Sendable {
        public var nowTs: Int
        /// End of the latest stored sleep session.
        public var nightEndTs: Int?
        /// Newest record offloaded from strap history (see `dataFrontier`).
        public var dataFrontierTs: Int?
        public var syncBusy: Bool
        /// Local hour of `nowTs`.
        public var localHour: Int
        /// Whether `nightEndTs` falls on the same local day as `nowTs`.
        public var nightEndIsToday: Bool

        public init(nowTs: Int, nightEndTs: Int?, dataFrontierTs: Int?, syncBusy: Bool, localHour: Int,
                    nightEndIsToday: Bool) {
            self.nowTs = nowTs
            self.nightEndTs = nightEndTs
            self.dataFrontierTs = dataFrontierTs
            self.syncBusy = syncBusy
            self.localHour = localHour
            self.nightEndIsToday = nightEndIsToday
        }
    }

    public static func evaluate(_ i: Input) -> Verdict {
        if i.syncBusy { return .syncInFlight }
        guard let end = i.nightEndTs, i.nightEndIsToday, end <= i.nowTs else { return .noNight }
        if i.localHour < earliestLocalHour { return .tooEarly }
        // No frontier at all: a source with no strap offload (imported or Apple Health nights). There is
        // nothing to compare with, so the night stands as stored, as before.
        guard let frontier = i.dataFrontierTs else { return .ready }
        return frontier >= end + wakeMarginSec ? .ready : .nightOpen
    }

    /// The frontier the readiness test uses: the history offload's own newest record when known. The
    /// store-wide newest sample is only the fallback for a device with no recorded history frontier yet,
    /// because live samples advance it while the night is still on the strap.
    public static func dataFrontier(historyFrontierTs: Int?, storeLatestTs: Int?) -> Int? {
        historyFrontierTs ?? storeLatestTs
    }

    /// What a written brief was built from, kept so a later, fuller night rewrites it.
    public struct Basis: Codable, Equatable, Sendable {
        public var day: String
        public var sleepMin: Double?
        public var nightEndTs: Int?
        public var recovery: Double?
        public var writtenAt: Int

        public init(day: String, sleepMin: Double?, nightEndTs: Int?, recovery: Double?, writtenAt: Int) {
            self.day = day
            self.sleepMin = sleepMin
            self.nightEndTs = nightEndTs
            self.recovery = recovery
            self.writtenAt = writtenAt
        }
    }

    /// Whether today's brief has to be (re)written: none yet for `day`, or the night it quoted moved.
    public static func needsWrite(previous: Basis?, day: String, sleepMin: Double?, nightEndTs: Int?) -> Bool {
        guard let p = previous, p.day == day else { return true }
        switch (p.sleepMin, sleepMin) {
        case let (a?, b?) where abs(a - b) >= rewriteSleepDeltaMin: return true
        case (nil, _?): return true
        default: break
        }
        if let a = p.nightEndTs, let b = nightEndTs, abs(a - b) >= rewriteNightEndDeltaSec { return true }
        if p.nightEndTs == nil, nightEndTs != nil { return true }
        return false
    }
}
