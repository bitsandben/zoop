import SwiftUI

// MARK: - ZoopCalibratingState (CONCEPT §5.2, §5.5)
//
// Shown while a metric is still collecting the nights its personal baseline needs. Instead of a number
// it says what is happening, how far along it is and what unlocks when: a progress bar plus a short
// timeline of milestones ("Recovery · 4 nights", "Personal HRV range · 14 nights"). The counts come
// from the engine's confidence; the template only lays them out.

public struct ZoopCalibratingState: View {

    /// One unlock on the way to a calibrated metric.
    public struct Milestone: Identifiable {
        public let nights: Int
        let title: Text
        public var id: Int { nights }

        public init(nights: Int, title: LocalizedStringKey) {
            self.nights = nights
            self.title = Text(title)
        }

        @_disfavoredOverload
        public init(nights: Int, title: LocalizedStringResource) {
            self.nights = nights
            self.title = Text(title)
        }
    }

    private let title: Text
    private let message: Text
    private let nightsCollected: Int
    private let milestones: [Milestone]
    private let tint: Color
    private let style: ZoopEmptyState.Style
    @ScaledMetric(relativeTo: .caption) private var trackHeight: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var nodeSize: CGFloat = 14

    /// `milestones` are sorted by night count; the last one is the fully calibrated state.
    /// `tint` is the metric's colour (§7.5); neutral by default.
    public init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        nightsCollected: Int,
        milestones: [Milestone],
        tint: Color = StrandPalette.textPrimary,
        style: ZoopEmptyState.Style = .card
    ) {
        self.title = Text(title)
        self.message = Text(message)
        self.nightsCollected = max(nightsCollected, 0)
        self.milestones = milestones.sorted { $0.nights < $1.nights }
        self.tint = tint
        self.style = style
    }

    @_disfavoredOverload
    public init(
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        nightsCollected: Int,
        milestones: [Milestone],
        tint: Color = StrandPalette.textPrimary,
        style: ZoopEmptyState.Style = .card
    ) {
        self.title = Text(title)
        self.message = Text(message)
        self.nightsCollected = max(nightsCollected, 0)
        self.milestones = milestones.sorted { $0.nights < $1.nights }
        self.tint = tint
        self.style = style
    }

    /// Not copy: the slash between "5" and "14 nights" reads the same in every locale.
    private static let countSeparator = "\u{2009}/\u{2009}"

    private var nightsNeeded: Int { max(milestones.last?.nights ?? 1, 1) }

    public var body: some View {
        switch style {
        case .card: ContentCard { content }
        case .plain: content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.l) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                title.font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                message.font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            progress
            if !milestones.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                        row(milestone, isLast: index == milestones.count - 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        let fraction = min(Double(nightsCollected) / Double(nightsNeeded), 1)
        return VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(tint)
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? trackHeight : 0))
                }
            }
            .frame(height: trackHeight)
            // "5 / 14 nights": the count is a plain locale-formatted number, the unit an existing plural.
            (Text(verbatim: min(nightsCollected, nightsNeeded).formatted() + Self.countSeparator)
                + Text(MetricStrings.nights(nightsNeeded)))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ milestone: Milestone, isLast: Bool) -> some View {
        let reached = nightsCollected >= milestone.nights
        return HStack(alignment: .top, spacing: ZoopSpacing.m) {
            VStack(spacing: 0) {
                node(reached: reached)
                if !isLast {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: nodeSize)
            VStack(alignment: .leading, spacing: 2) {
                milestone.title
                    .font(ZoopType.body)
                    .foregroundStyle(reached ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                Text(reached ? TemplateStrings.reached
                             : MetricStrings.nightsLeft(milestone.nights - nightsCollected))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, isLast ? 0 : ZoopSpacing.l)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func node(reached: Bool) -> some View {
        if reached {
            Circle().fill(tint)
                .overlay(Image(systemName: "checkmark").font(.caption2.weight(.bold))
                    .foregroundStyle(StrandPalette.surfaceRaised))
                .frame(width: nodeSize, height: nodeSize)
        } else {
            Circle().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 2)
                .frame(width: nodeSize, height: nodeSize)
        }
    }
}

#if DEBUG
#Preview("Calibrating") {
    ScrollView {
        ZoopCalibratingState(
            title: "Learning your baseline",
            message: "Wear the strap at night; each night sharpens your personal range.",
            nightsCollected: 5,
            milestones: [
                .init(nights: 4, title: "First Recovery score"),
                .init(nights: 7, title: "Provisional personal range"),
                .init(nights: 14, title: "Fully calibrated"),
            ],
            tint: StrandPalette.recovery100)
        .padding(ZoopSpacing.gutter)
    }
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
