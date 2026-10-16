#if os(iOS)
import SwiftUI
import StrandDesign

/// The transient sync pill at the very top of Today. It shows only while a sync, pull or analysis is in
/// flight, holds "up to date" for a moment, then fades out. A problem shows briefly too; the header's
/// warning glyph keeps it reachable afterwards. Overlay only: it never moves the page.
struct TodaySyncPill: View {
    var pull: PullSyncPhase
    var onOpenDevices: () -> Void

    @EnvironmentObject private var live: LiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: SyncCapsuleState?
    @State private var lastKind: Kind = .rest
    @State private var hideTask: Task<Void, Never>?

    /// Height of the pill; Today reserves this much above the header so the pill never covers it.
    static let height: CGFloat = 32

    private enum Kind { case busy, done, problem, rest }

    var body: some View {
        // The minute timeline keeps the resolved title current without a view-owned timer.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let current = SyncCapsuleState.resolve(status: live.syncStatus, pull: pull,
                                                   now: context.date.timeIntervalSince1970)
            ZStack {
                if let shown { pill(shown) }
            }
            .animation(ZoopMotion.gated(.easeInOut(duration: 0.3), reduced: reduceMotion), value: shown != nil)
            .onChange(of: current, initial: true) { _, new in update(new) }
        }
    }

    private func pill(_ state: SyncCapsuleState) -> some View {
        Button(action: onOpenDevices) {
            HStack(spacing: ZoopSpacing.s) {
                SyncRingGlyph(symbol: state.symbol, ring: state.ring, strong: state.celebrates, size: 22)
                Text(state.title)
                    .font(ZoopType.caption.weight(.medium))
                    .foregroundStyle(state.celebrates ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, ZoopSpacing.xs)
            .padding(.trailing, ZoopSpacing.m)
            .frame(height: Self.height)
            .background(Capsule(style: .continuous).fill(StrandPalette.surfaceRaised))
            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(Text(state.title))
        .transition(.opacity)
    }

    private func kind(_ state: SyncCapsuleState) -> Kind {
        if state.ring == .spinning { return .busy }
        if state.celebrates { return .done }
        if case .explain = state.tap, state.ring == .none { return .problem }
        return .rest
    }

    private func update(_ state: SyncCapsuleState) {
        let k = kind(state)
        defer { lastKind = k }
        switch k {
        case .busy:
            hideTask?.cancel()
            shown = state
        case .done:
            shown = state
            if lastKind != .done { hide(after: 2) }
        case .problem:
            shown = state
            if lastKind != .problem { hide(after: 4) }
        case .rest:
            // A sync that finished without the pull (the strap's own offload) still gets its moment.
            if lastKind == .busy, state.ring == .full { shown = state; hide(after: 2) }
            else if lastKind == .busy { hideTask?.cancel(); shown = nil }
        }
    }

    private func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            shown = nil
        }
    }
}
#endif
