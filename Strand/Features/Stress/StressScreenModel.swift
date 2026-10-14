import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - StressScreenModel
//
// Loads what the Stress screen shows and resolves it through `DaytimeStress`, the one stress resolver:
// `daily` for the morning level and the trend, `analyze` for today's curve, `headline` for the number.
// The view holds no logic and reads the published values.

@MainActor
final class StressScreenModel: ObservableObject {

    /// The morning's level and the daily trend. Nil when no day carries a signal.
    @Published private(set) var daily: DaytimeStress.Daily?
    /// Today's hourly read. Nil only while the first read is running; `.empty` when there is no usable HR.
    @Published private(set) var day: DaytimeStress.Result?
    @Published private(set) var loaded = false
    @Published private(set) var sleeps: [(start: Int, end: Int)] = []
    @Published private(set) var hrSamples = 0
    @Published private(set) var usesPersonalBaseline = false
    /// Test Centre only: alternate stress definitions that never reach a user screen.
    @Published private(set) var stressIndex: StressIndex.Components?
    @Published private(set) var freqHRV: HRVFreqDomain.Bands?
    /// True while a finished breathing session is waiting for its "Were you stressed?" answer.
    @Published private(set) var asking = false

    private weak var repo: Repository?
    private var stored: [(day: String, value: Double)] = []
    private let labels = StressLabelLog()

    func attach(repo: Repository) { self.repo = repo }

    // MARK: Derived

    /// The same call the Home tile makes, so the two cannot show different numbers.
    var headline: Assessment<Double, DaytimeStress.HeadlineSource> {
        DaytimeStress.headline(hours: day?.timeline ?? [], daily: daily)
    }

    var typical: StressReadouts.Typical { StressReadouts.typical(daily: daily) }

    /// Scored points of today's curve, the ones drawn.
    var points: [DaytimeStress.HourPoint] { (day?.timeline ?? []).filter { $0.level != nil } }

    var summary: StressReadouts.DaySummary? { StressReadouts.summary(day) }

    /// The method sentence tells the truth about whether HRV counted: the personal baseline scores HR only.
    var hrOnly: Bool {
        day?.hrOnlyFallback == true || (usesPersonalBaseline && !DaytimeStress.daytimeRMSSDScoringEnabled)
    }

    /// The headline, or the point under the finger while the curve is scrubbed.
    func readout(scrubbed: DaytimeStress.HourPoint?, now: Date = Date()) -> MetricReadout {
        let label: LocalizedStringResource
        let level: Double?
        if let scrubbed {
            label = StressStrings.at(Self.time(Date(timeIntervalSince1970: TimeInterval(scrubbed.startTs))))
            level = scrubbed.level
        } else {
            let head = headline
            level = head.value
            switch head.reason {
            case .currentHour:
                // A point covers the hour that starts at `startTs`; the reading is as new as the data.
                let end = points.last.map { min(now, Date(timeIntervalSince1970: TimeInterval($0.startTs + 3600))) } ?? now
                label = StressStrings.now(Self.time(end))
            case .dailyLevel: label = StressStrings.thisMorning
            case .none: label = StressStrings.label
            }
        }
        return StressReadouts.readout(level: level, label: label, confidence: headline.confidence, typical: typical)
    }

    func explanation(now: Date = Date()) -> MetricExplanation {
        StressReadouts.explanation(daily: daily, typical: typical, hrSamples: hrSamples, hrOnly: hrOnly, now: now)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    // MARK: Loading

    func reload() async {
        guard let repo else { return }
        stored = await repo.series(key: "stress", source: "my-whoop")
        loaded = true
        rebuildDaily()
        await refreshDay()
    }

    /// Cheap enough to call when `repo.days` changes: one pass over the stored days.
    func rebuildDaily() {
        guard let repo else { return }
        daily = DaytimeStress.daily(days: repo.days, stored: stored)
    }

    /// Reads today's banked HR and R-R and scores the hours. Local-day window [midnight, now].
    func refreshDay() async {
        guard let repo else { return }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())
        sleeps = repo.sleeps
            .filter { cal.isDateInToday(Date(timeIntervalSince1970: TimeInterval($0.endTs))) }
            .map { ($0.effectiveStartTs, $0.endTs) }

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        hrSamples = hr.count
        // Too few samples: empty the curve and the Test Centre readouts together, so neither shows stale
        // values beside the other.
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            day = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        // The wrist accelerometer masks exertion: a workout hour is not stress, so it is left unscored.
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
        let mode = await DaytimeStressMode.selected(
            repo: repo, startOfToday: startOfDay, calendar: cal,
            personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)
        if case .baselineRelative = mode { usesPersonalBaseline = true } else { usesPersonalBaseline = false }
        // The sliding timeline moves the line in half-hours instead of stepping by whole hours (#2144).
        // `runUnescalated` keeps this pure computation from racing the UI for cores (#2181).
        day = await runUnescalated(priority: .userInitiated) {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz, mode: mode,
                                  includeTimeline: true)
        }

        // Baevsky SI and LF/HF are alternate definitions of stress; they stay Test Centre instrumentation.
        guard TestCentre.active(.stress) else {
            stressIndex = nil
            freqHRV = nil
            return
        }
        let advanced = await runUnescalated { (index: StressIndex.components(rr: rr), freq: HRVFreqDomain.freqDomain(rr: rr)) }
        stressIndex = advanced.index
        freqHRV = advanced.freq
    }

    // MARK: "Were you stressed?"

    func refreshAsking() { asking = labels.isAsking() }

    func answer(stressed: Bool) {
        labels.record(stressed: stressed, level: headline.value)
        asking = false
    }
}
