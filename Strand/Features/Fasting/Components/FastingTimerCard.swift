#if os(iOS)
import SwiftUI
import StrandDesign

/// The hero: the two-phase ring, the clock of the running phase, and the one action that moves the
/// cycle on (end the fast → eating window; start the fast → fasting).
struct FastingTimerCard: View {
    let model: FastingModel
    let onStartEarlier: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HeroCard {
            // One tick per second is enough for an h:mm:ss clock and costs nothing when idle.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(model.timer(at: context.date))
            }
        }
    }

    @ViewBuilder
    private func content(_ state: FastingTimerState) -> some View {
        switch state {
        case .idle(let idle):
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                Text(idle.title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                if let detail = idle.detail {
                    Text(detail).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                startButtons
            }
        case .fasting(let f):
            VStack(spacing: ZoopSpacing.l) {
                ring(f.ring) {
                    clock(f.clock)
                    Text(f.ofGoal).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                    Text(f.status).font(ZoopType.caption)
                        .foregroundStyle(f.goalReached ? StrandPalette.metricCyan : StrandPalette.textSecondary)
                }
                VStack(spacing: ZoopSpacing.xs) {
                    Text(f.phase).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(FastingStrings.phaseNote).font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary).multilineTextAlignment(.center)
                }
                edges(f.since, f.goal)
                ZoopButton("zoop.fasting.stop", systemImage: "fork.knife", kind: .primary, fullWidth: true) {
                    Task { await model.stopFast() }
                }
                ZoopButton("zoop.fasting.edit", kind: .tertiary, fullWidth: true, action: onEdit)
            }
        case .eating(let e):
            VStack(spacing: ZoopSpacing.l) {
                ring(e.ring) {
                    clock(e.clock)
                    Text(FastingStrings.windowLeft).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Text(e.closesIn).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                edges(e.opened, e.closes)
                startButtons
            }
        }
    }

    private var startButtons: some View {
        VStack(spacing: ZoopSpacing.s) {
            ZoopButton("zoop.fasting.start", systemImage: "play.fill", kind: .primary, fullWidth: true) {
                Task { await model.startFast() }
            }
            ZoopButton("zoop.fasting.startEarlier", kind: .tertiary, fullWidth: true, action: onStartEarlier)
        }
    }

    private func ring<Center: View>(_ model: FastingRingModel, @ViewBuilder center: () -> Center) -> some View {
        ZStack {
            FastingCycleRing(model: model, lineWidth: 16)
            ForEach(model.markers, id: \.self) { MarkerTick(marker: $0, lineWidth: 16) }
            VStack(spacing: ZoopSpacing.xs, content: center)
        }
        .frame(width: 236, height: 236)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func clock(_ text: String) -> some View {
        Text(verbatim: text).font(ZoopType.metric).foregroundStyle(StrandPalette.textPrimary)
            .contentTransition(.numericText())
    }

    private func edges(_ leading: LocalizedStringResource, _ trailing: LocalizedStringResource) -> some View {
        HStack {
            Text(leading)
            Spacer(minLength: ZoopSpacing.s)
            Text(trailing)
        }
        .font(ZoopType.caption)
        .foregroundStyle(StrandPalette.textSecondary)
    }
}

/// A short tick across the ring plus its hour label just inside it. Hours since the last meal only.
private struct MarkerTick: View {
    let marker: FastingRingModel.Marker
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2 - lineWidth / 2
            let angle = Angle.degrees(marker.fraction * 360 - 90)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            Capsule()
                .fill(StrandPalette.textTertiary)
                .frame(width: 2, height: lineWidth + 4)
                .rotationEffect(angle + .degrees(90))
                .position(point(center, radius, angle))
            Text(verbatim: marker.label)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .position(point(center, radius - lineWidth - 12, angle))
        }
        .accessibilityHidden(true)
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Angle) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(a.radians)), y: c.y + r * CGFloat(sin(a.radians)))
    }
}
#endif
