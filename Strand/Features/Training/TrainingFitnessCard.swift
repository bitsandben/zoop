import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Fitness & fatigue
//
// Six weeks of the Banister fitness-fatigue model (`TrainingLoadEngine`): fitness is the 42-day average
// of daily Effort, fatigue the 7-day average, and the band between them is form. The verdict word and
// sentence come from the SAME gauge reading the gauges below draw, so the chart and the gauge cannot
// state different things about this week.

struct TrainingFitnessCard: View {
    let load: TrainingLoadEngine.Result
    let cardio: TrainingLoadGauge.Reading?
    let effortScale: EffortScale

    /// Six weeks of points, the horizon of the concept's chart.
    private static let windowDays = 42

    @State private var selected: Date?

    private struct Row: Identifiable {
        let date: Date
        let fitness: Double
        let fatigue: Double
        var id: Date { date }
    }

    /// Day keys are local calendar days, so they are parsed in the local zone; a UTC parse would shift
    /// the points a day in the Americas.
    private static let dayParser: DateFormatter = DayKeyFormat.local

    private var rows: [Row] {
        load.points.suffix(Self.windowDays).compactMap { p in
            Self.dayParser.date(from: p.day).map {
                Row(date: $0,
                    fitness: TrainingEffort.value(p.chronicLoad, scale: effortScale),
                    fatigue: TrainingEffort.value(p.acuteLoad, scale: effortScale))
            }
        }
    }

    var body: some View {
        ContentCard {
            header
            if load.isAvailable {
                readout
                chart
                Text(takeaway)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(TrainingStrings.fitnessExplain)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(TrainingStrings.fitnessNeedsDays(
                    minimum: TrainingLoadEngine.Configuration.standard.minimumDays,
                    have: load.contiguousDays))
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(TrainingStrings.fitnessTitle)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: ZoopSpacing.s)
            if let band = cardio.flatMap({ TrainingEffort.band(for: $0.state) }) {
                Text(String(localized: band.text))
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: Chart

    /// Legend by default; while scrubbing, the pinned values for the touched day instead of a tooltip
    /// that would cover the lines.
    private var readout: some View {
        HStack(spacing: ZoopSpacing.l) {
            if let row = selectedRow {
                Text(row.date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
                    .locale(AppLanguage.activeLocale)))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                legendItem(StrandPalette.gold, TrainingStrings.fitness, value: row.fitness)
                legendItem(StrandPalette.strain100, TrainingStrings.fatigue, value: row.fatigue)
            } else {
                legendItem(StrandPalette.gold, TrainingStrings.fitness, value: rows.last?.fitness)
                legendItem(StrandPalette.strain100, TrainingStrings.fatigue, value: rows.last?.fatigue)
            }
            Spacer(minLength: 0)
        }
    }

    private func legendItem(_ color: Color, _ label: String, value: Double?) -> some View {
        HStack(spacing: ZoopSpacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            if let value {
                Text(ZoopNumber.decimal(value, digits: 1))
                    .font(ZoopType.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private var selectedRow: Row? {
        guard let selected else { return nil }
        return rows.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    private var chart: some View {
        let data = rows
        let top = max(data.map { max($0.fitness, $0.fatigue) }.max() ?? 1, 1)
        return Chart {
            ForEach(data) { r in
                ZoopBandMark(x: .value("Day", r.date), low: min(r.fitness, r.fatigue),
                             high: max(r.fitness, r.fatigue), color: StrandPalette.gold)
                LineMark(x: .value("Day", r.date), y: .value("Fitness", r.fitness),
                         series: .value("Series", "Fitness"))
                    .foregroundStyle(StrandPalette.gold)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", r.date), y: .value("Fatigue", r.fatigue),
                         series: .value("Series", "Fatigue"))
                    .foregroundStyle(StrandPalette.strain100)
                    .interpolationMethod(.monotone)
            }
            if let row = selectedRow {
                RuleMark(x: .value("Day", row.date)).zoopScrubRule()
            }
        }
        .chartYScale(domain: 0...(top * 1.1))
        .zoopYAxis { ZoopNumber.decimal($0, digits: 0) }
        .zoopDayXAxis(days: Self.windowDays)
        .frame(height: 180)
        .scrubbable($selected)
        .accessibilityLabel(TrainingStrings.fitnessAccessibility)
        .accessibilityValue(rows.last.map {
            "\(TrainingStrings.fitness) \(ZoopNumber.decimal($0.fitness)), "
                + "\(TrainingStrings.fatigue) \(ZoopNumber.decimal($0.fatigue))"
        } ?? "")
    }

    private var takeaway: String {
        guard let state = cardio?.state else { return TrainingStrings.takeawayCalibrating }
        switch state {
        case .calibrating: return TrainingStrings.takeawayCalibrating
        case .low: return TrainingStrings.takeawayLow
        case .optimal: return TrainingStrings.takeawayOptimal
        case .high: return TrainingStrings.takeawayHigh
        }
    }
}

private extension View {
    /// Drag-to-read on touch platforms; `chartXSelection` needs iOS 17, which is the deployment floor.
    @ViewBuilder func scrubbable(_ date: Binding<Date?>) -> some View {
        #if os(iOS)
        chartXSelection(value: date)
        #else
        self
        #endif
    }
}
