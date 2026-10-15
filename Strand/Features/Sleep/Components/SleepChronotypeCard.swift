#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Sleep type card (Sleep screen)
//
// The type leads (early / intermediate / late), one sentence says what it means, a scale shows where
// the free-day mid-sleep sits, and three rows carry the habitual mid-sleep, the timing variation and the
// social jetlag. Tapping opens the explainer with every night's mid-sleep, the method and what helps.
// Draws nothing under seven nights: the regularity row already shows the calibration countdown.

struct SleepChronotypeSection: View {
    @EnvironmentObject private var repo: Repository
    @State private var content: SleepChronotypeContent?
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            if let content {
                SleepSectionTitle(SleepChronotypeStrings.title)
                Button { showsDetail = true } label: { SleepChronotypeCard(content: content) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the details"))
            }
        }
        .task(id: repo.refreshSeq) {
            content = SleepChronotypeContent.load(sleeps: repo.sleeps, days: repo.days)
        }
        .sheet(isPresented: $showsDetail) {
            if let content {
                SleepChronotypeSheet(content: content).presentationDetents([.medium, .large])
            }
        }
    }
}

struct SleepChronotypeCard: View {
    let content: SleepChronotypeContent

    var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                    Text(content.typeName).font(ZoopType.metric).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: ZoopSpacing.s)
                    Image(systemName: "chevron.right")
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(content.meaning)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SleepChronotypeScale(midSleepSignedMin: content.profile.chronotypeMidSleepSignedMin,
                                     clock: content.typeMidSleep)
                VStack(spacing: 0) {
                    ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
                        SleepChronotypeRow(row: row, isFirst: index == 0)
                    }
                }
                Text(content.shiftSentence)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                SleepChronotypeSample(content: content)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SleepChronotypeRow: View {
    let row: SleepChronotypeContent.Row
    let isFirst: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.m) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(row.label).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                Text(row.note)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZoopSpacing.s)
            VStack(alignment: .trailing, spacing: ZoopSpacing.xs) {
                Text(verbatim: row.value)
                    .font(ZoopType.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                if let verdict = row.verdict {
                    Text(verdict).font(ZoopType.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .padding(.vertical, ZoopSpacing.s)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SleepChronotypeSample: View {
    let content: SleepChronotypeContent

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(content.sample)
            if let building = content.building { Text(building) }
        }
        .font(ZoopType.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Early | intermediate | late on a 01:00–07:00 mid-sleep axis, the user's free-day mid-sleep marked.
struct SleepChronotypeScale: View {
    let midSleepSignedMin: Double
    let clock: String
    @ScaledMetric(relativeTo: .caption) private var track: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var marker: CGFloat = 14

    static let axis: ClosedRange<Double> = 60...420

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset).frame(height: track)
                    Capsule().fill(StrandPalette.metricPurple.opacity(0.25))
                        .frame(width: max(0, x(Chronotype.lateFromMin, w) - x(Chronotype.earlyBeforeMin, w)), height: track)
                        .offset(x: x(Chronotype.earlyBeforeMin, w))
                    Circle().fill(StrandPalette.metricPurple)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 2))
                        .frame(width: marker, height: marker)
                        .offset(x: x(midSleepSignedMin, w) - marker / 2)
                }
                .frame(height: marker)
            }
            .frame(height: marker)
            HStack {
                Text(SleepChronotypeStrings.scaleEarly)
                Spacer()
                Text(SleepChronotypeStrings.typeMidSleep(clock))
                Spacer()
                Text(SleepChronotypeStrings.scaleLate)
            }
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SleepChronotypeStrings.typeMidSleep(clock)))
    }

    private func x(_ minutes: Double, _ width: CGFloat) -> CGFloat {
        let a = Self.axis
        let clamped = min(max(minutes, a.lowerBound), a.upperBound)
        return CGFloat((clamped - a.lowerBound) / (a.upperBound - a.lowerBound)) * width
    }
}

// MARK: - Explainer sheet

struct SleepChronotypeSheet: View {
    let content: SleepChronotypeContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                    Text(content.meaning)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ContentCard {
                        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                            Text(SleepChronotypeStrings.chart).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                            SleepChronotypeChart(profile: content.profile).frame(height: ZoopMetrics.chartHeight)
                            Text(content.shiftSentence)
                                .font(ZoopType.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section(SleepChronotypeStrings.whatTitle, SleepChronotypeStrings.what)
                    section(SleepChronotypeStrings.adviceTitle, content.advice)
                    VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                        section(SleepChronotypeStrings.methodTitle, SleepChronotypeStrings.method)
                        Text(verbatim: "Roenneberg et al., 2004; Wittmann et al., 2006")
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        SleepChronotypeSample(content: content)
                    }
                }
                .padding(ZoopSpacing.gutter)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(content.typeName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func section(_ title: LocalizedStringResource, _ text: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Every night's mid-sleep, free days in the sleep colour, workdays muted, each group's mean dashed.
struct SleepChronotypeChart: View {
    let profile: Chronotype.Profile

    var body: some View {
        Chart {
            ForEach(profile.series, id: \.day) { p in
                PointMark(x: .value("Night", SleepInsightFormat.date(p.day)), y: .value("Mid-sleep", p.midSleepSignedMin))
                    .foregroundStyle(by: .value("Day", String(localized: p.isFreeDay ? SleepChronotypeStrings.freeDay
                                                                                       : SleepChronotypeStrings.workday)))
                    .symbolSize(36)
            }
            if let free = profile.freeDayMidSleepSignedMin {
                RuleMark(y: .value("Free days", free)).zoopReferenceRule(color: StrandPalette.metricPurple)
            }
            if let work = profile.workdayMidSleepSignedMin {
                RuleMark(y: .value("Workdays", work)).zoopReferenceRule()
            }
        }
        .chartForegroundStyleScale([
            String(localized: SleepChronotypeStrings.freeDay): StrandPalette.metricPurple,
            String(localized: SleepChronotypeStrings.workday): StrandPalette.textTertiary,
        ])
        .chartLegend(position: .bottom, alignment: .leading)
        .zoopYAxis(format: SleepInsightFormat.clock)
        .zoopDayXAxis(days: profile.series.count)
        .accessibilityLabel(Text(SleepChronotypeStrings.chart))
    }
}
#endif
