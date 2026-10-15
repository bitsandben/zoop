#if os(iOS)
import SwiftUI
import StrandDesign

/// Follows one pull-to-sync from release to outcome. It only asks the strap for its history (the same
/// `syncNow()` the old pull called) and watches the shared live state; it never changes how the BLE
/// layer syncs.
@MainActor @Observable
final class TodayPullSync {
    private(set) var phase: PullSyncPhase = .idle
    /// Bumps once per finished pull, for the haptic.
    private(set) var finishedCount = 0

    /// How long the pull waits for an offload to begin after asking for one.
    private static let startWindow: Duration = .seconds(4)
    /// How long the pull follows a running offload before handing over to the live status.
    private static let followLimit: Duration = .seconds(90)
    private static let poll: Duration = .milliseconds(250)
    private static let resultHold: Duration = .seconds(3)

    func run(live: LiveState, ble: BLEManager, reload: () async -> Void) async {
        guard !phase.isBusy else { return }
        let startedAt = Date().timeIntervalSince1970
        var sawOffload = live.backfilling
        if live.historyReady {
            phase = .requesting
            ble.syncNow()
            sawOffload = await wait(upTo: Self.startWindow) { live.backfilling } || sawOffload
            if sawOffload { _ = await wait(upTo: Self.followLimit) { !live.backfilling } }
        }
        phase = .computing
        await reload()
        let outcome = PullSyncOutcome.resolve(status: live.syncStatus, sawOffload: sawOffload,
                                              pullStartedAt: startedAt)
        phase = .finished(outcome)
        finishedCount &+= 1
        try? await Task.sleep(for: Self.resultHold)
        if case .finished = phase { phase = .idle }
    }

    /// Polls `condition` until it holds or `limit` passes; returns whether it held.
    private func wait(upTo limit: Duration, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: Self.poll)
        }
        return condition()
    }

    /// The finish haptic: light for "up to date", a warning when the pull could not do its job.
    var haptic: SensoryFeedback? {
        switch phase {
        case .finished(.upToDate): return .impact(weight: .light)
        case .finished(.didNotStart), .finished(.status): return .warning
        default: return nil
        }
    }
}

/// A custom pull-to-sync for a scroll view: a ring fills as you pull, the label turns to "release" past
/// the threshold, and releasing there starts the sync. iOS 17 keeps the system `refreshable`.
struct PullToSync: ViewModifier {
    let isBusy: Bool
    let action: () async -> Void

    @State private var pull: CGFloat = 0
    @State private var topInset: CGFloat = 0
    @State private var dragging = false
    @State private var armed = false

    static let threshold: CGFloat = 84

    private struct Probe: Equatable {
        var pull: CGFloat
        var inset: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Probe.self) { geo in
                    Probe(pull: max(0, -(geo.contentOffset.y + geo.contentInsets.top)), inset: geo.contentInsets.top)
                } action: { _, new in
                    pull = new.pull
                    topInset = new.inset
                    if dragging, !isBusy { armed = new.pull >= Self.threshold }
                }
                .onScrollPhaseChange { old, new in
                    if new == .interacting {
                        dragging = true
                    } else if old == .interacting {
                        dragging = false
                        if armed, !isBusy { Task { await action() } }
                        armed = false
                    }
                }
                .overlay(alignment: .top) { indicator }
                .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, new in new }
        } else {
            content.refreshable { await action() }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        let progress = min(1, pull / Self.threshold)
        // Only while the finger is pulling: the bounce after release belongs to the header capsule.
        if dragging, !isBusy, pull > 6 {
            PullToSyncIndicator(progress: progress, armed: armed)
                .padding(.top, topInset + max(0, (pull - PullToSyncIndicator.height) / 2))
                .opacity(Double(min(1, pull / 32)))
                .allowsHitTesting(false)
        }
    }
}

/// The glyph and label shown in the gap a pull opens above the page.
struct PullToSyncIndicator: View {
    let progress: CGFloat
    let armed: Bool

    static let height: CGFloat = 52

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: ZoopSpacing.xs) {
            ZStack {
                Circle().stroke(StrandPalette.hairline, lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(armed ? StrandPalette.accent : StrandPalette.textSecondary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: armed ? "arrow.triangle.2.circlepath" : "arrow.down")
                    .font(ZoopType.icon(11, weight: .bold))
                    .foregroundStyle(armed ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 24, height: 24)
            Text(armed ? SyncCapsuleCopy.release : SyncCapsuleCopy.pull)
                .font(ZoopType.caption.weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .contentTransition(.opacity)
        }
        .frame(height: Self.height)
        .animation(ZoopMotion.gated(ZoopMotion.value, reduced: reduceMotion), value: armed)
        .accessibilityHidden(true)
    }
}
#endif
