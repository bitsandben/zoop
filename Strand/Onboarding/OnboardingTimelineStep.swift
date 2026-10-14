import SwiftUI
import UserNotifications
import StrandDesign

// MARK: - Step 9: What to expect
//
// The calibration timeline, so an empty Recovery on day one reads as "not yet", not "broken". The
// milestones follow the minimum-data table (concept §5.5): strain and heart rate from the first hour,
// sleep after one night, a provisional Recovery and first personal ranges after four, stable ranges
// after fourteen, check-in personalisation after 28 answers.

struct OnboardingTimelineStep: View {
    private struct Milestone: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        var whenKey: String { "zoop.onboarding.timeline." + id + ".when" }
        var whatKey: String { "zoop.onboarding.timeline." + id + ".what" }
    }

    private let milestones: [Milestone] = [
        Milestone(id: "day1", icon: "heart.fill", tint: StrandPalette.effortColor),
        Milestone(id: "night4", icon: "circle.dashed", tint: StrandPalette.recovery100),
        Milestone(id: "night14", icon: "chart.line.uptrend.xyaxis", tint: StrandPalette.recovery100),
        Milestone(id: "day28", icon: "slider.horizontal.3", tint: StrandPalette.accent),
    ]

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.timeline.title"),
                       subtitle: String(localized: "zoop.onboarding.timeline.subtitle")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                ListCard {
                    ForEach(Array(milestones.enumerated()), id: \.element.id) { i, m in
                        row(m, isLast: i == milestones.count - 1)
                            .padding(.top, i == 0 ? ZoopSpacing.l : 0)
                            .padding(.bottom, i == milestones.count - 1 ? ZoopSpacing.l : 0)
                    }
                }
                OnboardingNotificationRow()
            }
        }
    }

    /// One milestone: a dot on a vertical line, the "when" as a headline, the "what" underneath.
    private func row(_ m: Milestone, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: ZoopSpacing.m) {
            VStack(spacing: 0) {
                OnboardingIconWell(icon: m.icon, tint: m.tint, size: 36)
                if !isLast {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(m.whenKey))
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(LocalizedStringKey(m.whatKey))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, ZoopSpacing.s)
            .padding(.bottom, isLast ? 0 : ZoopSpacing.l)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Optional notification permission, offered with the one notification a new user gets by default
/// (the morning recovery note, `GoodMorningNotifier`, default on). Asking only on tap keeps it at the
/// point of need; every other alert still asks from its own toggle.
private struct OnboardingNotificationRow: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Group {
            if status == .notDetermined {
                ListCard {
                    VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                        OnboardingInfoRow(icon: "bell", title: String(localized: "zoop.onboarding.notify.title"),
                                          message: String(localized: "zoop.onboarding.notify.body"))
                        Button("zoop.onboarding.notify.allow", action: request)
                            .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
                    }
                    .listCardRow(isFirst: true)
                }
            } else if status == .authorized || status == .provisional {
                OnboardingStatusLine(text: String(localized: "zoop.onboarding.notify.on"),
                                     tint: StrandPalette.statusPositive)
            }
            // Denied: say nothing. The toggles that need it explain the Settings path themselves.
        }
        .task { await refresh() }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func request() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
    }
}
