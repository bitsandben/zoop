#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Card

struct SleepInsightCard: View {
    let kind: SleepInsightKind
    let report: SleepInsights.Report

    var body: some View {
        ContentCard(LocalizedStringKey(kind.title), showsChevron: true) {
            if let headline = kind.headline(report) {
                Text(verbatim: headline)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SleepInsightChart(kind: kind, report: report, large: false)
                .frame(height: 64)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the details"))
    }
}

// MARK: - Detail sheet

struct SleepInsightDetailSheet: View {
    let kind: SleepInsightKind
    let report: SleepInsights.Report
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                    if let headline = kind.headline(report) {
                        Text(verbatim: headline)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ContentCard {
                        SleepInsightChart(kind: kind, report: report, large: true)
                            .frame(height: ZoopMetrics.chartHeight)
                        footer
                    }
                    VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                        Text("How it's computed").font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: kind.method)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ZoopSpacing.gutter)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(verbatim: kind.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// The data behind the chart: the window and how many nights it holds.
    @ViewBuilder
    private var footer: some View {
        switch kind {
        case .latency:
            if let l = report.latency {
                ChartFooter([("Typical", SleepInsightFormat.duration(l.typicalMin)),
                             ("Last 7 nights", SleepInsightFormat.duration(l.recentMin)),
                             ("Nights", "\(l.nightCount)")])
            }
        case .sleepNeed:
            if let n = report.sleepNeed {
                ChartFooter([("Best recovery", "\(Int(n.best.meanRecovery.rounded()))"),
                             ("Range", "\(Int(n.spreadPts.rounded()))"),
                             ("Nights", "\(n.nightCount)")])
            }
        case .bedtime:
            if let b = report.bedtime {
                ChartFooter([("Best recovery", "\(Int(b.best.meanRecovery.rounded()))"),
                             ("Range", "\(Int(b.spreadPts.rounded()))"),
                             ("Nights", "\(b.nightCount)")])
            }
        }
    }
}

// MARK: - Charts

struct SleepInsightChart: View {
    let kind: SleepInsightKind
    let report: SleepInsights.Report
    let large: Bool

    private var highlight: Color { StrandPalette.metricPurple }
    private var muted: Color { StrandPalette.textTertiary.opacity(0.45) }

    var body: some View {
        switch kind {
        case .latency: latencyChart
        case .sleepNeed: binChart(report.sleepNeed, label: SleepInsightFormat.duration)
        case .bedtime: binChart(report.bedtime, label: SleepInsightFormat.clock)
        }
    }

    /// 30 nights as dots, the typical value as a dashed rule, the recent median as a solid one.
    @ViewBuilder
    private var latencyChart: some View {
        if let l = report.latency {
            let recent = Set(l.recentDays)
            let recentDates = l.recentDays.map(SleepInsightFormat.date)
            Chart {
                ForEach(l.series, id: \.day) { p in
                    PointMark(x: .value("Night", SleepInsightFormat.date(p.day)), y: .value("Minutes", p.value))
                        .foregroundStyle(recent.contains(p.day) ? highlight : muted)
                        .symbolSize(large ? 40 : 18)
                }
                RuleMark(y: .value("Typical", l.typicalMin)).zoopReferenceRule()
                if let first = recentDates.first, let last = recentDates.last {
                    RuleMark(xStart: .value("From", first), xEnd: .value("To", last),
                             y: .value("Last 7 nights", l.recentMin))
                        .foregroundStyle(highlight)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .chartXAxis(large ? .automatic : .hidden)
            .chartYAxis(large ? .automatic : .hidden)
            .accessibilityLabel(Text("Time to fall asleep over the last \(l.nightCount) nights"))
        }
    }

    /// Average next-morning recovery per 30-minute bin, the named bin highlighted.
    @ViewBuilder
    private func binChart(_ b: SleepInsights.BinnedRecovery?, label: @escaping (Double) -> String) -> some View {
        if let b {
            Chart(b.bins) { bin in
                BarMark(x: .value("Bin", label(bin.lower)), y: .value("Recovery", bin.meanRecovery))
                    .foregroundStyle(bin.lower == b.best.lower && !b.isFlat ? highlight : muted)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .chartXAxis(large ? .automatic : .hidden)
            .chartYAxis(large ? .automatic : .hidden)
            .chartYScale(domain: 0...100)
        }
    }
}
#endif
