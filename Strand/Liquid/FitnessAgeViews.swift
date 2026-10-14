#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Fitness Age (Zoop iOS)
//
// Home's Fitness Age card and its detail screen, in the style of Bevel's Biological Age. Both read the
// weekly rows `IntelligenceEngine.fitnessAgeRows` stores (the age, each factor's years and the inputs it
// was scored on), so the card, the dial and the factor rows all show one computation.

/// What the card and the screen show: the stored weekly fitness ages and the latest week's breakdown.
struct FitnessAgeSnapshot {
    var history: [(day: String, value: Double)] = []
    /// Weighted years per factor for the latest week (positive = older).
    var contributions: [FitnessAgeFactor: Double] = [:]
    /// Input values for the latest week, by stored key.
    var inputs: [String: Double] = [:]

    var latest: (day: String, value: Double)? { history.last }

    static func load(repo: Repository) async -> FitnessAgeSnapshot {
        var snap = FitnessAgeSnapshot()
        snap.history = await repo.exploreSeries(key: "fitness_age", source: "my-whoop", days: 400)
        guard let day = snap.history.last?.day else { return snap }
        for f in FitnessAgeFactor.allCases {
            if let v = await value(repo, f.contributionKey, day) { snap.contributions[f] = v }
        }
        let inputKeys = FitnessAgeFactor.allCases.map(\.inputKey)
            + [FitnessAgeKeys.vo2Measured, FitnessAgeKeys.bodyFat, FitnessAgeKeys.bmi]
        for k in inputKeys {
            if let v = await value(repo, k, day) { snap.inputs[k] = v }
        }
        return snap
    }

    private static func value(_ repo: Repository, _ key: String, _ day: String) async -> Double? {
        await repo.exploreSeries(key: key, source: "my-whoop", days: 400).first { $0.day == day }?.value
    }
}

/// Younger reads positive, older warning, the same as your age neutral.
private func fitnessTint(delta: Double) -> Color {
    if delta >= 0.5 { return StrandPalette.statusPositive }
    if delta <= -0.5 { return StrandPalette.statusWarning }
    return StrandPalette.textSecondary
}

private func oneDecimal(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(1)))
}

/// "2.6 years younger than your age" as whole sentences per direction.
func fitnessAgeDeltaLine(fitnessAge: Double, chronoAge: Int) -> String {
    let delta = Double(chronoAge) - fitnessAge
    let years = oneDecimal(abs(delta))
    if abs(delta) < 0.5 { return String(localized: "About the same as your age") }
    return delta > 0
        ? String(localized: "\(years) years younger than your age")
        : String(localized: "\(years) years older than your age")
}

private func dayDate(_ day: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: day)
}

// MARK: - Home card

/// The full-width Home card: the fitness age, how far it sits from your real age, and a small dial.
struct HomeFitnessAgeCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var snapshot = FitnessAgeSnapshot()
    @State private var loaded = false

    var body: some View {
        HStack(alignment: .center, spacing: ZoopMetrics.space4) {
            VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                HStack(spacing: 6) {
                    Text("Fitness Age")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                if let latest = snapshot.latest {
                    Text(verbatim: oneDecimal(latest.value))
                        .font(StrandFont.display(34))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(fitnessAgeDeltaLine(fitnessAge: latest.value, chronoAge: profile.age))
                        .font(StrandFont.subhead)
                        .foregroundStyle(fitnessTint(delta: Double(profile.age) - latest.value))
                        .lineLimit(2)
                } else {
                    Text(verbatim: "–")
                        .font(StrandFont.display(34))
                        .foregroundStyle(StrandPalette.textSecondary)
                    if loaded {
                        Text(fitnessReadyLeadCopy(
                            rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
                            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            if let latest = snapshot.latest, profile.age > 0 {
                FitnessAgeDial(value: latest.value, chronoAge: Double(profile.age), compact: true)
                    .frame(width: 112, height: 64)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: repo.refreshSeq) {
            snapshot = await FitnessAgeSnapshot.load(repo: repo)
            loaded = true
        }
    }
}

// MARK: - Dial

/// A half-circle gauge with fine ticks over your age ±5 years (widened to fit the value): younger to the
/// left, older to the right, your age as a longer tick, the span between your age and the fitness age
/// tinted, and a dot on the value.
struct FitnessAgeDial: View {
    let value: Double
    let chronoAge: Double
    var compact = false

    private var range: ClosedRange<Double> {
        let lo = min(chronoAge - 5, value - 1), hi = max(chronoAge + 5, value + 1)
        return lo...hi
    }

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width / 2, size.height) - (compact ? 6 : 10)
            let center = CGPoint(x: size.width / 2, y: size.height - (compact ? 2 : 4))
            let span = range.upperBound - range.lowerBound
            func angle(_ v: Double) -> Double { .pi + (v - range.lowerBound) / span * .pi }
            func point(_ a: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
            }
            let ticks = compact ? 36 : 60
            let tickLen: CGFloat = compact ? 7 : 14
            let lo = min(value, chronoAge), hi = max(value, chronoAge)
            let tint = fitnessTint(delta: chronoAge - value)
            for i in 0...ticks {
                let v = range.lowerBound + span * Double(i) / Double(ticks)
                let a = angle(v)
                var path = Path()
                path.move(to: point(a, r - tickLen))
                path.addLine(to: point(a, r))
                let inSpan = v >= lo && v <= hi
                ctx.stroke(path, with: .color(inSpan ? tint : StrandPalette.textTertiary.opacity(0.55)),
                           lineWidth: compact ? 1.5 : 2)
            }
            // Your age: a longer neutral tick.
            var age = Path()
            let aa = angle(chronoAge)
            age.move(to: point(aa, r - tickLen - (compact ? 4 : 8)))
            age.addLine(to: point(aa, r + (compact ? 2 : 4)))
            ctx.stroke(age, with: .color(StrandPalette.textSecondary), lineWidth: compact ? 1.5 : 2.5)
            // The value: a dot on the arc.
            let dot = point(angle(value), r - tickLen / 2)
            let d: CGFloat = compact ? 9 : 16
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - d / 2, y: dot.y - d / 2, width: d, height: d)),
                     with: .color(StrandPalette.textPrimary))
        }
    }
}

// MARK: - Screen

/// The Fitness Age screen: the dial for the latest week, what it is, each factor with its trend, value,
/// a sparkline and the years it adds or removes, and the weekly history.
struct FitnessAgeScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @State private var snapshot = FitnessAgeSnapshot()
    @State private var lines: [FitnessAgeFactor: [(day: String, value: Double)]] = [:]
    @State private var loaded = false
    @State private var refreshing = false
    @State private var showSettings = false

    var body: some View {
        ScreenScaffold(title: "Fitness Age") {
            VStack(alignment: .leading, spacing: 14) {
                if let latest = snapshot.latest, profile.age > 0 {
                    hero(latest)
                    Text("An estimate from your fitness, heart, activity, body and sleep compared with people of your age and sex.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ZoopPanelSurface(cornerRadius: 20))
                    factorsSection
                    historySection(chrono: Double(profile.age))
                } else if loaded {
                    notReady
                }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        snapshot = await FitnessAgeSnapshot.load(repo: repo)
        lines = await Self.sparklines(repo: repo, inputs: snapshot.inputs)
        loaded = true
    }

    // MARK: Hero

    private func hero(_ latest: (day: String, value: Double)) -> some View {
        let chrono = Double(profile.age)
        let delta = chrono - latest.value
        return VStack(spacing: ZoopMetrics.space2) {
            if let d = dayDate(latest.day) {
                Text("Week of \(d.formatted(.dateTime.day().month(.wide)))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ZStack(alignment: .bottom) {
                FitnessAgeDial(value: latest.value, chronoAge: chrono)
                    .frame(height: 170)
                VStack(spacing: 2) {
                    Text(verbatim: oneDecimal(latest.value))
                        .font(StrandFont.display(56))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(fitnessAgeDeltaLine(fitnessAge: latest.value, chronoAge: profile.age))
                        .font(StrandFont.subhead)
                        .foregroundStyle(fitnessTint(delta: delta))
                }
            }
            HStack {
                Text(verbatim: oneDecimal(min(chrono - 5, latest.value - 1)))
                Spacer()
                Text("Your age \(profile.age)")
                Spacer()
                Text(verbatim: oneDecimal(max(chrono + 5, latest.value + 1)))
            }
            .font(StrandFont.footnote.monospacedDigit())
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(ZoopPanelSurface(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(String(localized: "Fitness Age")) \(oneDecimal(latest.value)), \(fitnessAgeDeltaLine(fitnessAge: latest.value, chronoAge: profile.age))"))
    }

    // MARK: Factors

    private var factorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What shapes it")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 6)
            ForEach(FitnessAgeFactor.allCases.filter { snapshot.contributions[$0] != nil }, id: \.self) { f in
                FitnessFactorRow(title: title(f), value: valueText(f),
                                 trend: FitnessTrend.of(lines[f] ?? [], lowerIsBetter: f == .restingHR || f == .body),
                                 line: lines[f] ?? [], years: snapshot.contributions[f] ?? 0)
            }
            if snapshot.contributions[.vo2max] == nil {
                Button { showSettings = true } label: {
                    Text("Add your waist in Settings or a VO₂max in Apple Health to include your fitness.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
        }
    }

    private func title(_ f: FitnessAgeFactor) -> String {
        switch f {
        case .vo2max:
            return snapshot.inputs[FitnessAgeKeys.vo2Measured] == 1
                ? String(localized: "VO₂max") : String(localized: "VO₂max (estimated)")
        case .restingHR: return String(localized: "Resting HR baseline")
        case .hrv: return String(localized: "HRV baseline")
        case .activity: return String(localized: "Activity")
        case .body:
            return snapshot.inputs[FitnessAgeKeys.bodyFat] != nil ? String(localized: "Body fat") : String(localized: "BMI")
        case .sleep: return String(localized: "Sleep regularity")
        }
    }

    private func valueText(_ f: FitnessAgeFactor) -> String {
        let i = snapshot.inputs
        switch f {
        case .vo2max: return i[f.inputKey].map { "\(oneDecimal($0)) ml/kg/min" } ?? "–"
        case .restingHR: return i[f.inputKey].map { "\(oneDecimal($0)) bpm" } ?? "–"
        case .hrv: return i[f.inputKey].map { "\(oneDecimal($0)) ms" } ?? "–"
        case .activity: return i[f.inputKey].map { String(localized: "Index \(oneDecimal($0)) of 15") } ?? "–"
        case .body:
            if let bf = i[FitnessAgeKeys.bodyFat] { return "\(oneDecimal(bf)) %" }
            return i[FitnessAgeKeys.bmi].map { oneDecimal($0) } ?? "–"
        case .sleep: return i[f.inputKey].map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
        }
    }

    /// The last 60 days of each factor's underlying daily signal, for the sparklines and trend words.
    private static func sparklines(repo: Repository, inputs: [String: Double])
        async -> [FitnessAgeFactor: [(day: String, value: Double)]] {
        let cutoff = Repository.localDayKey(Date().addingTimeInterval(-60 * 86_400))
        let days = repo.days.filter { $0.day >= cutoff }.sorted { $0.day < $1.day }
        func daily(_ pick: (DailyMetric) -> Double?) -> [(day: String, value: Double)] {
            days.compactMap { d in pick(d).map { (day: d.day, value: $0) } }
        }
        var out: [FitnessAgeFactor: [(day: String, value: Double)]] = [:]
        out[.restingHR] = daily { $0.restingHr.map(Double.init) }
        out[.hrv] = daily { $0.avgHrv }
        out[.activity] = daily { $0.strain }
        out[.sleep] = daily { $0.totalSleepMin.map { $0 / 60 } }
        let vo2Key = inputs[FitnessAgeKeys.vo2Measured] == 1 ? "vo2max" : "vo2max_est"
        let vo2Source = vo2Key == "vo2max" ? "apple-health" : "my-whoop"
        out[.vo2max] = await repo.exploreSeries(key: vo2Key, source: vo2Source, days: 60)
        let bodyKey = inputs[FitnessAgeKeys.bodyFat] != nil ? "body_fat" : "weight"
        out[.body] = await repo.exploreSeries(key: bodyKey, source: "apple-health", days: 60)
        return out.mapValues(rollingMean)
    }

    /// A trailing 7-point mean, so a sparkline shows the drift the 30-day baselines follow rather than
    /// night-to-night noise (and a part-day reading cannot spike its end).
    private static func rollingMean(_ s: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        s.indices.map { i in
            let w = s[max(0, i - 6)...i]
            return (day: s[i].day, value: w.map(\.value).reduce(0, +) / Double(w.count))
        }
    }

    // MARK: History

    private func historySection(chrono: Double) -> some View {
        let cutoff = Repository.localDayKey(Date().addingTimeInterval(-90 * 86_400))
        let pts = snapshot.history.filter { $0.day >= cutoff }.compactMap { p in dayDate(p.day).map { (date: $0, value: p.value) } }
        return VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            Text("Last 90 days")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            if pts.count >= 2 {
                Chart {
                    RuleMark(y: .value("Age", chrono))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    ForEach(pts, id: \.date) { p in
                        LineMark(x: .value("Week", p.date), y: .value("Fitness Age", p.value))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Week", p.date), y: .value("Fitness Age", p.value))
                            .foregroundStyle(fitnessTint(delta: chrono - p.value))
                            .symbolSize(24)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(height: 160)
            } else {
                Text("A line appears after a second week.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }

    // MARK: Not ready

    private var notReady: some View {
        let readiness = FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty,
            rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
            activityDays: repo.days.suffix(7).compactMap { $0.strain }.count,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0, hasWaist: profile.waistCm > 0)
        return VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
            Text(fitnessReadyLeadCopy(rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
                                      hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(readiness.items, id: \.key) { item in
                HStack(spacing: ZoopMetrics.space3) {
                    Image(systemName: item.status == .satisfied ? "checkmark.circle.fill"
                          : item.status == .partial ? "circle.lefthalf.filled" : "circle")
                        .foregroundStyle(item.status == .satisfied ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    Text(engineText(item.label))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(engineText(item.detail))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            HStack(spacing: ZoopMetrics.space4) {
                Button("Open Settings") { showSettings = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        _ = await intelligence.recomputeFitnessAgeOnly()
                        await load()
                        refreshing = false
                    }
                } label: {
                    if refreshing { ProgressView() } else { Text("Refresh") }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }
}

// MARK: - Factor row

/// Which way a factor's signal is moving, judged on its last 14 days against the 46 before.
enum FitnessTrend {
    case improving(up: Bool), worsening(up: Bool), steady

    static func of(_ series: [(day: String, value: Double)], lowerIsBetter: Bool) -> FitnessTrend {
        guard series.count >= 6 else { return .steady }
        let cutoff = Repository.localDayKey(Date().addingTimeInterval(-14 * 86_400))
        let recent = series.filter { $0.day >= cutoff }.map(\.value)
        let before = series.filter { $0.day < cutoff }.map(\.value)
        guard !recent.isEmpty, !before.isEmpty else { return .steady }
        let r = recent.reduce(0, +) / Double(recent.count), b = before.reduce(0, +) / Double(before.count)
        guard b != 0, abs(r - b) / abs(b) >= 0.03 else { return .steady }
        let up = r > b
        return up != lowerIsBetter ? .improving(up: up) : .worsening(up: up)
    }

    var word: String {
        switch self {
        case .improving: return String(localized: "Improving")
        case .worsening: return String(localized: "Worsening")
        case .steady: return String(localized: "Steady")
        }
    }

    var icon: String {
        switch self {
        case .improving(let up), .worsening(let up):
            return up ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
        case .steady: return "arrow.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .improving: return StrandPalette.statusPositive
        case .worsening: return StrandPalette.statusWarning
        case .steady: return StrandPalette.textSecondary
        }
    }
}

/// One factor: its name, the trend word with an arrow, the value it was scored on, a sparkline of the
/// last 60 days with its average dotted, and the years it adds (+) or removes (−).
private struct FitnessFactorRow: View {
    let title: String
    let value: String
    let trend: FitnessTrend
    let line: [(day: String, value: Double)]
    let years: Double

    var body: some View {
        HStack(alignment: .center, spacing: ZoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 5) {
                    Image(systemName: trend.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(trend.tint)
                    Text(trend.word)
                        .foregroundStyle(trend.tint)
                    Text(verbatim: "·")
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(verbatim: value)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.system(size: 13, weight: .medium))
            }
            Spacer(minLength: 6)
            FitnessSparkline(points: line, tint: trend.tint)
                .frame(width: 72, height: 30)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: (years > 0 ? "+" : years < 0 ? "−" : "") + oneDecimal(abs(years)))
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(years < -0.05 ? StrandPalette.statusPositive
                                     : years > 0.05 ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                Text("years")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .background(ZoopPanelSurface(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(trend.word), \(value), \(String(localized: "\(oneDecimal(years)) years"))"))
    }
}

/// A small line of a factor's recent values, its average as a dotted rule and a dot on the latest.
private struct FitnessSparkline: View {
    let points: [(day: String, value: Double)]
    let tint: Color

    var body: some View {
        let pts = points.compactMap { p in dayDate(p.day).map { (date: $0, value: p.value) } }
        if pts.count >= 2, let last = pts.last {
            let mean = pts.map(\.value).reduce(0, +) / Double(pts.count)
            Chart {
                RuleMark(y: .value("Average", mean))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
                ForEach(pts, id: \.date) { p in
                    LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                PointMark(x: .value("Day", last.date), y: .value("Value", last.value))
                    .foregroundStyle(tint)
                    .symbolSize(22)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}
#endif
