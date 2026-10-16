#if os(iOS)
import SwiftUI
import StrandDesign

/// Profile on the left, the day navigator in the middle, quick actions on the right.
struct TodayHeader: View {
    let dayOffset: Int
    let today: Date
    let onSelectDay: (Int) -> Void
    let onProfile: () -> Void
    let onQuickActions: () -> Void
    var pull: PullSyncPhase = .idle
    var onOpenDevices: (() -> Void)?
    var onRetry: (() -> Void)?

    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var live: LiveState
    @State private var explaining: SyncExplanation?
    /// The tappable size of the header controls (HIG minimum 44 pt).
    private static let control: CGFloat = 44

    var body: some View {
        HStack(spacing: ZoopSpacing.s) {
            avatar

            DayNavBar(selectedOffset: dayOffset, today: today, style: .pill, onSelect: onSelectDay)
                .frame(maxWidth: .infinity)

            Button(action: onQuickActions) {
                Image(systemName: "plus")
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.primaryButtonText)
                    .frame(width: Self.control, height: Self.control)
                    .background(SquircleShape().fill(StrandPalette.primaryButtonFill))
                    .contentShape(SquircleShape())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel(Text(TodayCopy.quickActions))
        }
        .sheet(item: $explaining) { explanation in
            SyncExplanationSheet(explanation: explanation, onRetry: onRetry, onOpenDevices: onOpenDevices)
                .presentationDetents([.medium])
        }
    }

    // MARK: Avatar, battery ring and sync warning

    private var battery: StrapBatteryDisplay? { live.knownBattery }

    /// A sync problem worth a standing marker: Bluetooth off, a stalled sync, a pull that never started.
    private var problem: SyncExplanation? {
        let state = SyncCapsuleState.resolve(status: live.syncStatus, pull: pull)
        guard case .explain(let explanation) = state.tap, state.ring == .none else { return nil }
        return explanation
    }

    private var avatar: some View {
        Button(action: onProfile) {
            ProfileAvatarView(imageData: profile.avatarImageData, size: Self.control - 8)
                .frame(width: Self.control, height: Self.control)
                .overlay { batteryRing }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { warningGlyph }
        .accessibilityLabel(Text(TodayCopy.profile))
        .accessibilityValue(Text(battery.map(BatteryLabel.text) ?? ""))
    }

    /// The strap charge as an arc around the avatar; the warning colour below 20 % (not while charging).
    @ViewBuilder
    private var batteryRing: some View {
        if case .charge(let pct, let charging, _)? = battery {
            let low = pct < 20 && !charging
            ZStack {
                Circle().stroke(StrandPalette.hairline, lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.02, min(1, pct / 100)))
                    .stroke(low ? StrandPalette.statusWarning : (charging ? StrandPalette.accent : StrandPalette.textTertiary),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1.25)
        }
    }

    @ViewBuilder
    private var warningGlyph: some View {
        if let problem {
            Button { explaining = problem } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(ZoopType.icon(11, weight: .bold))
                    .foregroundStyle(StrandPalette.statusWarning)
                    .padding(4)
                    .background(Circle().fill(StrandPalette.surfaceRaised))
                    .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 10, y: -10)
            .accessibilityLabel(Text("zoop.sync.problem"))
        }
    }
}
#endif
