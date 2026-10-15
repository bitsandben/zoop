import SwiftUI
import StrandDesign

/// Settings root: profile card, appearance block, then one row per page (Zoop 2.0 §3.9). Each page owns its own preferences and
/// state, so this view only orders the list. Every host wraps it in a `NavigationStack` (the More tab,
/// the Home avatar sheet, the macOS detail pane), which the value-pushed pages rely on.
struct SettingsView: View {
    var body: some View {
        ScreenScaffold(title: "Settings") {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                SettingsProfileHeader()
                SettingsLookBlock()
                ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, pages in
                    ListCard {
                        ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                            NavigationLink(value: page) {
                                ZoopIconRow(page.title, subtitle: page.subtitle, icon: page.icon)
                            }
                            .buttonStyle(.plain)
                            .listCardRow(isFirst: index == 0)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: SettingsPage.self) { page in
            page.destination
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
    }
}

/// The top-level pages. Order is frequency of use: what people change in their first week first,
/// developer tooling and the about text last.
enum SettingsPage: String, Hashable, CaseIterable, Identifiable {
    case profile, strap, notifications, appearance, features, data, advanced, about
    var id: String { rawValue }

    /// macOS already lists Notifications in its sidebar, so it is not repeated there.
    static var visible: [SettingsPage] {
        #if os(macOS)
        allCases.filter { $0 != .notifications }
        #else
        allCases
        #endif
    }

    /// The rows listed under the profile card and the appearance block. Profile has its own card, and
    /// Appearance (language, charts) follows the look block it extends.
    static var groups: [[SettingsPage]] {
        [[.strap, .notifications, .appearance, .features], [.data, .advanced, .about]]
            .map { $0.filter { visible.contains($0) } }
    }

    var title: LocalizedStringKey {
        switch self {
        case .profile: return "zoop.settings.profile.title"
        case .strap: return "Strap"
        case .notifications: return "zoop.settings.notifications.title"
        case .appearance: return "zoop.settings.language.title"
        case .features: return "Features"
        case .data: return "Data"
        case .advanced: return "Advanced"
        case .about: return "About Zoop"
        }
    }

    /// Kept to about 25 characters so the row never truncates (design audit, Settings #1).
    var subtitle: LocalizedStringKey {
        switch self {
        case .profile: return "zoop.settings.profile.subtitle"
        case .strap: return "zoop.settings.strap.subtitle"
        case .notifications: return "zoop.settings.notifications.subtitle"
        case .appearance: return "zoop.settings.language.subtitle"
        case .features: return "zoop.settings.features.subtitle"
        case .data: return "zoop.settings.data.subtitle"
        case .advanced: return "zoop.settings.advanced.subtitle"
        case .about: return "zoop.settings.about.subtitle"
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.fill"
        case .strap: return "dot.radiowaves.left.and.right"
        case .notifications: return "bell.fill"
        case .appearance: return "paintbrush.fill"
        case .features: return "square.grid.2x2.fill"
        case .data: return "externaldrive.fill"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .profile: SettingsProfilePage()
        case .strap: SettingsStrapPage()
        case .notifications: SettingsNotificationsDestination()
        case .appearance: SettingsAppearancePage()
        case .features: SettingsFeaturesPage()
        case .data: SettingsDataPage()
        case .advanced: SettingsAdvancedPage()
        case .about: SettingsAboutPage()
        }
    }
}

/// Alerts, reminders and wrist buzzes already have one screen on each platform, so the row opens it
/// rather than restating its toggles. On iOS that is Automations: the Notifications screen is macOS-only
/// and excluded from the iOS target.
private struct SettingsNotificationsDestination: View {
    var body: some View {
        #if os(macOS)
        NotificationSettingsView()
        #else
        AutomationsView()
        #endif
    }
}

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    return NavigationStack { SettingsView() }
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        .preferredColorScheme(.dark)
}
#endif
