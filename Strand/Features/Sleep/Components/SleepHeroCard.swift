import SwiftUI
import StrandDesign

/// Top of the Sleep screen: which night, the sleep score, time asleep and efficiency, and the sleep
/// window with its edit and "why" affordances.
struct SleepHeroCard: View {
    let page: SleepNightPage
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onSelect: (SleepMetric) -> Void
    let onEdit: () -> Void
    /// nil where the evidence sheet is not available (macOS).
    let onWhy: (() -> Void)?

    var body: some View {
        HeroCard {
            SleepNightNavigator(page: page, onOlder: onOlder, onNewer: onNewer)
            Button { onSelect(page.metrics.score) } label: { MetricHero(page.metrics.score.readout) }
                .buttonStyle(.plain)
            VStack(spacing: 0) {
                row(page.metrics.duration)
                row(page.metrics.efficiency)
                windowRow
            }
        }
    }

    private func row(_ metric: SleepMetric) -> some View {
        Button { onSelect(metric) } label: { MetricRow(metric.readout) }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
    }

    /// The clock window, its edit pencil and the way into "Why this sleep?".
    private var windowRow: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(page.night.onsetText) – \(page.night.wakeText)")
                    .font(ZoopType.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: ZoopSpacing.s)
                if let target = page.editTarget {
                    Button(action: onEdit) {
                        Image(systemName: target.userEdited ? "pencil.circle.fill" : "pencil.circle")
                            .font(ZoopType.headline)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(target.userEdited ? SleepStrings.editedTimes : SleepStrings.editTimes))
                }
            }
            if let onWhy, page.editTarget != nil {
                Button(action: onWhy) {
                    HStack {
                        Text(SleepStrings.whyThisSleep)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: ZoopSpacing.s)
                        Image(systemName: "chevron.right")
                            .font(ZoopType.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(SleepStrings.whyHint))
            }
        }
        .padding(.top, ZoopSpacing.s)
        .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
    }
}

/// "‹ Last night · Mon 13 → Tue 14 Oct ›". Older is to the left, newer to the right.
struct SleepNightNavigator: View {
    let page: SleepNightPage
    let onOlder: () -> Void
    let onNewer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            HStack(spacing: ZoopSpacing.s) {
                chevron("chevron.left", enabled: page.canGoOlder, label: SleepStrings.previousNight, action: onOlder)
                VStack(spacing: 2) {
                    Text(page.title)
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: page.spanLabel)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                chevron("chevron.right", enabled: page.canGoNewer, label: SleepStrings.nextNight, action: onNewer)
            }
            if !page.canGoOlder {
                Text(SleepStrings.noEarlierNight)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func chevron(_ symbol: String, enabled: Bool, label: LocalizedStringResource,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ZoopType.headline)
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}
