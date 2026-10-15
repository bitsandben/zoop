import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Today, trend, breathe, label (CONCEPT §3.5)
//
// The cards under the hero. Each reads values `StressScreenModel` and `StressReadouts` already resolved;
// none computes a stress number of its own.

// MARK: Today

struct StressTodayCard: View {
    let summary: StressReadouts.DaySummary

    var body: some View {
        ContentCard("zoop.stress.card.today") {
            VStack(spacing: 0) {
                row(StressStrings.highest, StressStrings.levelAt(level(summary.highest.level), time(summary.highest)), first: true)
                row(StressStrings.lowest, StressStrings.levelAt(level(summary.lowest.level), time(summary.lowest)))
                row(StressStrings.average, level(summary.average))
                row(StressStrings.timeHigh, duration(minutes: summary.highMinutes))
            }
        }
    }

    private func row(_ label: LocalizedStringResource, _ value: String, first: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopSpacing.m)
            Text(verbatim: value).font(ZoopType.body).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
        }
        .listCardRow(isFirst: first)
        .accessibilityElement(children: .combine)
    }

    private func level(_ value: Double?) -> String { StressTrace.displayLevel(value ?? 0) }

    /// The start of the hour the point covers.
    private func time(_ point: DaytimeStress.HourPoint) -> String {
        StressScreenModel.time(Date(timeIntervalSince1970: TimeInterval(point.startTs)))
    }

    private func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow, zeroValueUnits: .hide))
            .nonEmpty ?? Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .narrow))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: Trend

enum StressTrendRange: Int, CaseIterable {
    case week = 7, month = 30

    var title: String {
        switch self {
        case .week: return String(localized: StressStrings.week)
        case .month: return String(localized: StressStrings.month)
        }
    }
}

struct StressTrendCard: View {
    let daily: DaytimeStress.Daily?
    let typical: StressReadouts.Typical

    @State private var range: StressTrendRange = .week

    var body: some View {
        let points = StressReadouts.trend(daily, days: range.rawValue)
        ContentCard("zoop.stress.card.trend") {
            SegmentedPillControl(StressTrendRange.allCases, selection: $range, adaptsToAvailableWidth: true) { $0.title }
            if points.count >= 2 {
                chart(points)
            } else {
                Text(StressStrings.trendEmpty).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chart(_ points: [StressReadouts.TrendPoint]) -> some View {
        Chart {
            if typical.isPersonal, let first = points.first, let last = points.last {
                RectangleMark(xStart: .value("From", first.date), xEnd: .value("To", last.date),
                              yStart: .value("Low", typical.range.lowerBound), yEnd: .value("High", typical.range.upperBound))
                    .foregroundStyle(StrandPalette.stressMedium.opacity(ZoopChartStyle.bandOpacity))
            }
            ForEach(points) { p in
                LineMark(x: .value("Day", p.date), y: .value("Stress", p.level))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...3)
        .zoopYAxis { StressTrace.displayLevel($0) }
        .zoopDayXAxis(days: range.rawValue)
        .frame(height: 160)
        .accessibilityLabel(Text(StressStrings.trendSummary))
    }
}

// MARK: Breathe

struct StressBreatheCard: View {
    let isHigh: Bool
    let onStart: () -> Void

    var body: some View {
        ContentCard("zoop.stress.card.breathe") {
            Text(isHigh ? StressStrings.breatheHigh : StressStrings.breatheCalm)
                .font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ZoopButton("zoop.stress.breathe.start", systemImage: "wind", kind: isHigh ? .primary : .secondary,
                       fullWidth: true, action: onStart)
        }
    }
}

// MARK: "Were you stressed?"

struct StressAskCard: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        ContentCard("zoop.stress.ask.title") {
            Text(StressStrings.askBody).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZoopSpacing.m) {
                ZoopButton("zoop.stress.ask.yes", kind: .secondary, fullWidth: true) { onAnswer(true) }
                ZoopButton("zoop.stress.ask.no", kind: .secondary, fullWidth: true) { onAnswer(false) }
            }
        }
    }
}

// MARK: Test Centre

/// Alternate stress definitions, shown only while the Test Centre stress domain is on.
struct StressAdvancedCard: View {
    let index: StressIndex.Components?
    let freq: HRVFreqDomain.Bands?

    var body: some View {
        if index != nil || freq?.lfhf != nil {
            ContentCard {
                Text(StressStrings.advancedCard).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                if let index { line("Baevsky Stress Index", "\(Int(index.si.rounded()))") }
                if let ratio = freq?.lfhf { line("Autonomic balance (LF/HF)", StressTrace.formatRatio(ratio)) }
            }
        }
    }

    private func line(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopSpacing.m)
            Text(verbatim: value).font(ZoopType.body).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
        }
    }
}
