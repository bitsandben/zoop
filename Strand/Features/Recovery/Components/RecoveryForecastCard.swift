import SwiftUI
import StrandDesign

/// Tomorrow's estimated Recovery, always as a range (CONCEPT §5.1: never a single number).
struct RecoveryForecastCard: View {
    let forecast: RecoveryForecastContent
    @Environment(\.locale) private var locale

    var body: some View {
        ContentCard("zoop.recovery.forecast.title") {
            Text(verbatim: MetricUnit.percent.formatRange(forecast.low...forecast.high, locale: locale))
                .font(ZoopType.metric)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(RecoveryStrings.forecastCaption(sleep: MetricUnit.duration.format(forecast.sleepSeconds, locale: locale)))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
