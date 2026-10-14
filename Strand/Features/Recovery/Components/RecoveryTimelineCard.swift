import SwiftUI
import StrandDesign

/// The calibration timeline: what unlocks after how many nights, and where the user is on it.
struct RecoveryTimelineCard: View {
    let steps: [RecoveryTimelineStep]

    var body: some View {
        ContentCard("zoop.recovery.timeline.title") {
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: ZoopSpacing.m) {
                        Image(systemName: symbol(step.status))
                            .font(ZoopType.body)
                            .foregroundStyle(step.status == .upcoming ? StrandPalette.textTertiary : StrandPalette.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                            Text(step.title).font(ZoopType.body)
                                .foregroundStyle(step.status == .upcoming ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                            Text(step.detail).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func symbol(_ status: RecoveryTimelineStep.Status) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .current: return "circle.dotted"
        case .upcoming: return "circle"
        }
    }
}
