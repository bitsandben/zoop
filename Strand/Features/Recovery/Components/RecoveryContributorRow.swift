import SwiftUI
import StrandDesign

/// One contributor: the shared `MetricRow` plus a leading mark for which way it pushed the score.
/// The mark is an icon, not a tinted chip, and the direction is also spoken for VoiceOver.
struct RecoveryContributorRow: View {
    let item: RecoveryContributor
    let isFirst: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: ZoopSpacing.s) {
                Image(systemName: symbol)
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 20)
                    .accessibilityLabel(Text(effectLabel))
                MetricRow(item.readout)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
        }
    }

    private var symbol: String {
        switch item.effect {
        case .raises: return "arrow.up.right"
        case .lowers: return "arrow.down.right"
        case .neutral: return "minus"
        }
    }

    // Colour only restates the arrow; amber rather than red because one low input is not an alarm.
    private var color: Color {
        switch item.effect {
        case .raises: return StrandPalette.recovery100
        case .lowers: return StrandPalette.recovery055
        case .neutral: return StrandPalette.textTertiary
        }
    }

    private var effectLabel: LocalizedStringResource {
        switch item.effect {
        case .raises: return RecoveryStrings.effectRaises
        case .lowers: return RecoveryStrings.effectLowers
        case .neutral: return RecoveryStrings.effectNeutral
        }
    }
}
