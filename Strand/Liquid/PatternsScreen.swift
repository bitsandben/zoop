#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// MARK: - Patterns
//
// What the stored history says, one card per question: tonight's sleep need and bedtime, tomorrow's
// recovery, training load, what moves recovery, illness watch, heart-rate recovery after workouts, how
// fast the heart rate settles at night, the best bedtime, weekday patterns, recovery across the cycle,
// evening stress against deep sleep, and the week in numbers. Every card hides itself when there is not
// enough data to say something honest, and each one says what it is based on.

@MainActor
final class PatternsModel: ObservableObject {
    struct Tonight: Equatable {
        let need: PatternInsights.SleepNeed; let bedtime: Int?; let wake: Int?
        /// The armed strap alarm the wake time came from, when there is one.
        var alarm: Date? = nil
        /// Minutes in bed for the chosen goal, and the goal itself (share of the need).
        var inBedMin: Double = 0
        var goal: Double = 1
        /// Bedtime for the full need, for the planner's "optimal" line.
        var fullNeedBedtime: Int? = nil
    }
    struct Effect: Identifiable, Equatable { let id: String; let behavior: String; let delta: Double; let n: Int }
    struct HRRStats: Equatable { let latestDrop: Int; let averageDrop: Double; let workouts: Int }
    struct WindDownStats: Equatable { let minutes: Double; let drop: Double; let nights: Int }
    struct PhaseStat: Identifiable, Equatable {
        let phase: CycleCalendar.Phase; let recovery: Double?; let hrv: Double?; let days: Int
        var id: String { phase.rawValue }
    }

    @Published var tonight: Tonight?
    @Published var forecast: RecoveryForecast?
    @Published var acwr: Double?
    @Published var effects: [Effect] = []
    @Published var hrr: HRRStats?
    @Published var windDown: WindDownStats?
    @Published var bedtime: PatternInsights.BedtimeWindow?
    @Published var weekday: PatternInsights.WeekdayPattern?
    @Published var cycle: [PhaseStat] = []
    @Published var stressSleep: PatternInsights.SplitEffect?
    @Published var digest: WeeklyDigest?
    @Published var loaded = false

    private static let day = 86_400

    /// The quick, in-memory readings (used by Home as well as this screen).
    func loadQuick(repo: Repository, alarm: Date? = nil) async {
        let days = repo.days
        guard !days.isEmpty else { return }
        let today = days.last
        let need = SleepModel.debtNeedMin(days: days)
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        let strain21 = today?.strain.map { $0 * 0.21 }
        let sleepNeed = PatternInsights.sleepNeedTonight(baseNeedMin: need, strain: strain21,
                                                         debtMin: ledger.isDebt ? ledger.magnitudeMin : 0)
        // Time in bed for the chosen goal, from the recent share of time in bed spent asleep.
        let effs = days.suffix(14).compactMap(\.efficiency)
        let eff = effs.isEmpty ? nil : effs.reduce(0, +) / Double(effs.count)
        let goal = SleepGoal.current.fraction
        let inBed = PatternInsights.inBedMinutes(needMin: sleepNeed.totalMin, goal: goal, efficiency: eff)
        let fullInBed = PatternInsights.inBedMinutes(needMin: sleepNeed.totalMin, goal: 1, efficiency: eff)
        // The reminder counts back the same time in bed, so it is handed over every time it is computed.
        WindDownNudge.updateTonightNeed(Int(inBed.rounded()))
        // One wake time for the card and the reminder: an armed strap alarm within the next day first,
        // then the wake time set for the reminder, then the habitual one from past nights.
        var bed: Int?, wake: Int?
        let usableAlarm = alarm.flatMap { $0.timeIntervalSinceNow < 26 * 3600 ? $0 : nil }
        if let a = usableAlarm {
            let c = Calendar.current.dateComponents([.hour, .minute], from: a)
            wake = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) * 60
        } else if WindDownNudge.isEnabled {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            wake = WindDownNudge.wakeMinutes(forWeekday: Calendar.current.component(.weekday, from: tomorrow)) * 60
        } else if let mid = await repo.habitualMidsleepSec() {
            let typical = (SleepModel.sleepNeedMin(days: days)) * 60
            wake = (mid + Int(typical / 2)) % Self.day
        }
        var fullBed: Int?
        if let w = wake {
            bed = ((w - Int(inBed * 60)) % Self.day + Self.day) % Self.day
            fullBed = ((w - Int(fullInBed * 60)) % Self.day + Self.day) % Self.day
        }
        tonight = Tonight(need: sleepNeed, bedtime: bed, wake: wake, alarm: usableAlarm,
                          inBedMin: inBed, goal: goal, fullNeedBedtime: fullBed)
        forecast = RecoveryForecaster.forecast(recentCharge: days.compactMap(\.recovery),
                                               recentEffort: days.compactMap(\.strain),
                                               todayEffort: today?.strain,
                                               plannedSleepHours: sleepNeed.totalMin / 60)
        acwr = ReadinessEngine.evaluate(days: days).acwr
        let weekdayValues: [(weekday: Int, value: Double)] = days.suffix(180).compactMap { d in
            guard let r = d.recovery, let date = Self.date(d.day) else { return nil }
            let wd = Calendar(identifier: .iso8601).component(.weekday, from: date)
            return ((wd + 5) % 7 + 1, r)
        }
        weekday = PatternInsights.weekdayPattern(weekdayValues)
        let d = WeeklyDigestSource.digest(from: days, anchorDay: Repository.localDayKey(Date()))
        digest = d.isEmpty ? nil : d
    }

    /// Everything, including the readings that need stored samples.
    func loadAll(repo: Repository, maxHR: Int, cycleApplies: Bool, alarm: Date? = nil) async {
        await loadQuick(repo: repo, alarm: alarm)
        let days = repo.days
        var byDay: [String: DailyMetric] = [:]
        for d in days { byDay[d.day] = d }
        let now = Int(Date().timeIntervalSince1970)

        // What moves recovery: journal yes/no days against recovery.
        let entries = await repo.journalEntries()
        var yes: [String: Set<String>] = [:], no: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { yes[e.question, default: []].insert(e.day) } else { no[e.question, default: []].insert(e.day) }
        }
        var recovery: [String: Double] = [:]
        for d in days { if let r = d.recovery { recovery[d.day] = r } }
        effects = EffectRanker.rank(behaviors: yes, controls: no, outcomeByDay: recovery, outcome: "Recovery")
            .prefix(4)
            .map { Effect(id: $0.behavior + "\($0.lag)", behavior: $0.behavior, delta: $0.effect.delta, n: $0.effect.nWith) }

        // Heart-rate recovery after recent workouts.
        let rows = await repo.workoutRows(days: 120).filter { $0.endTs - $0.startTs >= 600 }.suffix(12)
        var drops: [Int] = []
        for r in rows {
            if let res = await repo.workoutHeartRateRecovery(from: r.startTs, to: r.endTs,
                                                              maxHR: Double(maxHR), source: r.source),
               let one = res.after1Minute {
                drops.append(res.endHR - one)
            }
        }
        if let last = drops.last {
            hrr = HRRStats(latestDrop: last, averageDrop: Double(drops.reduce(0, +)) / Double(drops.count),
                           workouts: drops.count)
        }

        // Sleep sessions: bedtime window and wind-down.
        let sessions = await repo.sleepSessions(from: now - 150 * Self.day, to: now, limit: 600)
            .filter { $0.endTs - $0.effectiveStartTs >= 3 * 3600 }
        var onsetPairs: [(onsetMinute: Int, recovery: Double)] = []
        for s in sessions {
            let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            guard let r = byDay[wakeDay]?.recovery else { continue }
            let c = Calendar.current.dateComponents([.hour, .minute],
                                                    from: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)))
            var m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if m < 12 * 60 { m += 24 * 60 }
            onsetPairs.append((m, r))
        }
        bedtime = PatternInsights.bedtimeWindow(nights: onsetPairs)

        var winds: [PatternInsights.WindDown] = []
        for s in sessions.suffix(7) {
            let onset = s.effectiveStartTs
            let hr = await repo.hrSamples(from: onset - 900, to: onset + 3 * 3600, limit: 30_000)
            if let w = PatternInsights.windDown(hr: hr, onset: onset) { winds.append(w) }
        }
        if !winds.isEmpty {
            windDown = WindDownStats(minutes: Double(winds.map(\.minutesToSettle).reduce(0, +)) / Double(winds.count),
                                     drop: winds.map(\.dropBpm).reduce(0, +) / Double(winds.count),
                                     nights: winds.count)
        }

        // Recovery and HRV across the cycle, from logged periods.
        if cycleApplies {
            let starts = await repo.periodStarts().compactMap(CycleDays.number)
            let todayNum = CycleDays.today()
            var groups: [CycleCalendar.Phase: (r: [Double], h: [Double])] = [:]
            for d in days.suffix(180) {
                guard let n = CycleDays.number(d.day), n < todayNum,
                      let info = CycleCalendar.dayInfo(n, periodStarts: starts, today: todayNum) else { continue }
                var g = groups[info.phase] ?? ([], [])
                if let r = d.recovery { g.r.append(r) }
                if let h = d.avgHrv { g.h.append(h) }
                groups[info.phase] = g
            }
            let order: [CycleCalendar.Phase] = [.menstrual, .follicular, .ovulatory, .luteal]
            let stats = order.compactMap { p -> PhaseStat? in
                guard let g = groups[p], g.r.count >= 3 else { return nil }
                return PhaseStat(phase: p, recovery: g.r.reduce(0, +) / Double(g.r.count),
                                 hrv: g.h.isEmpty ? nil : g.h.reduce(0, +) / Double(g.h.count), days: g.r.count)
            }
            cycle = stats.count >= 2 ? stats : []
        }
        loaded = true

        // Evening stress against that night's deep sleep (slowest; last).
        stressSleep = await eveningStressAgainstDeepSleep(repo: repo, byDay: byDay)
    }

    private func eveningStressAgainstDeepSleep(repo: Repository,
                                               byDay: [String: DailyMetric]) async -> PatternInsights.SplitEffect? {
        let cal = Calendar.current
        var pairs: [(driver: Double, outcome: Double)] = []
        let tz = TimeZone.current.secondsFromGMT()
        for back in 1...28 {
            guard let date = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date())),
                  let next = cal.date(byAdding: .day, value: 1, to: date),
                  let deep = byDay[Repository.localDayKey(next)]?.deepMin else { continue }
            let from = Int(date.timeIntervalSince1970) + 17 * 3600
            let to = from + 6 * 3600
            let hr = await repo.hrSamples(from: from, to: to, limit: 40_000)
            guard hr.count >= DaytimeStress.minHourHRSamples else { continue }
            let rr = await repo.rrIntervals(from: from, to: to, limit: 80_000)
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 80_000)
            let result = await runUnescalated {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz,
                                      mode: .dayRelative, includeTimeline: false)
            }
            let levels = result.hours.compactMap(\.level)
            guard levels.count >= 3 else { continue }
            pairs.append((levels.reduce(0, +) / Double(levels.count), deep))
        }
        return PatternInsights.splitEffect(pairs)
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func date(_ day: String) -> Date? { parser.date(from: day) }
}

// MARK: - Screen

struct PatternsScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var model: AppModel
    @StateObject private var patterns = PatternsModel()

    var body: some View {
        ScreenScaffold(title: "Patterns") {
            VStack(alignment: .leading, spacing: 14) {
                if let t = patterns.tonight {
                    PatternTonightCard(tonight: t) { Task { await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm()) } }
                }
                if let f = patterns.forecast { forecastCard(f) }
                if let a = patterns.acwr { PatternLoadCard(acwr: a) }
                illnessCard
                if !patterns.effects.isEmpty { effectsCard }
                if let w = patterns.bedtime { bedtimeCard(w) }
                if let w = patterns.weekday { weekdayCard(w) }
                if let s = patterns.stressSleep { stressCard(s) }
                if let w = patterns.windDown { windDownCard(w) }
                if let h = patterns.hrr { hrrCard(h) }
                if !patterns.cycle.isEmpty { cycleCard }
                if let d = patterns.digest { digestCard(d) }
                if patterns.loaded, !pending.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Needs more data")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                        ForEach(pending, id: \.self) { line in
                            Text(line)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                }
                if !patterns.loaded {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading your history…")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
            .animation(.snappy, value: patterns.loaded)
        }
        .task(id: repo.refreshSeq) {
            await patterns.loadAll(repo: repo, maxHR: profile.hrMax, cycleApplies: profile.cycleAwarenessApplies,
                                   alarm: model.nextArmedStrapAlarm())
        }
    }

    /// The cards hidden for lack of data, with what each one waits for.
    private var pending: [String] {
        var out: [String] = []
        if patterns.effects.isEmpty { out.append(String(localized: "What moves your recovery: answer the journal for a few weeks.")) }
        if patterns.hrr == nil { out.append(String(localized: "Heart-rate recovery: hard workouts with the strap on until a few minutes after.")) }
        if patterns.windDown == nil { out.append(String(localized: "How fast you switch off: nights with heart rate around falling asleep.")) }
        if patterns.stressSleep == nil { out.append(String(localized: "Evening stress and deep sleep: two weeks of evenings with the strap on.")) }
        if profile.cycleAwarenessApplies && patterns.cycle.isEmpty {
            out.append(String(localized: "Your cycle and your body: log at least two periods."))
        }
        return out
    }

    // MARK: Cards

    private func forecastCard(_ f: RecoveryForecast) -> some View {
        PatternCard(icon: "sunrise.fill", title: "Tomorrow morning",
                    basis: "From your last \(f.nights) nights, if you sleep \(Self.hours(f.plannedSleepHours * 60)).") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(f.charge.rounded()))%")
                    .font(StrandFont.display(44))
                    .foregroundStyle(StrandPalette.recoveryColor(f.charge))
                Text("\(Int(f.low.rounded()))–\(Int(f.high.rounded()))%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Expected recovery")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ViewBuilder
    private var illnessCard: some View {
        if let s = model.illnessSignal {
            let calm = s.level == .quiet
            PatternCard(icon: calm ? "checkmark.shield.fill" : "cross.case.fill", title: "Illness watch",
                        basis: "Breathing rate, skin temperature and resting heart rate against your normal.") {
                Text(calm ? String(localized: "Nothing unusual") : s.copy)
                    .font(.system(size: calm ? 24 : 17, weight: .bold))
                    .foregroundStyle(calm ? StrandPalette.accent : StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var effectsCard: some View {
        PatternCard(icon: "wand.and.sparkles", title: "What moves your recovery",
                    basis: "Days you logged each answer in the journal, against days you didn't.") {
            VStack(spacing: 10) {
                ForEach(patterns.effects) { e in
                    HStack {
                        Text(e.behavior)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%+.0f%%", e.delta))
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(e.delta >= 0 ? StrandPalette.accent : StrandPalette.statusCritical)
                    }
                }
            }
            NavigationLink { InsightsHubView() } label: {
                Text("All effects")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func bedtimeCard(_ w: PatternInsights.BedtimeWindow) -> some View {
        PatternCard(icon: "bed.double.fill", title: "Your best bedtime",
                    basis: "\(w.nightsInWindow) of \(w.nights) nights started in this window.") {
            Text("\(Self.clock(w.startMinute))–\(Self.clock(w.endMinute))")
                .font(StrandFont.display(40))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(w.windowMean - w.overallMean >= 3
                 ? String(localized: "Recovery \(Int(w.windowMean.rounded()))% after these nights, \(Int(w.overallMean.rounded()))% on average")
                 : String(localized: "Your most common bedtime. Recovery barely changes with when you go to bed."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func weekdayCard(_ w: PatternInsights.WeekdayPattern) -> some View {
        let symbols = Calendar(identifier: .iso8601).shortStandaloneWeekdaySymbols
        let lo = w.means.values.min() ?? 0
        let span = max(1, (w.means.values.max() ?? 1) - lo)
        return PatternCard(icon: "calendar", title: "Recovery by weekday",
                           basis: "Average over the last six months.") {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(1...7, id: \.self) { wd in
                    VStack(spacing: 6) {
                        Text(w.means[wd].map { "\(Int($0.rounded()))" } ?? "–")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(wd == w.best ? StrandPalette.accent
                                  : wd == w.worst ? StrandPalette.statusCritical : StrandPalette.textTertiary.opacity(0.5))
                            .frame(height: 16 + 64 * ((w.means[wd] ?? lo) - lo) / span)
                        Text(symbols[wd % 7])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 120)
            Text(String(localized: "Best on \(symbols[w.best % 7]), lowest on \(symbols[w.worst % 7])."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func stressCard(_ s: PatternInsights.SplitEffect) -> some View {
        PatternCard(icon: "bolt.heart.fill", title: "Evening stress and deep sleep",
                    basis: "\(s.n) evenings between 17:00 and 23:00 over the last four weeks.") {
            Text(String(format: "%+.0f min", s.delta))
                .font(StrandFont.display(40))
                .foregroundStyle(s.delta < 0 ? StrandPalette.statusCritical : StrandPalette.accent)
            Text(String(localized: "Deep sleep after your most stressful evenings, against your calmest: \(Int(s.highMean.rounded())) min vs \(Int(s.lowMean.rounded())) min."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windDownCard(_ w: PatternsModel.WindDownStats) -> some View {
        PatternCard(icon: "moon.zzz.fill", title: "How fast you switch off",
                    basis: "Last \(w.nights) nights. A slow settle often follows late meals, alcohol or evening training.") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(w.minutes.rounded()))")
                    .font(StrandFont.display(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("min")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(String(localized: "until your heart rate settles after falling asleep, dropping \(Int(w.drop.rounded())) bpm."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func hrrCard(_ h: PatternsModel.HRRStats) -> some View {
        PatternCard(icon: "heart.text.square.fill", title: "Heart-rate recovery",
                    basis: "Drop in the first minute after \(h.workouts) recent workouts. Higher is fitter.") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(h.latestDrop)")
                    .font(StrandFont.display(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("bpm")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(String(localized: "after your last workout, \(Int(h.averageDrop.rounded())) bpm on average"))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var cycleCard: some View {
        PatternCard(icon: "drop.fill", title: "Your cycle and your body",
                    basisText: model.cyclePhase.map { $0.note } ?? String(localized: "From the periods you logged.")) {
            VStack(spacing: 10) {
                ForEach(patterns.cycle) { p in
                    HStack {
                        Circle().fill(p.phase.tint).frame(width: 10, height: 10)
                        Text(p.phase.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        if let r = p.recovery {
                            Text("\(Int(r.rounded()))%")
                                .font(.system(size: 15, weight: .bold).monospacedDigit())
                                .foregroundStyle(StrandPalette.recoveryColor(r))
                        }
                        if let h = p.hrv {
                            Text("\(Int(h.rounded())) ms")
                                .font(.system(size: 14, weight: .medium).monospacedDigit())
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func digestCard(_ d: WeeklyDigest) -> some View {
        PatternCard(icon: "doc.text.fill", title: "This week",
                    basis: "\(d.daysWithData) days with data, against last week.") {
            VStack(spacing: 10) {
                ForEach(d.metrics, id: \.metric) { m in
                    HStack {
                        Text(m.metric.displayLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        if m.thisWeek.n > 0 {
                            Text(String(format: "%.0f", m.thisWeek.mean))
                                .font(.system(size: 15, weight: .bold).monospacedDigit())
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        Text(String(format: "%+.0f", m.wowDelta))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(m.wowGoodness > 0 ? StrandPalette.accent
                                             : m.wowGoodness < 0 ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            ForEach(d.focalPoints, id: \.self) { p in
                Text(p)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Formatting

    static func clock(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func hours(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }
}

// MARK: - Shared cards (also used on Home)

/// A pattern card: icon well, title, the answer, and a grey line saying what it is based on.
struct PatternCard<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let basis: Text
    let content: () -> Content

    init(icon: String, title: LocalizedStringKey, basis: LocalizedStringKey,
         @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon; self.title = title; self.basis = Text(basis); self.content = content
    }

    init(icon: String, title: LocalizedStringKey, basisText: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon; self.title = title; self.basis = Text(verbatim: basisText); self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            content()
            basis
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ZoopPanelSurface())
    }
}

struct PatternTonightCard: View {
    let tonight: PatternsModel.Tonight
    /// Called after the reminder is switched on, so the card can be recomputed with its wake time.
    var onReminderChange: () -> Void = {}

    var body: some View {
        PatternCard(icon: "moon.stars.fill", title: "Tonight",
                    basisText: basis) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PatternsScreen.hours(tonight.need.totalMin))
                    .font(StrandFont.display(40))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("sleep need")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let bed = tonight.bedtime, let wake = tonight.wake {
                Text(String(localized: "In bed by \(PatternsScreen.clock(bed / 60)) to wake at \(PatternsScreen.clock(wake / 60))"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
            WindDownReminderRow(suggestedWakeMinute: tonight.wake.map { $0 / 60 }, onChange: onReminderChange)
        }
    }

    private var basis: String {
        var parts = [String(localized: "\(PatternsScreen.hours(tonight.need.baseMin)) base")]
        if tonight.need.strainMin >= 1 { parts.append(String(localized: "+\(Int(tonight.need.strainMin.rounded())) min for today's strain")) }
        if tonight.need.debtMin >= 1 { parts.append(String(localized: "+\(Int(tonight.need.debtMin.rounded())) min toward your sleep debt")) }
        return parts.joined(separator: " · ")
    }
}

struct PatternLoadCard: View {
    let acwr: Double

    private var state: (String, Color) {
        switch acwr {
        case ..<0.8: return (String(localized: "Below your usual"), StrandPalette.stressLow)
        case ..<1.3: return (String(localized: "In your range"), StrandPalette.accent)
        case ..<1.5: return (String(localized: "Building fast"), StrandPalette.restColor)
        default: return (String(localized: "Too much, too soon"), StrandPalette.statusCritical)
        }
    }

    var body: some View {
        PatternCard(icon: "gauge.with.dots.needle.67percent", title: "Training load",
                    basis: "Last 7 days of strain against the last 4 weeks. 0.8 to 1.3 is the usual safe range.") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%.2f", acwr))
                    .font(StrandFont.display(40))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(state.0)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.1)
            }
            GeometryReader { g in
                let frac = min(1, max(0, (acwr - 0.4) / 1.4))
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        Capsule().fill(StrandPalette.stressLow).frame(width: g.size.width * 0.29)
                        Capsule().fill(StrandPalette.accent).frame(width: g.size.width * 0.35)
                        Capsule().fill(StrandPalette.restColor).frame(width: g.size.width * 0.14)
                        Capsule().fill(StrandPalette.statusCritical)
                    }
                    .frame(height: 6)
                    Circle().fill(StrandPalette.textPrimary)
                        .frame(width: 14, height: 14)
                        .offset(x: g.size.width * frac - 7)
                }
            }
            .frame(height: 14)
        }
    }
}
#endif

#if os(iOS)
/// Home's look ahead: tonight's sleep need, tomorrow's recovery and training load side by side, with
/// the week in numbers first on Sundays and Mondays, and a link to all patterns.
struct HomePatternsCarousel: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @StateObject private var patterns = PatternsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionTitle(title: "Looking ahead") {
                NavigationLink(value: TabRoute.patterns) {
                    Text("All patterns")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if let t = patterns.tonight {
                        PatternTonightCard(tonight: t) { Task { await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm()) } }
                            .frame(width: 290)
                    }
                    if let f = patterns.forecast {
                        PatternCard(icon: "sunrise.fill", title: "Tomorrow morning",
                                    basis: "If you sleep \(PatternsScreen.hours(f.plannedSleepHours * 60)).") {
                            Text("\(Int(f.charge.rounded()))%")
                                .font(StrandFont.display(40))
                                .foregroundStyle(StrandPalette.recoveryColor(f.charge))
                            Text("Expected recovery")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .frame(width: 240)
                    }
                    if let a = patterns.acwr { PatternLoadCard(acwr: a).frame(width: 290) }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
        .task(id: repo.refreshSeq) { await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm()) }
    }
}
#endif

#if os(iOS)
/// The wind-down reminder from the Tonight card: its time when it is on, a button to turn it on when not.
struct WindDownReminderRow: View {
    /// The wake time the card shows, handed to the reminder when none was set yet so both use one time.
    let suggestedWakeMinute: Int?
    let onChange: () -> Void
    @State private var enabled = WindDownNudge.isEnabled && WindDownNudge.followsSleepNeed
    @State private var denied = false

    private var reminderMinute: Int {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return WindDownNudge.nudgeMinuteOfDay(forWeekday: Calendar.current.component(.weekday, from: tomorrow))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: enabled ? "bell.fill" : "bell")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            if enabled {
                Text("Reminder at \(PatternsScreen.clock(reminderMinute))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if denied {
                Text("Notifications are off for Zoop")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Button {
                    WindDownNudge.setFollowsSleepNeed(true)
                    if !WindDownNudge.hasWakeSetting, let wake = suggestedWakeMinute {
                        WindDownNudge.setWakeMinutes(wake)
                    }
                    WindDownNudge.setEnabled(true) { outcome in
                        onChange()
                        withAnimation(.snappy) {
                            enabled = outcome == .scheduled
                            denied = outcome == .denied
                        }
                    }
                } label: {
                    Text("Remind me to wind down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif

#if os(iOS)
/// How much of tonight's sleep need the plan aims for. Chosen in the sleep planner; the bedtime, the
/// Home card and the wind-down reminder all follow it.
enum SleepGoal: String, CaseIterable, Identifiable {
    case peak, perform, getBy
    var id: String { rawValue }
    static let storageKey = "zoop.sleepPlanner.goal"

    static var current: SleepGoal {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SleepGoal.init(rawValue:)) ?? .peak
    }

    var fraction: Double {
        switch self {
        case .peak: return 1.0
        case .perform: return 0.85
        case .getBy: return 0.7
        }
    }

    var title: String {
        switch self {
        case .peak: return String(localized: "Get all the sleep I need")
        case .perform: return String(localized: "Perform well")
        case .getBy: return String(localized: "Just get by")
        }
    }
}
#endif
