#if os(iOS)
import SwiftUI
import StrandDesign

/// The hero: live ring, clock, phase guide, and the start / stop actions.
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
        case .idle(let lastEnded):
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                Text(FastingStrings.notFasting)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let lastEnded {
                    Text(lastEnded).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                ZoopButton("zoop.fasting.start", systemImage: "play.fill", kind: .primary, fullWidth: true) {
                    Task { await model.startFast() }
                }
                ZoopButton("zoop.fasting.startEarlier", kind: .tertiary, fullWidth: true, action: onStartEarlier)
            }
        case .running(let r):
            VStack(spacing: ZoopSpacing.l) {
                FastingRing(state: r).frame(width: 236, height: 236)
                    .frame(maxWidth: .infinity)
                VStack(spacing: ZoopSpacing.xs) {
                    Text(r.phase).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(FastingStrings.phaseNote).font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Text(r.since)
                    Spacer(minLength: ZoopSpacing.s)
                    Text(r.goal)
                }
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                ZoopButton("zoop.fasting.stop", systemImage: "stop.fill", kind: .primary, fullWidth: true) {
                    Task { await model.stopFast() }
                }
                ZoopButton("zoop.fasting.edit", kind: .tertiary, fullWidth: true, action: onEdit)
            }
        }
    }
}

/// Progress ring with clock marks. The marks are hours since the last meal, nothing more (§3.8).
private struct FastingRing: View {
    let state: FastingTimerState.Running
    private let lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            FastingProgressRing(progress: state.progress, lineWidth: lineWidth)
            ForEach(state.markers, id: \.self) { marker in
                MarkerTick(marker: marker, lineWidth: lineWidth)
            }
            VStack(spacing: ZoopSpacing.xs) {
                Text(verbatim: state.clock)
                    .font(ZoopType.metric)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text(state.ofGoal).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                Text(state.status)
                    .font(ZoopType.caption)
                    .foregroundStyle(state.goalReached ? StrandPalette.metricCyan : StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A short tick across the ring plus its hour label just inside it.
private struct MarkerTick: View {
    let marker: FastingTimerState.Marker
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
