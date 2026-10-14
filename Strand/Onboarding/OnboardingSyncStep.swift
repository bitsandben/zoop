import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

// MARK: - Step 8: First sync and optional history
//
// No progress bar here on purpose: how long the first offload takes depends on how many days the
// strap holds, which Zoop does not know before it asks, and a made-up ETA is a promise it cannot keep.
// The live sync state belongs to the Today sync line once the flow is done.

struct OnboardingSyncStep: View {
    let hasStrap: Bool
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        OnboardingPage(title: String(localized: hasStrap ? "zoop.onboarding.sync.title" : "zoop.onboarding.sync.titleNoStrap"),
                       subtitle: String(localized: hasStrap ? "zoop.onboarding.sync.subtitle" : "zoop.onboarding.sync.subtitleNoStrap")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                if hasStrap {
                    ListCard {
                        OnboardingInfoRow(icon: "arrow.triangle.2.circlepath",
                                          title: String(localized: "zoop.onboarding.sync.history.title"),
                                          message: String(localized: "zoop.onboarding.sync.history.body"))
                            .listCardRow(isFirst: true)
                        OnboardingInfoRow(icon: "iphone.radiowaves.left.and.right",
                                          title: String(localized: "zoop.onboarding.sync.leave.title"),
                                          message: String(localized: "zoop.onboarding.sync.leave.body"))
                            .listCardRow()
                    }
                }
                importSection
                #if os(iOS)
                OnboardingAppleHealthRow()
                #endif
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importTarget.allowedContentTypes,
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importTarget {
            case .whoop:       model.importWhoop(url: url)
            case .appleHealth: model.importAppleHealth(url: url)
            }
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text("zoop.onboarding.sync.import")
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            ListCard {
                importRow(.whoop, icon: "tray.and.arrow.down",
                          title: model.isImporting(.whoop) ? String(localized: "Importing…")
                                                           : String(localized: "Import WHOOP export"))
                    .listCardRow(isFirst: true)
                importRow(.appleHealth, icon: "heart.text.square",
                          title: model.isImporting(.appleHealth) ? String(localized: "Working…")
                                                                 : String(localized: "Import Apple Health export"))
                    .listCardRow()
            }
            Text("zoop.onboarding.sync.import.note")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = lastSummary {
                // Styled off the typed failure flag, not a substring match, so real errors read as warnings.
                Text(summary)
                    .font(ZoopType.caption)
                    .foregroundStyle(model.importFailed(importKind) ? StrandPalette.statusWarning
                                                                    : StrandPalette.statusPositive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func importRow(_ target: ImportTarget, icon: String, title: String) -> some View {
        Button {
            importTarget = target
            showingImporter = true
        } label: {
            HStack(spacing: ZoopSpacing.m) {
                OnboardingIconWell(icon: icon)
                Text(title)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.hasActiveImport)
        .opacity(model.hasActiveImport ? 0.5 : 1)
    }

    private var importKind: DataSourceImportKind {
        importTarget == .whoop ? .whoop : .appleHealth
    }

    private var lastSummary: String? {
        importTarget == .whoop ? model.whoopImportSummary : model.appleHealthImportSummary
    }

    private enum ImportTarget {
        case whoop, appleHealth

        /// `.folder` is a macOS-only affordance; on iOS it greys out the .zip in Files (#179).
        var allowedContentTypes: [UTType] {
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            }
        }
    }
}

#if os(iOS)
/// Optional live Apple Health link, asked here because this is where the user decides where data comes
/// from. Same calls as Apple Health › Enable (`AppleHealthView`); hidden where it cannot work.
private struct OnboardingAppleHealthRow: View {
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var model: AppModel
    @State private var working = false

    var body: some View {
        switch health.auth {
        case .unavailable, .entitlementMissing:
            // A free-signed sideload has no HealthKit entitlement; offering a button that cannot work
            // would be a dead end. The export import above still covers this case.
            EmptyView()
        case .authorized:
            OnboardingStatusLine(text: String(localized: "zoop.onboarding.sync.health.connected"),
                                 tint: StrandPalette.statusPositive)
        case .unknown, .denied:
            ListCard {
                VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                    OnboardingInfoRow(icon: "heart.fill", tint: StrandPalette.metricCyan,
                                      title: String(localized: "zoop.onboarding.sync.health.title"),
                                      message: String(localized: "zoop.onboarding.sync.health.body"))
                    Button(action: connect) {
                        Text(LocalizedStringKey(working ? "zoop.onboarding.sync.health.working" : "zoop.onboarding.sync.health.connect"))
                    }
                    .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
                    .disabled(working)
                }
                .listCardRow(isFirst: true)
            }
        }
    }

    private func connect() {
        working = true
        Task {
            await health.requestAuthorization()
            await HealthSyncRefreshCoordinator.run(
                sync: { await health.sync() },
                refresh: { await model.refreshAfterAppleHealthSync(authorized: health.auth == .authorized) }
            )
            working = false
        }
    }
}
#endif
