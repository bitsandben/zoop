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

    @EnvironmentObject private var profile: ProfileStore
    /// The tappable size of the header controls (HIG minimum 44 pt).
    private static let control: CGFloat = 44

    var body: some View {
        HStack(spacing: ZoopSpacing.s) {
            Button(action: onProfile) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: Self.control)
                    .frame(width: Self.control, height: Self.control)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(TodayCopy.profile))

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
    }
}

/// The one calm sync line under the header: the sync state from `SyncStatus` and the active device's
/// charge. Text only; a state that needs action turns amber. Tapping it opens the strap screen.
struct TodayStatusLine: View {
    let onTap: () -> Void
    @EnvironmentObject private var live: LiveState

    var body: some View {
        // The minute timeline keeps "Last sync 4 min ago" current while Today stays open.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let status = live.syncStatus
            Button(action: onTap) {
                HStack(spacing: ZoopSpacing.s) {
                    if case .syncing = status { ProgressView().controlSize(.mini) }
                    Text(line(status, now: context.date.timeIntervalSince1970))
                        .font(ZoopType.caption)
                        .foregroundStyle(status.tone == .warning ? StrandPalette.statusWarning
                                                                 : StrandPalette.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func line(_ status: SyncStatus, now: TimeInterval) -> String {
        var parts = [status.title(now: now)]
        if let battery = batteryText { parts.append(battery) }
        return parts.joined(separator: " · ")
    }

    private var batteryText: String? {
        let display = StrapBatteryDisplay.resolve(
            activeIsWhoop: live.activeIsWhoop, connected: live.connected, batteryPct: live.batteryPct,
            charging: live.charging, ringPct: live.ouraBatteryPct, ringCharging: live.ouraWearState == .charging)
        switch display {
        case .charge(let pct, let charging, _):
            if charging { return String(localized: TodayCopy.batteryCharging) }
            let percent = (pct / 100).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))
            return String(localized: TodayCopy.battery(percent))
        case .pending(true):
            return String(localized: TodayCopy.batteryCharging)
        case .pending(false), .offline, .notActiveDevice:
            return nil
        }
    }
}
#endif
