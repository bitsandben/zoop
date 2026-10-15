import SwiftUI
import StrandDesign

/// Movement bouts, restless time and the longest still stretch of the night, each opening its
/// explainer. A night with thin motion data says so under the rows.
struct SleepRestlessCard: View {
    let content: SleepRestlessContent
    let onSelect: (SleepMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            SleepSectionTitle(SleepRestlessStrings.card)
            ListCard {
                ForEach(Array(content.metrics.enumerated()), id: \.element.id) { index, metric in
                    SleepMetricRowButton(metric: metric, isFirst: index == 0, onSelect: onSelect)
                }
            }
            if content.lowConfidence {
                Text(SleepRestlessStrings.lowNote)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZoopSpacing.xs)
            }
        }
    }
}
