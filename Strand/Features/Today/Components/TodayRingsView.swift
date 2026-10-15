#if os(iOS)
import SwiftUI
import StrandDesign

/// Sleep, Recovery and Strain as three squircle rings with the verdict under each, then the one
/// synthesis sentence. All three read as a plain number (no "%", no "of 100"): Sleep and Recovery on
/// 0–100, Strain on the user's Effort scale. A ring opens its screen (Strain: Training, whose load
/// cards explain the day; the legacy metric page printed "/100"); pressing and holding it
/// explains the number.
struct TodayRingsView: View {
    let content: TodayContent
    let onExplain: (MetricReadout) -> Void

    var body: some View {
        VStack(spacing: ZoopSpacing.l) {
            HStack(alignment: .top, spacing: ZoopSpacing.s) {
                cell(content.sleep, route: .sleep)
                cell(content.recovery, route: .recovery)
                cell(content.strain, route: .workouts, maxValue: content.strainRingMax,
                     target: content.strainTarget, targetHint: content.strainTargetCaption)
            }
            if let synthesis = content.synthesis {
                Text(synthesis)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, ZoopSpacing.s)
    }

    private func cell(_ readout: MetricReadout, route: TabRoute, maxValue: Double = 100,
                      target: ClosedRange<Double>? = nil, targetHint: LocalizedStringResource? = nil) -> some View {
        NavigationLink(value: route) {
            TodayRingCell(readout: readout, maxValue: maxValue, target: target, targetHint: targetHint)
        }
        .buttonStyle(LiquidPressStyle())
        .contextMenu {
            Button { onExplain(readout) } label: { Label { Text(TodayCopy.explain) } icon: { Image(systemName: "info.circle") } }
        }
    }
}

/// One ring: the readout's number inside (or the reason there is none), its label and verdict below.
struct TodayRingCell: View {
    let readout: MetricReadout
    var maxValue: Double = 100
    var target: ClosedRange<Double>?
    /// "Target 10–14": drawn as the arc on the ring, spoken as the hint.
    var targetHint: LocalizedStringResource?

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 100
    @State private var shownFraction: Double = 0

    private var fraction: Double {
        guard let v = readout.displayValue, maxValue > 0 else { return 0 }
        return min(max(v / maxValue, 0), 1)
    }

    var body: some View {
        let p = MetricPresentation(readout, locale: locale)
        VStack(spacing: ZoopSpacing.s) {
            ZStack {
                SquircleRing(fraction: shownFraction, tint: TodayTint.color(readout), lineWidth: diameter * 0.07)
                if let target {
                    SquircleShape()
                        .trim(from: target.lowerBound, to: target.upperBound)
                        .stroke(StrandPalette.textTertiary.opacity(0.6),
                                style: StrokeStyle(lineWidth: SquircleRing.themedLineWidth(diameter * 0.07) * 0.45,
                                                   lineCap: .round))
                        .padding(SquircleRing.themedLineWidth(diameter * 0.07) / 2)
                        .accessibilityHidden(true)
                }
                center(p)
                    .padding(.horizontal, diameter * 0.12)
            }
            // Shrinks below the text-scaled size when three rings do not fit across the screen.
            .frame(maxWidth: diameter, maxHeight: diameter)
            .aspectRatio(1, contentMode: .fit)
            VStack(spacing: 2) {
                Text(verbatim: p.label)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: p.number == nil ? reason(p) : p.verdict)
                    .font(ZoopType.caption)
                    .foregroundStyle(p.number == nil ? StrandPalette.textTertiary : TodayTint.verdictColor(readout))
                // A carried value keeps its colour and says which day it is from.
                if p.number != nil, case .stale(let since) = readout.confidence {
                    Text(TodayCopy.ringFrom(since.formatted(.dateTime.day().month(.abbreviated).locale(locale))))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: p.label))
        .accessibilityValue(Text(verbatim: p.accessibilityValue))
        .accessibilityHint(targetHint.map { Text($0) } ?? Text(verbatim: ""))
        .onAppear { roll() }
        .onChange(of: fraction) { _, _ in roll() }
    }

    @ViewBuilder
    private func center(_ p: MetricPresentation) -> some View {
        if let number = p.number {
            // The number alone: the three rings share one style, so Recovery drops its "%".
            Text(verbatim: number)
                .font(ZoopType.metric)
                .foregroundStyle(readout.isStale ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        // No number: the ring stays an empty track and the reason sits under it (see `reason`).
    }

    /// The short reason under an empty ring: "3 more nights" while calibrating, else "No data".
    private func reason(_ p: MetricPresentation) -> String {
        if case .unavailable(.calibrating) = readout.verdict { return p.verdict }
        return p.compactVerdict
    }

    /// Ring fill eases in once (0.6 s, §7.6) and stays still under Reduce Motion.
    private func roll() {
        guard !reduceMotion else { shownFraction = fraction; return }
        withAnimation(.easeOut(duration: 0.6)) { shownFraction = fraction }
    }
}

/// The metric colours of §7.5, read from a readout's tint. Recovery follows its score band.
enum TodayTint {
    /// A carried (stale) value keeps its metric colour, slightly dimmed; its date says how old it is.
    static func color(_ readout: MetricReadout) -> Color {
        let base = metricColor(readout)
        return readout.isStale ? base.opacity(0.55) : base
    }

    private static func metricColor(_ readout: MetricReadout) -> Color {
        switch readout.tint {
        case .recovery: return readout.displayValue.map(StrandPalette.recoveryColor) ?? StrandPalette.textTertiary
        case .strain: return StrandPalette.effortColor
        case .sleep: return StrandPalette.metricPurple
        case .stress: return StrandPalette.stressHigh
        case .fasting: return StrandPalette.metricCyan
        case .neutral: return StrandPalette.textPrimary
        }
    }

    /// Score bands carry their band colour; a range verdict is tinted only through the metric's
    /// polarity (better / worse), everything else stays neutral (calm by default).
    static func verdictColor(_ readout: MetricReadout) -> Color {
        if case .score = readout.verdict, let v = readout.displayValue { return StrandPalette.recoveryColor(v) }
        switch readout.assessment {
        case .better: return StrandPalette.textPositive
        case .worse: return StrandPalette.textWarning
        case .neutral: return StrandPalette.textSecondary
        }
    }
}
#endif
