#if os(iOS)
import SwiftUI
import StrandDesign

/// Compact fasting card under "My Day" (today only), one card for the whole cycle: ring, elapsed time and
/// goal while a fast runs; the eating window's countdown and "Start fast" while it is open; "Time to
/// fast" once it closed. Shown once fasting is turned on (a first fast or the schedule setting).
/// It owns its own model and minute tick, so a running fast never re-renders the rest of Today.
struct TodayFastingCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var model = FastingTodayModel()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            card(model.state(at: context.date))
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .onReceive(NotificationCenter.default.publisher(for: FastingLog.didChange)) { _ in
            Task { await model.reload() }
        }
    }

    @ViewBuilder
    private func card(_ state: FastingTodayState) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .shown(let c):
            HStack(spacing: ZoopSpacing.m) {
                NavigationLink(value: TabRoute.fasting) { summary(c) }.buttonStyle(.plain)
                if c.phase == .fasting {
                    ZoopButton("zoop.today.fasting.stop", kind: .secondary) { Task { await model.stop() } }
                } else {
                    ZoopButton("zoop.today.fasting.startFast", kind: .secondary) { Task { await model.start() } }
                }
            }
            .padding(.horizontal, ZoopSpacing.cardPadding)
            .padding(.vertical, ZoopSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
        }
    }

    private func summary(_ c: FastingTodayState.Card) -> some View {
        HStack(spacing: ZoopSpacing.m) {
            FastingProgressRing(progress: c.progress, lineWidth: 6,
                                tint: c.phase == .eating ? StrandPalette.metricAmber : StrandPalette.metricCyan)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.caption).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: c.headline).font(ZoopType.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                if let detail = c.detail {
                    Text(detail).font(ZoopType.caption)
                        .foregroundStyle(c.goalReached ? StrandPalette.metricCyan : StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: ZoopSpacing.s)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
