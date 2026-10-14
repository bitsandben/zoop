import SwiftUI
import StrandDesign

/// About: version and updates, the explainers people come back to, limits, credits.
struct SettingsAboutPage: View {
    @State private var showWhatsNew = false
    @State private var showScoringGuide = false
    @State private var showHowZoopWorks = false
    @State private var showAppleWatchSetup = false

    var body: some View {
        SettingsPageScaffold(title: "About Zoop") {
            SettingsGroup {
                SettingsRow(label: "zoop.settings.about.version", isFirst: true) {
                    // The bundle's marketing version, so this can never drift from the installed build.
                    Text(verbatim: UpdateWatch.installedVersion)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                SettingsActionRow(label: "What's new", icon: "sparkles") { showWhatsNew = true }
                SettingsActionRow(label: "How Zoop works", icon: "questionmark.circle") { showHowZoopWorks = true }
                SettingsActionRow(label: "How your scores work", icon: "gauge.with.dots.needle.33percent") {
                    showScoringGuide = true
                }
                SettingsLinkRow(label: "About Apple Watch data", icon: "applewatch") {
                    AppleWatchAboutView(onStartSetup: { showAppleWatchSetup = true })
                }
                SettingsLinkRow(label: "Zoop Limitations", icon: "list.bullet.rectangle") { ZoopLimitationsView() }
            }
            SettingsUpdatesGroup()
            #if os(iOS)
            SettingsIPhoneNotes()
            #endif
            creditsGroup
        }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView(onClose: { showWhatsNew = false }) }
        .sheet(isPresented: $showScoringGuide) { ScoringGuideView(onClose: { showScoringGuide = false }) }
        .sheet(isPresented: $showHowZoopWorks) { HowZoopWorksView(onClose: { showHowZoopWorks = false }) }
        .sheet(isPresented: $showAppleWatchSetup) { AppleWatchSetupView(onClose: { showAppleWatchSetup = false }) }
    }

    private var creditsGroup: some View {
        SettingsGroup(title: "Built on", footer: Text("zoop.settings.about.disclaimer")) {
            Link(destination: URL(string: "https://github.com/ryanbr/noop")!) {
                SettingsChevronLabel(label: "Project home & source", icon: "chevron.left.forwardslash.chevron.right")
            }
            .listCardRow(isFirst: true)
            attribution("johnmiddleton12/my-whoop", note: String(localized: "WHOOP 4.0 protocol"))
            attribution("b-nnett/goose", note: String(localized: "WHOOP 5.0 protocol"))
        }
    }

    private func attribution(_ repo: String, note: String) -> some View {
        HStack(spacing: ZoopSpacing.s) {
            Text(verbatim: repo).font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: note).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .listCardRow()
    }
}

/// Update checks. A sideloaded build cannot update itself, so noticing and saying so is all that is
/// possible; the request reads only GitHub's public latest-version number (#1659).
private struct SettingsUpdatesGroup: View {
    @StateObject private var checker = UpdateChecker()
    /// Default from `UpdateAvailability.defaultEnabled` so the switch and the launch check agree on "unset".
    @AppStorage(UpdateWatch.Keys.enabled) private var autoCheck = UpdateAvailability.defaultEnabled
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsGroup(title: "Updates") {
            SettingsActionRow(label: "Check for updates", icon: "arrow.triangle.2.circlepath",
                              value: statusText, isFirst: true) {
                checker.check(currentVersion: UpdateWatch.installedVersion)
            }
            .disabled(checker.state == .checking)
            if case .available(let version, let url, _) = checker.state {
                SettingsRow(label: "Version \(version) is available") {
                    ZoopButton("Download", systemImage: "arrow.down.circle.fill", kind: .primary) { openURL(url) }
                }
            }
            SettingsToggleRow(label: "Check automatically", isOn: $autoCheck,
                              note: "zoop.settings.about.autoCheckNote")
        }
    }

    private var statusText: String? {
        switch checker.state {
        case .checking: return String(localized: "Checking…")
        case .upToDate(let version): return String(localized: "You're on the latest (\(version)).")
        case .failed: return String(localized: "Couldn't check. Try again.")
        case .idle, .available: return nil
        }
    }
}

#if os(iOS)
/// What to expect from a sideloaded iPhone build, with the live certificate expiry when it is readable.
private struct SettingsIPhoneNotes: View {
    private let expiry = IOSDiagnostics.capture().expiryDaysRemaining()

    var body: some View {
        SettingsGroup(title: "Using Zoop on iPhone") {
            if let days = expiry {
                Text(verbatim: expiryText(days))
                    .font(ZoopType.caption)
                    .foregroundStyle(days <= 3 ? StrandPalette.statusWarning : StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listCardRow(isFirst: true)
            }
            note("zoop.settings.about.sideloadNote", isFirst: expiry == nil)
            note("zoop.settings.about.unlockNote")
            note("zoop.settings.about.backgroundNote")
        }
    }

    private func note(_ key: LocalizedStringKey, isFirst: Bool = false) -> some View {
        Text(key)
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .listCardRow(isFirst: isFirst)
    }

    private func expiryText(_ days: Int) -> String {
        if days < 0 {
            let expired = -days
            return expired == 1
                ? String(localized: "This sideloaded build expired 1 day ago. Re-sign it to keep it running.")
                : String(localized: "This sideloaded build expired \(expired) days ago. Re-sign it to keep it running.")
        }
        return days == 1
            ? String(localized: "This sideloaded build expires in 1 day. Re-sign to keep it running.")
            : String(localized: "This sideloaded build expires in \(days) days. Re-sign to keep it running.")
    }
}
#endif
