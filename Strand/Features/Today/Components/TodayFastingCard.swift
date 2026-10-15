#if os(iOS)
import SwiftUI
import StrandDesign

/// Compact fasting card under "My Day" (today only): ring, elapsed time and the end button while a fast
/// runs; the planned next start and a start button for people who fasted this week; nothing otherwise.
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
            Task { await model.load(repo: repo) }
        }
    }

    @ViewBuilder
    private func card(_ state: FastingTodayState) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case .running(let r):
            row {
                NavigationLink(value: TabRoute.fasting) {
                    HStack(spacing: ZoopSpacing.m) {
                        FastingProgressRing(progress: r.progress, lineWidth: 6).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: r.elapsed).font(ZoopType.headline.monospacedDigit())
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(r.status).font(ZoopType.caption)
                                .foregroundStyle(r.goalReached ? StrandPalette.metricCyan : StrandPalette.textSecondary)
                        }
                        Spacer(minLength: ZoopSpacing.s)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ZoopButton("zoop.today.fasting.stop", kind: .secondary) { Task { await model.stop() } }
            }
        case .next(let n):
            row {
                NavigationLink(value: TabRoute.fasting) {
                    HStack(spacing: ZoopSpacing.s) {
                        Text(FastingTodayStrings.nextTitle).font(ZoopType.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(n.when).font(ZoopType.caption.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: ZoopSpacing.s)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ZoopButton("zoop.today.fasting.start", kind: .secondary) { Task { await model.start() } }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: ZoopSpacing.m, content: content)
            .padding(.horizontal, ZoopSpacing.cardPadding)
            .padding(.vertical, ZoopSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous).fill(StrandPalette.surfaceRaised))
    }
}
#endif
