#if os(iOS)
import SwiftUI
import StrandDesign

/// A metric that opens its own screen on tap and explains its number on press and hold.
struct TodayLinkedTile<Label: View>: View {
    let route: TabRoute
    let readout: MetricReadout?
    let onExplain: (MetricReadout) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        NavigationLink(value: route) { label() }
            .buttonStyle(LiquidPressStyle())
            .contextMenu {
                if let readout {
                    Button { onExplain(readout) } label: {
                        SwiftUI.Label { Text(TodayCopy.explain) } icon: { Image(systemName: "info.circle") }
                    }
                }
            }
    }
}

/// The Health monitor: whether last night's vitals sat in the user's own ranges, one tag per vital.
struct TodayHealthTile: View {
    let summary: TodayHealthSummary

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(TodayCopy.health)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(headline)
                .font(ZoopType.headline)
                .foregroundStyle(summary.outsideCount > 0 ? StrandPalette.statusWarning : StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: ZoopSpacing.xs) {
                ForEach(summary.vitals) { vital in
                    HStack(spacing: ZoopSpacing.xs) {
                        Image(systemName: vital.inRange ? "checkmark" : "exclamationmark")
                            .font(ZoopType.caption.weight(.bold))
                            .foregroundStyle(vital.inRange ? StrandPalette.textSecondary : StrandPalette.statusWarning)
                        Text(verbatim: vital.name)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(ZoopSpacing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous).fill(StrandPalette.surfaceRaised))
        .contentShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var headline: LocalizedStringResource {
        if summary.vitals.isEmpty { return TodayCopy.healthNoData }
        return summary.outsideCount == 0 ? TodayCopy.healthAllTypical : TodayCopy.healthOutside(summary.outsideCount)
    }
}

/// The morning check-in: the one-time invite, then the daily question until it is answered.
struct TodayCheckInCard: View {
    let state: TodayCheckIn
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onAnswer: () -> Void

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .invite:
            ContentCard {
                VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                    Text(TodayCopy.checkInInviteTitle).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(TodayCopy.checkInInviteBody).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ZoopSpacing.s) {
                        Button(action: onStart) { Text(TodayCopy.checkInStart) }
                            .buttonStyle(ZoopButtonStyle(.primary))
                        Button(action: onDismiss) { Text(TodayCopy.checkInNotNow) }
                            .buttonStyle(ZoopButtonStyle(.tertiary))
                    }
                }
            }
        case .ask:
            Button(action: onAnswer) {
                HStack(spacing: ZoopSpacing.m) {
                    Image(systemName: "face.smiling")
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(TodayCopy.checkInAskTitle)
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: ZoopSpacing.s)
                    Text(TodayCopy.checkInAskAction)
                        .font(ZoopType.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .padding(ZoopSpacing.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous)
                    .fill(StrandPalette.surfaceRaised))
            }
            .buttonStyle(LiquidPressStyle())
        }
    }
}

#endif
