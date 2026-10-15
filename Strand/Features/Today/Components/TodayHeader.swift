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
#endif
