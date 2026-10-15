import Foundation
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

/// One row of the recent-sessions list, fully formatted here so the view only lays it out.
struct MindfulSessionRow: Identifiable {
    let id: Int
    let kind: MindfulPractice.Kind
    let title: String
    let detail: String
    let duration: String
    /// "−6 bpm" when the session's relaxation response was measured.
    let response: String?
}

// MARK: - Mindfulness model
//
// Loads every source of practice (mind-body workouts, the app's own breathing / meditation sessions,
// Apple Health mindful minutes), merges them, and measures what they did using the strap's heart rate,
// R-R and the hourly stress read. All maths lives in StrandAnalytics (`MindfulPractice`,
// `MindfulResponse`, `MindfulOutcomes`); this type only reads stores and builds readouts.

@MainActor
final class MindfulnessModel: ObservableObject {

    @Published private(set) var loaded = false
    @Published private(set) var hasPractice = false
    @Published private(set) var practice: [MindfulMetric] = []
    @Published private(set) var effect: [MindfulMetric] = []
    @Published private(set) var recent: [MindfulSessionRow] = []

    /// How far back sessions are read (the normal week needs 8 earlier weeks).
    static let historyDays = 70
    /// Window for the effect figures.
    static let effectDays = 60
    /// Sessions measured for the relaxation response (newest first).
    static let maxMeasured = 16
    /// Distinct days whose stress curve is read (each is a full day of heart data).
    static let maxStressDays = 6

    func refresh(repo: Repository, workouts: [WorkoutRow]) async {
        let now = Date()
        let cal = Calendar.current
        let since = now.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        let sinceTs = Int(since.timeIntervalSince1970)

        var all = MindfulSessionLog.sessions().filter { $0.endTs >= sinceTs }
        all += workouts.compactMap { row -> MindfulPractice.Session? in
            guard row.endTs >= sinceTs, let kind = MindfulPractice.kind(forSport: row.sport) else { return nil }
            return MindfulPractice.Session(startTs: row.startTs, endTs: row.endTs, kind: kind, source: .workout)
        }
        all += await MindfulHealthReader.sessions(since: since)
        let sessions = MindfulPractice.merge(all)
        hasPractice = !sessions.isEmpty
        guard hasPractice else { loaded = true; return }

        let effectStart = now.addingTimeInterval(-Double(Self.effectDays) * 86_400)
        let effectTs = Int(effectStart.timeIntervalSince1970)
        let window = DateInterval(start: effectStart, end: now)
        let recentFirst = sessions.filter { $0.startTs >= effectTs }.reversed()

        let measured = await measure(Array(recentFirst.prefix(Self.maxMeasured)), repo: repo)
        let shifts = await stressShifts(Array(recentFirst), repo: repo, calendar: cal)
        let (rhr, hrv) = contrasts(sessions, days: repo.days, now: now, calendar: cal)

        let inputs = MindfulnessReadouts.Inputs(
            summary: MindfulPractice.summary(sessions, now: now, calendar: cal),
            progress: MindfulResponse.progress(Array(measured.values)),
            stress: MindfulOutcomes.stressSummary(shifts), rhr: rhr, hrv: hrv, window: window)
        let built = MindfulnessReadouts.all(inputs)
        practice = built.practice
        effect = built.effect
        recent = sessions.suffix(5).reversed().map { row($0, response: measured[$0.startTs]) }
        loaded = true
    }

    // MARK: Relaxation response

    /// Measured sessions keyed by start time. Each session reads its own short window of HR and R-R.
    private func measure(_ sessions: [MindfulPractice.Session], repo: Repository) async -> [Int: MindfulResponse.Session] {
        var out: [Int: MindfulResponse.Session] = [:]
        for s in sessions where s.seconds >= MindfulResponse.minSessionSeconds {
            let from = s.startTs - MindfulResponse.preWindowSeconds
            let hr = await repo.hrSamples(from: from, to: s.endTs, limit: 20_000)
            guard hr.count >= MindfulResponse.minHRSamples else { continue }
            let rr = await repo.rrIntervals(from: from, to: s.endTs, limit: 40_000)
            if let r = MindfulResponse.evaluate(startTs: s.startTs, endTs: s.endTs, hr: hr, rr: rr) {
                out[s.startTs] = r
            }
        }
        return out
    }

    // MARK: Stress around sessions

    /// Scores each session day's hourly stress (day-relative, motion-gated like the Stress screen) and
    /// takes the hours either side of the sessions on it.
    private func stressShifts(_ sessions: [MindfulPractice.Session], repo: Repository,
                              calendar: Calendar) async -> [MindfulOutcomes.StressShift] {
        var byDay: [Date: [MindfulPractice.Session]] = [:]
        for s in sessions {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.startTs)))
            if byDay[day] != nil || byDay.count < Self.maxStressDays { byDay[day, default: []].append(s) }
        }
        var shifts: [MindfulOutcomes.StressShift] = []
        for (day, daySessions) in byDay {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let from = Int(day.timeIntervalSince1970), to = Int(end.timeIntervalSince1970)
            let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
            guard hr.count >= DaytimeStress.minHourHRSamples else { continue }
            let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
            let tz = TimeZone.current.secondsFromGMT(for: day)
            let result = await runUnescalated {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz)
            }
            for s in daySessions {
                if let shift = MindfulOutcomes.stressShift(hours: result.hours, startTs: s.startTs, endTs: s.endTs) {
                    shifts.append(shift)
                }
            }
        }
        return shifts
    }

    // MARK: Practice nights vs other nights

    private func contrasts(_ sessions: [MindfulPractice.Session], days: [DailyMetric], now: Date,
                           calendar: Calendar) -> (MindfulOutcomes.DayContrast, MindfulOutcomes.DayContrast) {
        let practiced = Set(sessions.map { MindfulPractice.dayKey($0.startTs, calendar) })
        let evaluated: [String] = (1...Self.effectDays).compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: now).map { MindfulPractice.dayKey($0, calendar) }
        }
        var rhr: [String: Double] = [:], hrv: [String: Double] = [:]
        for d in days {
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.avgHrv { hrv[d.day] = v }
        }
        return (MindfulOutcomes.nextNightContrast(days: evaluated, practiceDays: practiced, values: rhr),
                MindfulOutcomes.nextNightContrast(days: evaluated, practiceDays: practiced, values: hrv))
    }

    // MARK: Rows

    private func row(_ s: MindfulPractice.Session, response: MindfulResponse.Session?) -> MindfulSessionRow {
        let start = Date(timeIntervalSince1970: TimeInterval(s.startTs))
        let date = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        let duration = Duration.seconds(s.seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let drop = response.map { MetricUnit.beatsPerMinute.formatDelta(-$0.hrDrop, locale: .current) }
        return MindfulSessionRow(id: s.startTs, kind: s.kind, title: MindfulnessStrings.kind(s.kind),
                                 detail: date + " · " + MindfulnessStrings.source(s.source),
                                 duration: duration, response: drop)
    }
}
