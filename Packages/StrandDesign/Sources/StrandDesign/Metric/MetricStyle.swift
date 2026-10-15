import SwiftUI

// MARK: - Shared pieces of the Metric* views
//
// Colours come from StrandPalette tokens only, which already carry both themes and appearances.

enum MetricStyle {

    /// The metric's data colour. A stale readout drops to tertiary so an old number never looks current.
    static func tint(_ readout: MetricReadout) -> Color {
        if readout.isStale { return StrandPalette.textTertiary }
        switch readout.tint {
        case .neutral: return StrandPalette.textPrimary
        case .recovery: return recoveryColor(readout.verdict)
        case .strain: return StrandPalette.effortColor
        case .sleep: return StrandPalette.metricPurple
        case .stress: return StrandPalette.stressHigh
        case .fasting: return StrandPalette.metricCyan
        }
    }

    /// Score bands carry the green / amber / red colour; a range verdict is tinted only through the
    /// metric's polarity (better positive, worse warning), because "above" is good for HRV and bad for
    /// resting heart rate.
    static func verdictColor(_ readout: MetricReadout) -> Color {
        if readout.isStale { return StrandPalette.textTertiary }
        if case .score = readout.verdict { return recoveryColor(readout.verdict) }
        if case .unavailable = readout.verdict { return StrandPalette.textSecondary }
        switch readout.assessment {
        case .better: return StrandPalette.textPositive
        case .worse: return StrandPalette.textWarning
        case .neutral: return StrandPalette.textPrimary
        }
    }

    static func valueColor(_ readout: MetricReadout) -> Color {
        readout.isStale ? StrandPalette.textTertiary : StrandPalette.textPrimary
    }

    private static func recoveryColor(_ verdict: MetricVerdict) -> Color {
        guard case .score(let band) = verdict else { return StrandPalette.recovery100 }
        switch band {
        case .high: return StrandPalette.recovery100
        case .medium: return StrandPalette.recovery055
        case .low: return StrandPalette.recovery000
        }
    }
}

/// Number with its unit on one baseline; concatenated `Text` wraps as one run at large sizes instead of clipping the unit.
struct MetricValueText: View {
    let presentation: MetricPresentation
    let numberFont: Font
    let unitFont: Font
    let color: Color

    var body: some View {
        if let number = presentation.number {
            (Text(verbatim: number).font(numberFont)
                + Text(verbatim: presentation.unit.map { "\u{00A0}" + $0 } ?? "").font(unitFont))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "▲ +8 ms vs. typical". The arrow appears only past the smallest worthwhile change.
struct MetricDeltaText: View {
    let presentation: MetricPresentation

    var body: some View {
        if let delta = presentation.delta {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let symbol = arrow {
                    Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
                }
                Text(verbatim: delta).fixedSize(horizontal: false, vertical: true)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var arrow: String? {
        switch presentation.deltaDirection {
        case .up: return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case .flat: return nil
        }
    }
}

/// Verdict word, then the confidence note when there is one.
struct MetricVerdictText: View {
    let readout: MetricReadout
    let presentation: MetricPresentation
    var font: Font = StrandFont.headline
    /// Small container: the short unavailable wording, shrunk to fit on at most two lines.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: compact ? presentation.compactVerdict : presentation.verdict)
                .font(font)
                .foregroundStyle(MetricStyle.verdictColor(readout))
                .lineLimit(compact ? 2 : nil)
                .minimumScaleFactor(compact ? 0.7 : 1)
                .fixedSize(horizontal: false, vertical: true)
            if let note = presentation.confidenceNote {
                Text(verbatim: note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// One VoiceOver element ("HRV", "62 milliseconds, Above your range"); the meaning is the hint, and
    /// delta and range sit in the More Content rotor so the first swipe stays short.
    func metricAccessibility(_ p: MetricPresentation) -> some View {
        self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: p.label))
            .accessibilityValue(Text(verbatim: p.accessibilityValue))
            .accessibilityHint(Text(verbatim: p.meaning))
            .modifier(MetricCustomContent(presentation: p))
    }
}

private struct MetricCustomContent: ViewModifier {
    let presentation: MetricPresentation

    func body(content: Content) -> some View {
        content
            .accessibilityCustomContent(Text(MetricStrings.change), Text(verbatim: presentation.delta ?? ""))
            .accessibilityCustomContent(Text(MetricStrings.range), Text(verbatim: presentation.range ?? ""))
    }
}
