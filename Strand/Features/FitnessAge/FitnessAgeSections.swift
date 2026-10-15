#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Section chrome

struct FitnessSectionTitle: View {
    let text: LocalizedStringResource
    init(_ text: LocalizedStringResource) { self.text = text }

    var body: some View {
        Text(text)
            .font(ZoopType.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct FitnessPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) { content }
            .padding(ZoopSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zoopInsetSurface(radius: ZoopRadius.tile)
    }
}

private extension Text {
    func fitnessNote() -> some View {
        self.font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Lever ("Hebel")

/// The one change the model says would lower the fitness age most, worded as a what-if.
struct FitnessLeverSection: View {
    let advice: FitnessLeverAdvice?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            FitnessSectionTitle(FitnessAgeStrings.leverTitle)
            FitnessPanel {
                if let advice {
                    Text(advice.title)
                        .font(StrandFont.ui(15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(advice.text)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(FitnessAgeStrings.leverNone)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(FitnessAgeStrings.leverFootnote).fitnessNote()
            }
        }
    }
}

// MARK: - Weekly history

/// The stored weekly fitness ages with the ± band the estimate can be off, against your real age.
struct FitnessHistorySection: View {
    let history: FitnessSeries
    let chronoAge: Double

    var body: some View {
        let cutoff = Repository.localDayKey(Date().addingTimeInterval(-90 * 86_400))
        let pts = history.filter { $0.day >= cutoff }
            .compactMap { p in fitnessDayDate(p.day).map { (date: $0, value: p.value) } }
        let band = FitnessAgeEngine.displayBandYears
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            FitnessSectionTitle(FitnessAgeStrings.historyTitle)
            FitnessPanel {
                if pts.count >= 2 {
                    Chart {
                        ForEach(pts, id: \.date) { p in
                            AreaMark(x: .value("Week", p.date),
                                     yStart: .value("Low", p.value - band), yEnd: .value("High", p.value + band))
                                .foregroundStyle(StrandPalette.textPrimary.opacity(0.08))
                                .interpolationMethod(.monotone)
                        }
                        RuleMark(y: .value("Age", chronoAge))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        ForEach(pts, id: \.date) { p in
                            LineMark(x: .value("Week", p.date), y: .value("Fitness Age", p.value))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Week", p.date), y: .value("Fitness Age", p.value))
                                .foregroundStyle(fitnessTint(delta: chronoAge - p.value))
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
                    Text(FitnessAgeStrings.historyNote(fitnessOneDecimal(band))).fitnessNote()
                } else {
                    Text(FitnessAgeStrings.historyEmpty).fitnessNote()
                }
            }
        }
    }
}

// MARK: - VO₂max line

/// VO₂max over the last half year against what is typical for people within five years of your age.
struct FitnessVO2Section: View {
    let line: FitnessSeries
    let chronoAge: Double
    let sex: String
    let measured: Bool

    var body: some View {
        let pts = line.compactMap { p in fitnessDayDate(p.day).map { (date: $0, value: p.value) } }
        let source: FitnessVO2Source = measured ? .measured : .nesEstimate
        let lo = FitnessAgeEngine.vo2Norm(age: chronoAge + 5, sex: sex, source: source)
        let hi = FitnessAgeEngine.vo2Norm(age: max(18, chronoAge - 5), sex: sex, source: source)
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            FitnessSectionTitle(FitnessAgeStrings.vo2Title)
            FitnessPanel {
                if pts.count >= 2, let first = pts.first, let last = pts.last {
                    Chart {
                        // The band is drawn between the line's two end days so it spans the plot.
                        ForEach([first.date, last.date], id: \.self) { day in
                            AreaMark(x: .value("Day", day), yStart: .value("Low", lo), yEnd: .value("High", max(lo, hi)),
                                     series: .value("Series", "band"))
                                .foregroundStyle(StrandPalette.metricCyan.opacity(0.14))
                        }
                        ForEach(pts, id: \.date) { p in
                            LineMark(x: .value("Day", p.date), y: .value("VO2max", p.value),
                                     series: .value("Series", "line"))
                                .foregroundStyle(StrandPalette.metricCyan)
                                .interpolationMethod(.monotone)
                        }
                        PointMark(x: .value("Day", last.date), y: .value("VO2max", last.value))
                            .foregroundStyle(StrandPalette.metricCyan)
                            .symbolSize(40)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(StrandPalette.hairline)
                            AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .frame(height: 160)
                    Text(FitnessAgeStrings.vo2Note).fitnessNote()
                } else {
                    Text(FitnessAgeStrings.vo2Empty).fitnessNote()
                }
            }
        }
    }
}

// MARK: - Method

struct FitnessMethodSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            FitnessSectionTitle(FitnessAgeStrings.methodTitle)
            Text(FitnessAgeStrings.methodBlend).fitnessNote()
            Text(FitnessAgeStrings.methodCadence).fitnessNote()
            Text(FitnessAgeStrings.methodSources).fitnessNote()
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
