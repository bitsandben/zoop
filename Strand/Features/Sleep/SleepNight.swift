import Foundation
import StrandDesign
import WhoopStore

// MARK: - Night value types

/// Stage minutes for one night.
struct Stages: Equatable {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// Time in bed, awake included.
    var total: Double { awake + light + deep + rem }
    var asleep: Double { light + deep + rem }

    static let zero = Stages(awake: 0, light: 0, deep: 0, rem: 0)

    func minutes(_ stage: SleepStage) -> Double {
        switch stage {
        case .awake: return awake
        case .light: return light
        case .deep: return deep
        case .rem: return rem
        }
    }
}

/// One displayed night: the day's main-night group merged into a single synthetic session. Edits must
/// target a real stored row, so the blocks it was built from travel with it.
struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The real per-segment timeline of an on-device night; nil for imported nights (totals only).
    var realSegments: [SleepInterval]? = nil
    var sourceBlocks: [CachedSleepSession] = []
    /// Per-epoch motion of the main-night group in timeline order; empty when none was stored.
    var motionEpochs: [Double] = []
    /// The learned habitual midsleep the screen loaded, so `editTarget` resolves the same block the
    /// analytics rollup did.
    var habitualMidsleepSec: Int? = nil

    /// The stored block a sleep-time edit writes against; nil for a synthetic stub.
    var editTarget: CachedSleepSession? {
        SleepScreen.mainNightSession(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// Start keys of the bridged main-night group; every other block of the day is a nap.
    var mainGroupStarts: Set<Int> {
        Set(SleepScreen.mainNightGroup(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec).map(\.startTs))
    }

    /// The day's naps, oldest first.
    var naps: [CachedSleepSession] {
        let group = mainGroupStarts
        return sourceBlocks.filter { !group.contains($0.startTs) }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    var timeInBed: Double { stages.total }
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)) }
    var wakeDate: Date { Date(timeIntervalSince1970: TimeInterval(session.endTs)) }
    var hasRealTimeline: Bool { (realSegments?.count ?? 0) >= 2 }

    /// The yyyy-MM-dd day the night is filed under: sleep belongs to the day you woke.
    var wakeDayKey: String { Repository.localDayKey(wakeDate) }

    /// Stage intervals in seconds from onset. Imported nights carry totals only, so they are laid out
    /// as a plausible architecture (deep early, REM later) purely for drawing.
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            out.append(SleepInterval(stage: stage, start: t, end: t + minutes * 60))
            t += minutes * 60
        }
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.clockString(session.effectiveStartTs) }
    var wakeText: String { Night.clockString(session.endTs) }

    /// "Mon 13 → Tue 14 Oct" across midnight; a night that began after midnight is named by the
    /// evening it belongs to (wake day minus one), so consecutive nights never share a label.
    var spanLabel: String {
        let cal = Calendar.current
        if cal.isDate(onsetDate, inSameDayAs: wakeDate) {
            let nightDay = cal.date(byAdding: .day, value: -1, to: wakeDate) ?? wakeDate
            return Night.dateFmt.string(from: nightDay)
        }
        return "\(Night.spanFmt.string(from: onsetDate)) → \(Night.dateFmt.string(from: wakeDate))"
    }

    /// A unix second as a clock string honouring the app's clock-format setting.
    static func clockString(_ ts: Int) -> String {
        AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span; the wake side carries the month.
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}
